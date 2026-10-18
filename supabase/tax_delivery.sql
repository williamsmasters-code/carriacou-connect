-- Carriacou Connect v1.5 : TAX and DELIVERY FEES at checkout. TEST MODE wallets unchanged (play money only).
-- Run this whole file in Supabase SQL Editor LAST, after: schema -> seed -> storage -> orders -> order_notes -> pay -> analytics -> staff -> photos
--   -> standard_analytics -> platform_analytics -> advanced_analytics -> admin_customers.   Safe to re-run (idempotent).
-- RUN tax_delivery.sql LAST: it redefines place_order, vendor_tax_report, vendor_pnl and vendor_accounting_export from earlier files.
-- If you ever re-run an earlier file, re-run this one again afterwards (the order trigger and all new tables keep working either way).
-- Supabase uses pg-safeupdate: every UPDATE / DELETE below has a WHERE.
--
-- WHAT IT ADDS
--   * vendor_checkout_settings: per business: pickup on/off, delivery on/off, delivery fee model (flat, or a per-area list), "free delivery over EC$X",
--     VAT registered yes/no, VAT rate (empty = platform default), prices include tax yes/no, VAT number. RLS on, NO grants: only the functions below touch it.
--     No row = defaults: pickup and delivery both on, delivery fee EC$0, not VAT registered (tax 0). So every existing business behaves exactly as before.
--   * platform_settings.default_vat_pct (default 15, allowed 0 to 30): the rate used for VAT-registered businesses that did not set their own rate.
--   * orders get snapshot columns: delivery_area, tax_xcd, vendor_vat_number (tax_rate_pct, tax_inclusive, delivery_fee_xcd already exist). Old orders keep NULL tax_xcd.
--   * _order_money(): THE ONE place the money is worked out (used by the order trigger and by the checkout preview).
--   * trigger trg_orders_zz_tax_delivery (BEFORE INSERT on orders): when place_order() creates an order it fills in the delivery fee, area, tax snapshot
--     and the final total_xcd. It runs AFTER the campaign discount trigger (triggers fire alphabetically).
--   * place_order() redefined: the customer may choose pickup or delivery PER vendor order (plus a delivery area). place_order_with_code() is untouched
--     and still works (it calls place_order). New place_order_plan() = place_order_with_code + a per-vendor plan.
--   * checkout_quote(): server-side preview of the same numbers for the checkout page (display only; place_order recomputes everything).
--   * vendor_checkout_options(): what a customer may see about a business's delivery/tax rules (no private data).
--   * vendor_get_checkout_settings / vendor_set_checkout_settings: owner and sub-admin only, audited.
--   * admin_vat_settings / admin_set_default_vat: platform admin only, reason required, audited. admin_pa_tax_summary: platform tax report.
--   * vendor_tax_report, vendor_pnl, vendor_accounting_export redefined to use the REAL snapshotted tax where an order has it (estimate for older orders).
--
-- MONEY RULES (document of record)
--   subtotal  = sum over the order's lines of round(price x quantity, 2)         (as before)
--   discount  = campaign discount, round(subtotal x pct / 100, 2), never more than the subtotal      (as before)
--   net       = subtotal - discount
--   delivery  = 0 for pickup. Delivery: the flat fee, or the fee of the chosen area; then 0 if "free over" is set and net >= that amount.
--   base      = net + delivery.   The delivery fee is taxed like the goods (same rate, same inclusive/exclusive setting).
--   VAT registered, rate r, prices INCLUDE tax:  tax = round(base x r / (100 + r), 2);  total = base           (tax is already inside the total)
--   VAT registered, rate r, prices EXCLUDE tax:  tax = round(base x r / 100, 2);        total = base + tax     (tax is added on top)
--   Not VAT registered: rate 0, tax 0, total = base.
--   ONE rounding per order (on the whole base, not per line), numeric arithmetic, round half away from zero (Postgres round(numeric, 2)), to the cent.
--   Wallet payments, refunds and the ledger all use total_xcd x 100 as whole cents, so they always agree with what the customer saw.
--   Changing a setting later never changes an old order: the rate, inclusive flag, tax amount, delivery fee and area are saved on the order.

-- =====================================================================================================
-- 1. Columns and tables
-- =====================================================================================================
alter table public.orders add column if not exists delivery_area text;
alter table public.orders add column if not exists tax_xcd numeric(10,2);
alter table public.orders add column if not exists vendor_vat_number text;
alter table public.orders drop constraint if exists orders_tax_nonneg;
alter table public.orders add constraint orders_tax_nonneg check (tax_xcd is null or tax_xcd >= 0);

alter table public.platform_settings add column if not exists default_vat_pct numeric(5,2) not null default 15;
alter table public.platform_settings drop constraint if exists platform_settings_vat_range;
alter table public.platform_settings add constraint platform_settings_vat_range check (default_vat_pct >= 0 and default_vat_pct <= 30);

create table if not exists public.vendor_checkout_settings (
  vendor_id           uuid primary key references public.vendors(id) on delete cascade,
  pickup_enabled      boolean not null default true,
  delivery_enabled    boolean not null default true,
  delivery_model      text not null default 'flat' check (delivery_model in ('flat','zones')),
  delivery_flat_fee   numeric(8,2) not null default 0 check (delivery_flat_fee >= 0 and delivery_flat_fee <= 500),
  free_over_xcd       numeric(10,2) check (free_over_xcd is null or (free_over_xcd > 0 and free_over_xcd <= 100000)),
  delivery_zones      jsonb not null default '[]'::jsonb check (jsonb_typeof(delivery_zones) = 'array' and jsonb_array_length(delivery_zones) <= 20),
  vat_registered      boolean not null default false,
  vat_rate_pct        numeric(5,2) check (vat_rate_pct is null or (vat_rate_pct >= 0 and vat_rate_pct <= 30)),
  prices_include_tax  boolean not null default true,
  vat_number          text check (vat_number is null or char_length(vat_number) <= 40),
  updated_by          uuid,
  updated_at          timestamptz not null default now(),
  check (pickup_enabled or delivery_enabled)
);
alter table public.vendor_checkout_settings enable row level security;
revoke all on public.vendor_checkout_settings from public, anon, authenticated;

-- =====================================================================================================
-- 2. The one money calculation
-- =====================================================================================================
create or replace function public._vat_default() returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select default_vat_pct from public.platform_settings where id), 15) $$;
revoke all on function public._vat_default() from public, anon, authenticated;

-- returns jsonb {delivery_fee_xcd, delivery_area, tax_rate_pct, tax_inclusive, tax_xcd, total_xcd, net_xcd, vat_number, vat_registered}
-- raises for a choice the business does not offer / a missing or unknown area.
create or replace function public._order_money(p_vendor uuid, p_sub numeric, p_disc numeric, p_ful text, p_area text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.vendor_checkout_settings; found_s boolean; vname text; net numeric; fee numeric := 0; area text; z jsonb; zones jsonb;
  reg boolean := false; rate numeric := 0; incl boolean := true; vat text; base numeric; tax numeric := 0; total numeric;
begin
  select * into s from public.vendor_checkout_settings where vendor_id = p_vendor; found_s := found;
  select name into vname from public.vendors where id = p_vendor;
  net := greatest(coalesce(p_sub, 0) - coalesce(p_disc, 0), 0);
  if p_ful = 'pickup' then
    if found_s and not s.pickup_enabled then raise exception '% does not offer pickup. Choose delivery.', vname; end if;
  elsif p_ful = 'delivery' then
    if found_s and not s.delivery_enabled then raise exception '% does not offer delivery. Choose pickup.', vname; end if;
    zones := case when found_s then s.delivery_zones else '[]'::jsonb end;
    if found_s and s.delivery_model = 'zones' and jsonb_array_length(zones) > 0 then
      select e into z from jsonb_array_elements(zones) e where lower(e->>'name') = lower(btrim(coalesce(p_area, ''))) limit 1;
      if z is null then raise exception 'Choose a delivery area for %.', vname; end if;
      fee := (z->>'fee')::numeric; area := z->>'name';
    else
      fee := case when found_s then s.delivery_flat_fee else 0 end;
    end if;
    if found_s and s.free_over_xcd is not null and net >= s.free_over_xcd then fee := 0; end if;
  else
    raise exception 'Choose pickup or delivery';
  end if;
  fee := round(fee, 2);
  if found_s and s.vat_registered then
    reg := true; rate := coalesce(s.vat_rate_pct, public._vat_default()); incl := s.prices_include_tax; vat := s.vat_number;
  end if;
  base := net + fee;
  if rate > 0 then
    tax := case when incl then round(base * rate / (100 + rate), 2) else round(base * rate / 100, 2) end;
  end if;
  total := base + case when incl then 0 else tax end;
  return jsonb_build_object('delivery_fee_xcd', fee, 'delivery_area', area, 'tax_rate_pct', rate, 'tax_inclusive', incl, 'tax_xcd', tax,
                            'total_xcd', total, 'net_xcd', net, 'vat_number', vat, 'vat_registered', reg);
end $$;
revoke all on function public._order_money(uuid, numeric, numeric, text, text) from public, anon, authenticated;

-- BEFORE INSERT on orders: only when place_order() switched it on for this order (cc.order_money = '1').
-- (A row inserted any other way, e.g. test data typed into the SQL editor, is stored exactly as given.)
create or replace function public.orders_apply_tax_delivery() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare m jsonb;
begin
  if coalesce(current_setting('cc.order_money', true), '') <> '1' then return new; end if;
  m := public._order_money(new.vendor_id, new.subtotal_xcd, new.discount_xcd, new.fulfilment, new.delivery_area);
  new.delivery_fee_xcd := (m->>'delivery_fee_xcd')::numeric;
  new.delivery_area    := m->>'delivery_area';
  new.tax_rate_pct     := (m->>'tax_rate_pct')::numeric;
  new.tax_inclusive    := (m->>'tax_inclusive')::boolean;
  new.tax_xcd          := (m->>'tax_xcd')::numeric;
  new.vendor_vat_number := m->>'vat_number';
  new.total_xcd        := (m->>'total_xcd')::numeric;
  return new;
end $$;
revoke all on function public.orders_apply_tax_delivery() from public, anon, authenticated;
drop trigger if exists trg_orders_zz_tax_delivery on public.orders;
create trigger trg_orders_zz_tax_delivery before insert on public.orders
  for each row execute function public.orders_apply_tax_delivery();

-- =====================================================================================================
-- 3. place_order(): same rules as orders.sql (all or nothing, prices from the table, one order per vendor, stock and suspension triggers
--    still apply) PLUS per-vendor pickup/delivery choice, the delivery fee and tax. The plan is read from the setting cc.order_plan
--    (set only by place_order_plan below), shape {"<vendor uuid>": {"fulfilment": "pickup|delivery", "area": "Hillsborough"}};
--    a vendor missing from the plan uses p_fulfilment. Result per order: id, order_number, vendor_id, vendor_name, fulfilment,
--    subtotal_xcd, delivery_fee_xcd, tax_xcd, total_xcd.
-- =====================================================================================================
create or replace function public.place_order(
  p_cart jsonb, p_fulfilment text, p_contact_phone text,
  p_delivery_address text default null, p_notes text default null, p_contact_name text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  ph text := btrim(coalesce(p_contact_phone,''));
  addr text := nullif(btrim(coalesce(p_delivery_address,'')),'');
  nts text := nullif(btrim(coalesce(p_notes,'')),'');
  cname text := nullif(btrim(coalesce(p_contact_name,'')),'');
  el jsonb; k text; v jsonb; pid uuid; q integer;
  vrec record; oid uuid; onum text; sub numeric(10,2);
  result jsonb := '[]'::jsonb; missing text;
  plan jsonb := '{}'::jsonb; vful text; varea text; o record;
begin
  if uid is null then raise exception 'Please log in to place an order'; end if;
  if p_fulfilment is null or p_fulfilment not in ('pickup','delivery') then raise exception 'Choose pickup or delivery'; end if;
  if char_length(ph) < 7 or char_length(ph) > 30 then raise exception 'Enter a contact phone number'; end if;
  if char_length(coalesce(addr,'')) > 300 or char_length(coalesce(nts,'')) > 500 or char_length(coalesce(cname,'')) > 80 then
    raise exception 'Address, notes or name too long';
  end if;
  if p_cart is null then raise exception 'Your cart is empty'; end if;
  begin plan := coalesce(nullif(current_setting('cc.order_plan', true), '')::jsonb, '{}'::jsonb); exception when others then plan := '{}'::jsonb; end;
  if jsonb_typeof(plan) <> 'object' then plan := '{}'::jsonb; end if;

  -- normalise the cart into lines (merge duplicates)
  create temp table if not exists _cart_lines(product_id uuid primary key, qty integer not null) on commit drop;
  delete from _cart_lines where true;
  if jsonb_typeof(p_cart) = 'array' then
    for el in select * from jsonb_array_elements(p_cart) loop
      begin
        pid := (el->>'product_id')::uuid; q := (el->>'quantity')::integer;
      exception when others then raise exception 'Invalid cart'; end;
      if q is null or q < 1 or q > 99 then raise exception 'Invalid quantity'; end if;
      insert into _cart_lines values (pid, q) on conflict (product_id) do update set qty = least(99, _cart_lines.qty + q);
    end loop;
  elsif jsonb_typeof(p_cart) = 'object' then
    for k, v in select * from jsonb_each(p_cart) loop
      begin pid := k::uuid; q := (v #>> '{}')::integer; exception when others then raise exception 'Invalid cart'; end;
      if q is null or q < 1 or q > 99 then raise exception 'Invalid quantity'; end if;
      insert into _cart_lines values (pid, q) on conflict (product_id) do update set qty = least(99, _cart_lines.qty + q);
    end loop;
  else raise exception 'Invalid cart'; end if;

  if (select count(*) from _cart_lines) = 0 then raise exception 'Your cart is empty'; end if;
  if (select count(*) from _cart_lines) > 50 then raise exception 'Too many different items (max 50)'; end if;

  -- every product must exist and be active
  select string_agg(coalesce(p.name, c.product_id::text), ', ') into missing
    from _cart_lines c left join public.products p on p.id = c.product_id
    where p.id is null or not p.active;
  if missing is not null then raise exception 'No longer available: %. Remove it from your cart and try again.', missing; end if;
  if (select count(distinct p.vendor_id) from _cart_lines c join public.products p on p.id = c.product_id) > 10 then
    raise exception 'Too many vendors in one cart (max 10)';
  end if;

  -- one order per vendor
  for vrec in
    select distinct v.id, v.name from _cart_lines c
      join public.products p on p.id = c.product_id join public.vendors v on v.id = p.vendor_id order by v.name
  loop
    vful := coalesce(nullif(plan->(vrec.id::text)->>'fulfilment', ''), p_fulfilment);
    if vful not in ('pickup','delivery') then raise exception 'Choose pickup or delivery'; end if;
    varea := nullif(btrim(coalesce(plan->(vrec.id::text)->>'area', '')), '');
    if char_length(coalesce(varea, '')) > 60 then raise exception 'Delivery area too long'; end if;
    if vful = 'delivery' and (addr is null or char_length(addr) < 5) then raise exception 'Enter a delivery address'; end if;

    select coalesce(sum(round(p.price_xcd * c.qty, 2)),0) into sub
      from _cart_lines c join public.products p on p.id = c.product_id where p.vendor_id = vrec.id;

    perform set_config('cc.order_money', '1', true);    -- trigger trg_orders_zz_tax_delivery works out delivery fee, tax and total
    insert into public.orders(consumer_id, vendor_id, status, fulfilment, payment_method, contact_name, contact_phone,
                              delivery_address, delivery_area, notes, subtotal_xcd, delivery_fee_xcd, total_xcd)
    values (uid, vrec.id, 'placed', vful,
            case vful when 'pickup' then 'pay_on_pickup' else 'pay_on_delivery' end,
            cname, ph, case when vful = 'delivery' then addr end, varea, nts, sub, 0, sub)
    returning id, order_number into oid, onum;
    perform set_config('cc.order_money', '', true);

    insert into public.order_items(order_id, product_id, product_name, unit_price_xcd, quantity, line_total_xcd)
    select oid, p.id, p.name, p.price_xcd, c.qty, round(p.price_xcd * c.qty, 2)
      from _cart_lines c join public.products p on p.id = c.product_id where p.vendor_id = vrec.id;

    insert into public.order_status_history(order_id, from_status, to_status, changed_by) values (oid, null, 'placed', uid);

    select ord.subtotal_xcd, ord.discount_xcd, ord.delivery_fee_xcd, ord.tax_xcd, ord.total_xcd into o from public.orders ord where ord.id = oid;
    result := result || jsonb_build_array(jsonb_build_object('id', oid, 'order_number', onum,
              'vendor_id', vrec.id, 'vendor_name', vrec.name, 'fulfilment', vful,
              'subtotal_xcd', o.subtotal_xcd, 'discount_xcd', o.discount_xcd, 'delivery_fee_xcd', o.delivery_fee_xcd, 'tax_xcd', o.tax_xcd, 'total_xcd', o.total_xcd));
  end loop;
  return result;
end $$;
revoke all on function public.place_order(jsonb, text, text, text, text, text) from public, anon;
grant execute on function public.place_order(jsonb, text, text, text, text, text) to authenticated;

-- place an order with a per-vendor plan (and an optional campaign code). This is what the checkout page calls.
create or replace function public.place_order_plan(
  p_cart jsonb, p_plan jsonb, p_contact_phone text, p_delivery_address text default null, p_notes text default null,
  p_contact_name text default null, p_campaign_code text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare res jsonb; key text; val jsonb; any_delivery boolean := false;
begin
  if auth.uid() is null then raise exception 'Please log in to place an order'; end if;
  if p_plan is null or jsonb_typeof(p_plan) <> 'object' then raise exception 'Choose pickup or delivery'; end if;
  if (select count(*) from jsonb_object_keys(p_plan)) > 10 then raise exception 'Too many vendors in one cart (max 10)'; end if;
  for key, val in select * from jsonb_each(p_plan) loop
    if key !~* '^[0-9a-f-]{36}$' or jsonb_typeof(val) <> 'object' or coalesce(val->>'fulfilment', '') not in ('pickup','delivery') then
      raise exception 'Choose pickup or delivery'; end if;
    if val->>'fulfilment' = 'delivery' then any_delivery := true; end if;
  end loop;
  perform set_config('cc.order_plan', p_plan::text, true);
  begin
    -- the default fulfilment only matters for a vendor missing from the plan (use delivery if the person gave an address, else pickup)
    res := public.place_order_with_code(p_cart, case when any_delivery then 'delivery' else 'pickup' end, p_contact_phone,
             p_delivery_address, p_notes, p_contact_name, p_campaign_code);
  exception when others then
    perform set_config('cc.order_plan', '', true);
    raise;
  end;
  perform set_config('cc.order_plan', '', true);
  return res;
end $$;
revoke all on function public.place_order_plan(jsonb, jsonb, text, text, text, text, text) from public, anon;
grant execute on function public.place_order_plan(jsonb, jsonb, text, text, text, text, text) to authenticated;

-- =====================================================================================================
-- 4. Checkout preview + what a customer may know about a business's delivery and tax rules
-- =====================================================================================================
-- vendor ids in a cart (active products only; same cart shapes as place_order)
create or replace function public._cart_vendor_ids(p_cart jsonb) returns uuid[]
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare el jsonb; k text; ids uuid[] := '{}';
begin
  if p_cart is null then return ids; end if;
  if jsonb_typeof(p_cart) = 'array' then
    for el in select * from jsonb_array_elements(p_cart) loop
      if (el->>'product_id') ~* '^[0-9a-f-]{36}$' then ids := ids || (el->>'product_id')::uuid; end if;
    end loop;
  elsif jsonb_typeof(p_cart) = 'object' then
    for k in select * from jsonb_object_keys(p_cart) loop
      if k ~* '^[0-9a-f-]{36}$' then ids := ids || k::uuid; end if;
    end loop;
  end if;
  return coalesce((select array_agg(distinct p.vendor_id order by p.vendor_id) from public.products p where p.id = any(ids) and p.active), '{}');
end $$;
revoke all on function public._cart_vendor_ids(jsonb) from public, anon, authenticated;

create or replace function public.vendor_checkout_options(p_vendor_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_vendor_ids is null or cardinality(p_vendor_ids) > 20 then raise exception 'Too many businesses'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'vendor_id', v.id, 'vendor_name', v.name,
      'pickup_enabled', coalesce(s.pickup_enabled, true), 'delivery_enabled', coalesce(s.delivery_enabled, true),
      'delivery_model', coalesce(s.delivery_model, 'flat'), 'delivery_flat_fee', coalesce(s.delivery_flat_fee, 0), 'free_over_xcd', s.free_over_xcd,
      'delivery_zones', coalesce(s.delivery_zones, '[]'::jsonb),
      'vat_registered', coalesce(s.vat_registered, false),
      'tax_rate_pct', case when coalesce(s.vat_registered, false) then coalesce(s.vat_rate_pct, public._vat_default()) else 0 end,
      'prices_include_tax', case when coalesce(s.vat_registered, false) then s.prices_include_tax else true end,
      'vat_number', case when coalesce(s.vat_registered, false) then s.vat_number end) order by v.name)
    from public.vendors v left join public.vendor_checkout_settings s on s.vendor_id = v.id where v.id = any(p_vendor_ids)), '[]'::jsonb);
end $$;
revoke all on function public.vendor_checkout_options(uuid[]) from public, anon;
grant execute on function public.vendor_checkout_options(uuid[]) to authenticated;

-- Server-side preview of what place_order_plan will do. DISPLAY ONLY: place_order recomputes everything when the order is placed.
-- p_plan: {"<vendor uuid>": {"fulfilment": "pickup|delivery", "area": "..."}}. A vendor with a problem (area missing, delivery off) gets an "error" text.
-- A wrong campaign code counts as a failed guess (same throttle as check_campaign_code) and is reported in code_error.
create or replace function public.checkout_quote(p_cart jsonb, p_plan jsonb, p_campaign_code text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); vid uuid; vname text; sub numeric; disc numeric; ful text; area text; m jsonb; c public.campaigns; cr jsonb;
  outl jsonb := '[]'::jsonb; grand numeric := 0; cerr text; cid uuid; code text := nullif(btrim(coalesce(p_campaign_code, '')), ''); rw jsonb;
begin
  if uid is null then raise exception 'Please log in'; end if;
  if p_plan is null or jsonb_typeof(p_plan) <> 'object' then p_plan := '{}'::jsonb; end if;
  if code is not null then
    perform public._pay_throttle(uid, 'campaign', 10, 'Too many wrong codes. Please wait a few minutes and try again.');
    cr := public._campaign_resolve(code, uid, false);
    if cr ? 'err' then
      if cr ? 'bad' then insert into public.pay_attempts(user_id, kind) values (uid, 'campaign'); end if;
      cerr := cr->>'err';
    else cid := (cr->>'id')::uuid; select * into c from public.campaigns where id = cid; end if;
  end if;
  for vid in select unnest(public._cart_vendor_ids(p_cart)) loop
    select name into vname from public.vendors where id = vid;
    sub := public._cart_vendor_subtotal(p_cart, vid);
    disc := 0;
    if cid is not null and c.vendor_id = vid and c.discount_pct is not null then disc := least(round(sub * c.discount_pct / 100, 2), sub); end if;
    ful := coalesce(nullif(p_plan->(vid::text)->>'fulfilment', ''), 'pickup');
    area := nullif(btrim(coalesce(p_plan->(vid::text)->>'area', '')), '');
    rw := jsonb_build_object('vendor_id', vid, 'vendor_name', vname, 'fulfilment', ful, 'subtotal_xcd', sub, 'discount_xcd', disc);
    begin
      m := public._order_money(vid, sub, disc, ful, area);
      rw := rw || jsonb_build_object('delivery_fee_xcd', m->'delivery_fee_xcd', 'delivery_area', m->'delivery_area', 'tax_rate_pct', m->'tax_rate_pct',
               'tax_inclusive', m->'tax_inclusive', 'tax_xcd', m->'tax_xcd', 'total_xcd', m->'total_xcd', 'vat_registered', m->'vat_registered', 'vat_number', m->'vat_number');
      grand := grand + (m->>'total_xcd')::numeric;
    exception when others then
      rw := rw || jsonb_build_object('error', sqlerrm, 'delivery_fee_xcd', 0, 'tax_xcd', 0, 'total_xcd', greatest(sub - disc, 0));
      grand := grand + greatest(sub - disc, 0);
    end;
    outl := outl || jsonb_build_array(rw);
  end loop;
  return jsonb_build_object('orders', outl, 'grand_total_xcd', grand, 'code_error', cerr, 'campaign_vendor_id', case when cid is not null then c.vendor_id end);
end $$;
revoke all on function public.checkout_quote(jsonb, jsonb, text) from public, anon;
grant execute on function public.checkout_quote(jsonb, jsonb, text) to authenticated;

-- =====================================================================================================
-- 5. Vendor settings: owner and sub-admin only (vendor_role = 'admin' or 'subadmin'; staff cannot), every change audited
-- =====================================================================================================
create or replace function public._co_editor(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(public.vendor_role(p_vendor) in ('admin', 'subadmin'), false) $$;
revoke all on function public._co_editor(uuid) from public, anon, authenticated;

create or replace function public.vendor_get_checkout_settings(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.vendor_checkout_settings; has boolean;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_vendor is null or not public._co_editor(p_vendor) then raise exception 'Only the owner or a sub-admin can see these settings'; end if;
  select * into s from public.vendor_checkout_settings where vendor_id = p_vendor; has := found;
  return jsonb_build_object('saved', has,
    'pickup_enabled', coalesce(s.pickup_enabled, true), 'delivery_enabled', coalesce(s.delivery_enabled, true),
    'delivery_model', coalesce(s.delivery_model, 'flat'), 'delivery_flat_fee', coalesce(s.delivery_flat_fee, 0), 'free_over_xcd', s.free_over_xcd,
    'delivery_zones', coalesce(s.delivery_zones, '[]'::jsonb), 'vat_registered', coalesce(s.vat_registered, false), 'vat_rate_pct', s.vat_rate_pct,
    'prices_include_tax', coalesce(s.prices_include_tax, true), 'vat_number', s.vat_number,
    'platform_default_vat_pct', public._vat_default(), 'updated_at', s.updated_at);
end $$;
revoke all on function public.vendor_get_checkout_settings(uuid) from public, anon;
grant execute on function public.vendor_get_checkout_settings(uuid) to authenticated;

-- p_settings keys (all optional; a missing key keeps the current value): pickup_enabled, delivery_enabled, delivery_model ('flat'|'zones'),
-- delivery_flat_fee, free_over_xcd (null = no free-delivery threshold), delivery_zones [{name, fee}], vat_registered, vat_rate_pct (null = platform default),
-- prices_include_tax, vat_number.
create or replace function public.vendor_set_checkout_settings(p_vendor uuid, p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare cur jsonb; n jsonb; z jsonb; zs jsonb := '[]'::jsonb; names text[] := '{}'; zn text; zf numeric; ff numeric; fo numeric; vr numeric; vn text; model text;
  pe boolean; de boolean; reg boolean; incl boolean; k text;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_vendor is null or not public._co_editor(p_vendor) then raise exception 'Only the owner or a sub-admin can change these settings'; end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then raise exception 'Invalid settings'; end if;
  for k in select * from jsonb_object_keys(p_settings) loop
    if k not in ('pickup_enabled','delivery_enabled','delivery_model','delivery_flat_fee','free_over_xcd','delivery_zones','vat_registered','vat_rate_pct','prices_include_tax','vat_number') then
      raise exception 'Unknown setting: %', left(k, 40); end if;
  end loop;
  perform pg_advisory_xact_lock(hashtext('checkout_settings:' || p_vendor::text));
  cur := public.vendor_get_checkout_settings(p_vendor);
  n := cur || p_settings;
  begin
    pe := (n->>'pickup_enabled')::boolean; de := (n->>'delivery_enabled')::boolean; reg := (n->>'vat_registered')::boolean; incl := (n->>'prices_include_tax')::boolean;
    ff := (n->>'delivery_flat_fee')::numeric; fo := nullif(n->>'free_over_xcd', '')::numeric; vr := nullif(n->>'vat_rate_pct', '')::numeric;
  exception when others then raise exception 'Invalid settings (a number or yes/no value is not valid)'; end;
  if pe is null or de is null or reg is null or incl is null or ff is null then raise exception 'Invalid settings'; end if;
  if not pe and not de then raise exception 'Turn on pickup, delivery or both'; end if;
  model := n->>'delivery_model';
  if model not in ('flat', 'zones') then raise exception 'Choose a flat fee or delivery areas'; end if;
  if ff < 0 or ff > 500 or ff <> round(ff, 2) then raise exception 'The delivery fee must be between 0 and 500, with at most two decimals'; end if;
  if fo is not null and (fo <= 0 or fo > 100000 or fo <> round(fo, 2)) then raise exception 'Free delivery over: use an amount above 0 (at most two decimals), or leave it empty'; end if;
  if vr is not null and (vr < 0 or vr > 30 or vr <> round(vr, 2)) then raise exception 'The VAT rate must be between 0 and 30 percent, with at most two decimals'; end if;
  vn := nullif(btrim(coalesce(n->>'vat_number', '')), '');
  if vn is not null and (char_length(vn) > 40 or vn ~ '[[:cntrl:]]') then raise exception 'The VAT number is too long or has invalid characters (max 40)'; end if;
  if jsonb_typeof(n->'delivery_zones') <> 'array' then raise exception 'Delivery areas must be a list'; end if;
  if jsonb_array_length(n->'delivery_zones') > 20 then raise exception 'At most 20 delivery areas'; end if;
  for z in select * from jsonb_array_elements(n->'delivery_zones') loop
    if jsonb_typeof(z) <> 'object' then raise exception 'Invalid delivery area'; end if;
    zn := btrim(coalesce(z->>'name', ''));
    if char_length(zn) < 1 or char_length(zn) > 40 or zn ~ '[[:cntrl:]]' then raise exception 'Each delivery area needs a name of 1 to 40 characters'; end if;
    if lower(zn) = any(names) then raise exception 'Delivery area "%" is listed twice', zn; end if;
    names := names || lower(zn);
    begin zf := (z->>'fee')::numeric; exception when others then raise exception 'The fee for "%" is not a number', zn; end;
    if zf is null or zf < 0 or zf > 500 or zf <> round(zf, 2) then raise exception 'The fee for "%" must be between 0 and 500, with at most two decimals', zn; end if;
    zs := zs || jsonb_build_array(jsonb_build_object('name', zn, 'fee', zf));
  end loop;
  if model = 'zones' and jsonb_array_length(zs) = 0 then raise exception 'Add at least one delivery area, or choose a flat fee'; end if;
  insert into public.vendor_checkout_settings(vendor_id, pickup_enabled, delivery_enabled, delivery_model, delivery_flat_fee, free_over_xcd, delivery_zones,
      vat_registered, vat_rate_pct, prices_include_tax, vat_number, updated_by, updated_at)
  values (p_vendor, pe, de, model, ff, fo, zs, reg, vr, incl, vn, auth.uid(), now())
  on conflict (vendor_id) do update set pickup_enabled = excluded.pickup_enabled, delivery_enabled = excluded.delivery_enabled,
      delivery_model = excluded.delivery_model, delivery_flat_fee = excluded.delivery_flat_fee, free_over_xcd = excluded.free_over_xcd,
      delivery_zones = excluded.delivery_zones, vat_registered = excluded.vat_registered, vat_rate_pct = excluded.vat_rate_pct,
      prices_include_tax = excluded.prices_include_tax, vat_number = excluded.vat_number, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  perform public._audit(p_vendor, 'checkout_settings_changed', null, jsonb_build_object(
    'before', cur - 'updated_at' - 'saved' - 'platform_default_vat_pct', 'after', public.vendor_get_checkout_settings(p_vendor) - 'updated_at' - 'saved' - 'platform_default_vat_pct'));
  return public.vendor_get_checkout_settings(p_vendor);
end $$;
revoke all on function public.vendor_set_checkout_settings(uuid, jsonb) from public, anon;
grant execute on function public.vendor_set_checkout_settings(uuid, jsonb) to authenticated;

-- =====================================================================================================
-- 6. Platform admin: default VAT rate (bounded 0 to 30, reason required, audited) and the platform tax report
-- =====================================================================================================
create or replace function public.admin_vat_settings() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  return jsonb_build_object('default_vat_pct', public._vat_default(), 'min', 0, 'max', 30,
    'registered_vendors', (select count(*) from public.vendor_checkout_settings s join public.vendors v on v.id = s.vendor_id where s.vat_registered and not v.is_sample),
    'vendors_using_default', (select count(*) from public.vendor_checkout_settings s join public.vendors v on v.id = s.vendor_id where s.vat_registered and s.vat_rate_pct is null and not v.is_sample),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'from', a.details->'from', 'to', a.details->'to', 'reason', a.details->>'reason') order by a.at desc, a.id desc)
                           from (select * from public.audit_log where action = 'platform_default_vat_changed' order by at desc, id desc limit 20) a), '[]'::jsonb));
end $$;

create or replace function public.admin_set_default_vat(p_rate numeric, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare old numeric; why text := btrim(coalesce(p_reason, ''));
begin
  perform public._require_platform_admin();
  if p_rate is null or p_rate < 0 or p_rate > 30 then raise exception 'The default VAT rate must be between 0 and 30 percent'; end if;
  if p_rate <> round(p_rate, 2) then raise exception 'Use at most two decimal places'; end if;
  if char_length(why) < 3 or char_length(why) > 300 then raise exception 'Give a reason (3 to 300 characters)'; end if;
  perform pg_advisory_xact_lock(hashtext('platform_vat'));
  select default_vat_pct into old from public.platform_settings where id;
  if old = p_rate then return jsonb_build_object('ok', true, 'unchanged', true, 'default_vat_pct', p_rate); end if;
  update public.platform_settings set default_vat_pct = p_rate, updated_by = auth.uid(), updated_at = now() where id;
  perform public._audit(null, 'platform_default_vat_changed', null, jsonb_build_object('from', old, 'to', p_rate, 'reason', why));
  return jsonb_build_object('ok', true, 'default_vat_pct', p_rate, 'note', 'Applies to new orders from VAT-registered businesses that use the default rate. Old orders keep the rate they were placed with.');
end $$;

-- tax collected island-wide (real snapshots only; older orders have none). Sample businesses excluded. Sales = not cancelled, not refunded.
create or replace function public.admin_pa_tax_summary(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare lo timestamptz; hi timestamptz; r jsonb;
begin
  perform public._pa_range(p_from, p_to);
  lo := p_from::timestamp at time zone 'America/Grenada'; hi := (p_to + 1)::timestamp at time zone 'America/Grenada';
  select jsonb_build_object('from', p_from, 'to', p_to, 'timezone', 'America/Grenada',
    'sales_orders', count(*),
    'gmv_xcd', coalesce(round(sum(o.total_xcd), 2), 0),
    'tax_collected_xcd', coalesce(round(sum(o.tax_xcd), 2), 0),
    'tax_inside_prices_xcd', coalesce(round(sum(o.tax_xcd) filter (where o.tax_inclusive), 2), 0),
    'tax_added_on_top_xcd', coalesce(round(sum(o.tax_xcd) filter (where not o.tax_inclusive), 2), 0),
    'delivery_fees_xcd', coalesce(round(sum(o.delivery_fee_xcd), 2), 0),
    'goods_net_of_tax_xcd', coalesce(round(sum(o.total_xcd - coalesce(o.tax_xcd, 0)), 2), 0),
    'orders_with_tax_record', count(*) filter (where o.tax_xcd is not null),
    'orders_without_tax_record', count(*) filter (where o.tax_xcd is null),
    'taxed_orders', count(*) filter (where o.tax_xcd > 0),
    'vat_registered_vendors', (select count(*) from public.vendor_checkout_settings s join public.vendors v on v.id = s.vendor_id where s.vat_registered and not v.is_sample),
    'default_vat_pct', public._vat_default(),
    'note', 'Tax collected comes from the tax saved on each order when it was placed. Orders from before v1.5 have no tax record and are not counted here. A summary for records, not official tax advice. GMV is what customers paid: it includes tax and delivery fees.')
  into r
  from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
  where o.created_at >= lo and o.created_at < hi and o.status <> 'cancelled' and o.payment_status <> 'refunded';
  return r;
end $$;

revoke all on function public.admin_vat_settings(), public.admin_set_default_vat(numeric, text), public.admin_pa_tax_summary(date, date) from public, anon;
grant execute on function public.admin_vat_settings(), public.admin_set_default_vat(numeric, text), public.admin_pa_tax_summary(date, date) to authenticated;

-- =====================================================================================================
-- 7. Vendor tax report: REAL snapshotted tax where the order has it, ESTIMATE (as in v1.1) for older orders.
--    net_of_tax = what the business keeps before tax: recorded orders total - tax; estimated inclusive total - tax; estimated exclusive = total
--    (the estimate for an older order with prices "excluding tax" was never collected, so it is not inside the total).
-- =====================================================================================================
create or replace function public.vendor_tax_report(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; cur record; cs record; res jsonb; lim constant integer := 5000;
begin
  perform public._std_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  select * into cur from public.vendor_tax_settings where vendor_id = p_vendor;
  select * into cs from public.vendor_checkout_settings where vendor_id = p_vendor;
  with base as (
    select row_number() over (order by o.created_at desc, o.order_number)::integer as n, o.created_at as at,
           (o.created_at at time zone 'America/Grenada')::date as day, o.order_number as ref, o.total_xcd as total, o.delivery_fee_xcd as dlv,
           o.tax_xcd as rec, coalesce(o.tax_rate_pct, cur.tax_rate_pct) as rate, coalesce(o.tax_inclusive, cur.tax_inclusive, true) as incl
      from public.orders o
     where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  r0 as (
    select base.*, (rec is not null) as recorded,
           case when rec is not null then rec
                when rate is null then null
                when incl then round(total * rate / (100 + rate), 2) else round(total * rate / 100, 2) end as tax from base),
  r as (
    select r0.*, case when recorded then total - tax when tax is not null and incl then total - tax else total end as net from r0)
  select jsonb_build_object('settings', jsonb_build_object('tax_rate_pct', cur.tax_rate_pct, 'tax_inclusive', coalesce(cur.tax_inclusive, true),
         'license_number', cur.license_number, 'license_expiry', cur.license_expiry,
         'license_days_left', case when cur.license_expiry is null then null else cur.license_expiry - public._gd_today() end),
    'checkout', jsonb_build_object('vat_registered', coalesce(cs.vat_registered, false), 'vat_rate_pct', cs.vat_rate_pct, 'effective_rate_pct',
         case when coalesce(cs.vat_registered, false) then coalesce(cs.vat_rate_pct, public._vat_default()) else 0 end,
         'prices_include_tax', coalesce(cs.prices_include_tax, true), 'vat_number', cs.vat_number),
    'orders', (select count(*) from r), 'orders_without_rate', (select count(*) from r where rate is null),
    'orders_recorded', (select count(*) from r where recorded), 'orders_estimated', (select count(*) from r where not recorded and rate is not null),
    'sales_xcd', (select coalesce(sum(total), 0) from r),
    'net_of_tax_xcd', (select coalesce(sum(net), 0) from r),
    'delivery_xcd', (select coalesce(sum(dlv), 0) from r),
    'taxed_sales_xcd', (select coalesce(sum(total), 0) from r where rate is not null and (not recorded or tax > 0)),
    'tax_xcd', (select coalesce(sum(tax), 0) from r),
    'tax_recorded_xcd', (select coalesce(sum(tax), 0) from r where recorded),
    'tax_estimated_xcd', (select coalesce(sum(tax), 0) from r where not recorded),
    'tax_inclusive_xcd', (select coalesce(sum(tax), 0) from r where incl),
    'tax_exclusive_xcd', (select coalesce(sum(tax), 0) from r where not incl),
    'tax_added_xcd', (select coalesce(sum(tax), 0) from r where recorded and not incl),
    'tax_not_collected_xcd', (select coalesce(sum(tax), 0) from r where not recorded and not incl),
    'by_month', coalesce((select jsonb_agg(jsonb_build_object('month', m, 'orders', c, 'sales_xcd', s, 'net_xcd', nt, 'tax_xcd', x) order by m)
                           from (select date_trunc('month', day)::date as m, count(*) as c, sum(total) as s, sum(net) as nt, coalesce(sum(tax), 0) as x from r group by 1) q), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'day', day, 'ref', ref, 'total_xcd', total, 'delivery_xcd', dlv, 'net_xcd', net, 'rate_pct', rate,
                          'inclusive', incl, 'tax_xcd', tax, 'source', case when recorded then 'recorded' else 'estimate' end) order by n)
                       from r where n <= lim), '[]'::jsonb),
    'truncated', (select count(*) > lim from r), 'limit', lim)
  into res;
  return res;
end $$;
revoke all on function public.vendor_tax_report(uuid,date,date) from public, anon;
grant execute on function public.vendor_tax_report(uuid,date,date) to authenticated;

-- =====================================================================================================
-- 8. Advanced reports that must treat tax correctly. Profit and loss: revenue = what the customer paid MINUS the recorded tax (tax is not your income),
--    delivery fees stay in revenue; a tax_collected line is added. Accounting export: a tax column per day and payment method.
--    (Copies of the v1.3 functions with only those changes. Other Advanced/Premium reports use the gross amount paid; Basic revenue is the gross amount paid too.)
-- =====================================================================================================
create or replace function public.vendor_pnl(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._adv_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with months as (select gs::date as m from generate_series(date_trunc('month', p_from)::timestamp, date_trunc('month', p_to)::timestamp, interval '1 month') gs),
  s as (
    select o.id, date_trunc('month', o.created_at at time zone 'America/Grenada')::date as m, o.total_xcd - coalesce(o.tax_xcd, 0) as rev, o.discount_xcd as disc, o.delivery_fee_xcd as dlv, o.subtotal_xcd as sub, coalesce(o.tax_xcd, 0) as tx
      from public.orders o
     where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  l as (
    select s.m, coalesce(sum(oi.unit_cost_xcd * oi.quantity), 0) as cogs,
           coalesce(sum(coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity) * (1 - case when s.sub > 0 then s.disc / s.sub else 0 end))
                    filter (where oi.unit_cost_xcd is null), 0) as unc,
           coalesce(sum(coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity) * (1 - case when s.sub > 0 then s.disc / s.sub else 0 end))
                    filter (where oi.unit_cost_xcd is not null), 0) as cst
      from s join public.order_items oi on oi.order_id = s.id group by s.m),
  e as (select date_trunc('month', x.spent_on)::date as m, sum(x.amount_xcd) as amt
          from public.vendor_expenses x where x.vendor_id = p_vendor and x.spent_on between p_from and p_to group by 1),
  sm as (select m, count(*) as orders, sum(rev) as rev, sum(disc) as disc, sum(dlv) as dlv, sum(tx) as tx from s group by m),
  rows as (
    select mo.m, coalesce(sm.orders, 0) as orders, coalesce(sm.rev, 0) as rev, coalesce(sm.disc, 0) as disc, coalesce(sm.dlv, 0) as dlv, coalesce(sm.tx, 0) as tx,
           coalesce(l.cogs, 0) as cogs, coalesce(l.unc, 0) as unc, coalesce(l.cst, 0) as cst, coalesce(e.amt, 0) as exp
      from months mo left join sm on sm.m = mo.m left join l on l.m = mo.m left join e on e.m = mo.m)
  select jsonb_build_object('timezone', 'America/Grenada', 'from', p_from, 'to', p_to, 'revenue_excludes_tax', true,
    'months', (select jsonb_agg(jsonb_build_object('month', m, 'orders', orders, 'revenue_xcd', rev, 'discounts_xcd', disc, 'delivery_xcd', dlv, 'tax_collected_xcd', tx,
          'cogs_xcd', round(cogs, 2), 'uncosted_revenue_xcd', round(unc, 2), 'gross_profit_xcd', round(rev - cogs, 2),
          'expenses_xcd', exp, 'net_profit_xcd', round(rev - cogs - exp, 2)) order by m) from rows),
    'totals', (select jsonb_build_object('orders', coalesce(sum(orders), 0), 'revenue_xcd', coalesce(sum(rev), 0), 'discounts_xcd', coalesce(sum(disc), 0),
          'delivery_xcd', coalesce(sum(dlv), 0), 'tax_collected_xcd', coalesce(sum(tx), 0), 'cogs_xcd', round(coalesce(sum(cogs), 0), 2), 'uncosted_revenue_xcd', round(coalesce(sum(unc), 0), 2),
          'gross_profit_xcd', round(coalesce(sum(rev), 0) - coalesce(sum(cogs), 0), 2), 'expenses_xcd', coalesce(sum(exp), 0),
          'net_profit_xcd', round(coalesce(sum(rev), 0) - coalesce(sum(cogs), 0) - coalesce(sum(exp), 0), 2),
          'cost_coverage_pct', case when coalesce(sum(cst), 0) + coalesce(sum(unc), 0) > 0 then round(sum(cst) / (sum(cst) + sum(unc)) * 100, 1) end) from rows),
    'expenses_by_category', coalesce((select jsonb_agg(jsonb_build_object('category', category, 'amount_xcd', amt) order by amt desc, category)
          from (select x.category, sum(x.amount_xcd) as amt from public.vendor_expenses x
                 where x.vendor_id = p_vendor and x.spent_on between p_from and p_to group by x.category) q), '[]'::jsonb))
  into res;
  return res;
end $$;

create or replace function public.vendor_accounting_export(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb; lim constant integer := 5000;
begin
  perform public._adv_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with s as (
    select (o.created_at at time zone 'America/Grenada')::date as d, o.payment_method as pm, o.total_xcd as t, o.discount_xcd as disc, o.delivery_fee_xcd as dlv, coalesce(o.tax_xcd, 0) as tx
      from public.orders o
     where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  ex as (
    select row_number() over (order by e.spent_on, e.created_at, e.id)::integer as n, e.spent_on, e.category, e.description, e.amount_xcd
      from public.vendor_expenses e where e.vendor_id = p_vendor and e.spent_on between p_from and p_to)
  select jsonb_build_object('timezone', 'America/Grenada', 'from', p_from, 'to', p_to,
    'sales', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'method', pm, 'orders', c, 'total_xcd', t, 'discounts_xcd', disc, 'delivery_xcd', dlv, 'tax_xcd', tx) order by d, pm)
                         from (select d, pm, count(*) as c, sum(t) as t, sum(disc) as disc, sum(dlv) as dlv, sum(tx) as tx from s group by d, pm) q), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('day', spent_on, 'category', category, 'description', description, 'amount_xcd', amount_xcd) order by n) from ex where n <= lim), '[]'::jsonb),
    'expenses_truncated', (select count(*) > lim from ex), 'limit', lim)
  into res;
  return res;
end $$;

revoke all on function public.vendor_pnl(uuid,date,date), public.vendor_accounting_export(uuid,date,date) from public, anon;
grant execute on function public.vendor_pnl(uuid,date,date), public.vendor_accounting_export(uuid,date,date) to authenticated;

notify pgrst, 'reload schema';
