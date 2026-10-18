-- Carriacou Connect v1.1 : STANDARD-tier analytics + campaigns + tax/license settings. TEST MODE wallets unchanged.
-- Safe to re-run (idempotent). Every UPDATE/DELETE has a WHERE (Supabase runs pg-safeupdate).
--
-- RUN ORDER on a fresh project:
--   schema.sql > seed.sql > storage.sql > orders.sql > order_notes.sql > pay.sql > analytics.sql > staff.sql > photos.sql > standard_analytics.sql
-- Existing v1.0 project: just run this file.
-- RE-RUN THIS FILE LAST whenever you re-run schema.sql (it re-grants SELECT on every products column, including the private
-- cost_price) or any file that adds columns to products. It never replaces place_order, bulk_upsert_products, create_charge,
-- vendor_plan or role_perms, so re-running orders/pay/staff/photos does not undo it (only the column grants above are affected).
--
-- What this file adds
--   1. products.cost_price (private: shoppers and anon cannot read it) + order_items.unit_cost_xcd snapshot (trigger; place_order untouched)
--   2. orders.discount_xcd / campaign_id / tax_rate_pct / tax_inclusive snapshots (trigger; place_order untouched)
--   3. campaigns (every plan) + place_order_with_code() wrapper that calls place_order() unchanged and lets a trigger apply the discount
--   4. vendor_tax_settings (tax rate, tax-inclusive flag, license number + expiry)
--   5. pay_requests.created_by (who made a POS charge; set by trigger; create_charge untouched)
--   6. Standard analytics functions (Standard, Plus+, Pro, Enterprise only; owner + sub-admin only; checked INSIDE the functions)

-- =====================================================================================================
-- 1. Cost price (private) and cost snapshot on order lines
-- =====================================================================================================
alter table public.products add column if not exists cost_price numeric(10,2);
alter table public.products drop constraint if exists products_cost_price_check;
alter table public.products add constraint products_cost_price_check check (cost_price is null or (cost_price >= 0 and cost_price <= 1000000));
alter table public.order_items add column if not exists unit_cost_xcd numeric(10,2);   -- null = no cost known when ordered (all old orders)

-- Shoppers (anon / any logged-in user) may read every products column EXCEPT cost_price. Vendors read costs through vendor_product_costs().
-- Writing cost_price still goes through the normal products RLS policies (products_edit).
revoke select on public.products from anon, authenticated;
do $$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name <> 'cost_price';
  execute 'grant select (' || cols || ') on public.products to anon, authenticated';
end $$;

create or replace function public.order_items_snapshot_cost() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.unit_cost_xcd is null and new.product_id is not null then
    select p.cost_price into new.unit_cost_xcd from public.products p where p.id = new.product_id;
  end if;
  return new;
end $$;
revoke all on function public.order_items_snapshot_cost() from public, anon, authenticated;
drop trigger if exists trg_order_items_snapshot_cost on public.order_items;
create trigger trg_order_items_snapshot_cost before insert on public.order_items
  for each row execute function public.order_items_snapshot_cost();

create or replace function public.vendor_product_costs(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not public.vendor_perm(p_vendor, 'products_edit') then raise exception 'You do not have permission to see product costs for this business'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'cost_price', p.cost_price) order by p.id)
                     from public.products p where p.vendor_id = p_vendor and p.cost_price is not null), '[]'::jsonb);
end $$;

-- =====================================================================================================
-- 2. Order snapshots: discount, campaign, tax
-- =====================================================================================================
alter table public.orders add column if not exists discount_xcd numeric(10,2) not null default 0;
alter table public.orders add column if not exists campaign_id uuid;
alter table public.orders add column if not exists tax_rate_pct numeric(5,2);
alter table public.orders add column if not exists tax_inclusive boolean;
alter table public.orders drop constraint if exists orders_discount_range;
alter table public.orders add constraint orders_discount_range check (discount_xcd >= 0 and discount_xcd <= subtotal_xcd);

-- =====================================================================================================
-- 3. Tax and license settings (private to the business team: NOT on the public vendors table)
-- =====================================================================================================
create table if not exists public.vendor_tax_settings (
  vendor_id      uuid primary key references public.vendors(id) on delete cascade,
  tax_rate_pct   numeric(5,2) check (tax_rate_pct is null or (tax_rate_pct >= 0 and tax_rate_pct <= 100)),
  tax_inclusive  boolean not null default true,
  license_number text check (license_number is null or char_length(license_number) <= 60),
  license_expiry date,
  updated_by     uuid,
  updated_at     timestamptz not null default now()
);

-- Standard plan or higher (rank from tier_limits). Used by the policies and functions below.
create or replace function public._std_tier_ok(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select t.rank >= 2 from public.vendors v join public.tier_limits t on t.tier = v.tier where v.id = p_vendor), false);
$$;
revoke all on function public._std_tier_ok(uuid) from public, anon;
grant execute on function public._std_tier_ok(uuid) to authenticated;

alter table public.vendor_tax_settings enable row level security;
drop policy if exists tax_settings_select on public.vendor_tax_settings;
create policy tax_settings_select on public.vendor_tax_settings for select
  using (public.vendor_perm(vendor_id, 'analytics'));
drop policy if exists tax_settings_insert on public.vendor_tax_settings;
create policy tax_settings_insert on public.vendor_tax_settings for insert
  with check (public.vendor_perm(vendor_id, 'vendor_edit') and public._std_tier_ok(vendor_id));
drop policy if exists tax_settings_update on public.vendor_tax_settings;
create policy tax_settings_update on public.vendor_tax_settings for update
  using (public.vendor_perm(vendor_id, 'vendor_edit') and public._std_tier_ok(vendor_id))
  with check (public.vendor_perm(vendor_id, 'vendor_edit') and public._std_tier_ok(vendor_id));
revoke all on public.vendor_tax_settings from anon, authenticated;
grant select, insert, update on public.vendor_tax_settings to authenticated;

create or replace function public.tax_settings_before() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.license_number := nullif(btrim(coalesce(new.license_number, '')), '');
  if new.license_number is not null and new.license_number ~ '[[:cntrl:]]' then raise exception 'License number has invalid characters'; end if;
  new.updated_by := auth.uid(); new.updated_at := now();
  return new;
end $$;
revoke all on function public.tax_settings_before() from public, anon, authenticated;
drop trigger if exists trg_tax_settings_before on public.vendor_tax_settings;
create trigger trg_tax_settings_before before insert or update on public.vendor_tax_settings
  for each row execute function public.tax_settings_before();

-- =====================================================================================================
-- 4. Campaigns (every plan can create them; results reporting is Standard+)
-- =====================================================================================================
create table if not exists public.campaigns (
  id               uuid primary key default gen_random_uuid(),
  vendor_id        uuid not null references public.vendors(id) on delete cascade,
  name             text not null check (char_length(name) between 2 and 80),
  headline         text check (headline is null or char_length(headline) <= 140),
  code             text check (code is null or code ~ '^[A-Z0-9]{3,20}$'),
  discount_pct     numeric(5,2) check (discount_pct is null or (discount_pct > 0 and discount_pct <= 90)),
  starts_on        date not null,
  ends_on          date not null,
  featured         boolean not null default false,
  active           boolean not null default true,
  max_uses         integer check (max_uses is null or (max_uses >= 1 and max_uses <= 1000000)),
  one_per_customer boolean not null default false,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint campaigns_dates_ok check (ends_on >= starts_on and ends_on - starts_on <= 366),
  constraint campaigns_discount_needs_code check (discount_pct is null or code is not null)
);
create unique index if not exists campaigns_code_uq on public.campaigns(code) where code is not null;
create index if not exists campaigns_vendor_idx on public.campaigns(vendor_id, starts_on desc);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orders_campaign_fk') then
    alter table public.orders add constraint orders_campaign_fk foreign key (campaign_id) references public.campaigns(id) on delete restrict;
  end if;
end $$;
create index if not exists orders_campaign_idx on public.orders(campaign_id) where campaign_id is not null;

create or replace function public.campaigns_before() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.name := btrim(new.name);
  new.headline := nullif(btrim(coalesce(new.headline, '')), '');
  new.code := nullif(upper(btrim(coalesce(new.code, ''))), '');
  new.updated_at := now();
  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.created_by);
    if (select count(*) from public.campaigns where vendor_id = new.vendor_id) >= 100 then
      raise exception 'A business can have at most 100 campaigns. Delete old ones first.'; end if;
  else
    new.vendor_id := old.vendor_id; new.created_by := old.created_by;
  end if;
  return new;
end $$;
revoke all on function public.campaigns_before() from public, anon, authenticated;
drop trigger if exists trg_campaigns_before on public.campaigns;
create trigger trg_campaigns_before before insert or update on public.campaigns
  for each row execute function public.campaigns_before();

alter table public.campaigns enable row level security;
drop policy if exists campaigns_select on public.campaigns;
create policy campaigns_select on public.campaigns for select using (public.vendor_perm(vendor_id, 'products_edit') or public.is_admin());
drop policy if exists campaigns_insert on public.campaigns;
create policy campaigns_insert on public.campaigns for insert with check (public.vendor_perm(vendor_id, 'products_edit'));
drop policy if exists campaigns_update on public.campaigns;
create policy campaigns_update on public.campaigns for update using (public.vendor_perm(vendor_id, 'products_edit')) with check (public.vendor_perm(vendor_id, 'products_edit'));
drop policy if exists campaigns_delete on public.campaigns;
create policy campaigns_delete on public.campaigns for delete using (public.vendor_perm(vendor_id, 'products_edit'));
revoke all on public.campaigns from anon, authenticated;
grant select, insert, update, delete on public.campaigns to authenticated;

-- Banner data for the marketplace. The discount code is NEVER returned (vendors put it in the headline if they want to).
create or replace function public.public_featured_campaigns() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'vendor_id', c.vendor_id, 'vendor_name', v.name, 'name', c.name,
           'headline', c.headline, 'ends_on', c.ends_on, 'has_discount', c.discount_pct is not null) order by c.ends_on, c.created_at), '[]'::jsonb)
    from (select * from public.campaigns k
           where k.featured and k.active and (now() at time zone 'America/Grenada')::date between k.starts_on and k.ends_on
           order by k.ends_on, k.created_at limit 6) c
    join public.vendors v on v.id = c.vendor_id;
$$;
revoke all on function public.public_featured_campaigns() from public;
grant execute on function public.public_featured_campaigns() to anon, authenticated;

-- ---- code lookup shared by the checkout preview and the order wrapper. Returns {id} or {err}. Never raises (so failed-guess records stay saved).
create or replace function public._campaign_resolve(p_code text, p_uid uuid, p_lock boolean) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.campaigns; s text := upper(btrim(coalesce(p_code, ''))); today date := (now() at time zone 'America/Grenada')::date;
begin
  if s !~ '^[A-Z0-9]{3,20}$' then return jsonb_build_object('err', 'That code is not valid or has expired.', 'bad', true); end if;
  if p_lock then select * into c from public.campaigns where code = s for update;
  else select * into c from public.campaigns where code = s; end if;
  if not found or not c.active or today < c.starts_on or today > c.ends_on then
    return jsonb_build_object('err', 'That code is not valid or has expired.', 'bad', true); end if;
  if c.discount_pct is null then return jsonb_build_object('id', c.id); end if;   -- tracking-only code: always fine
  if c.max_uses is not null and (select count(*) from public.orders o where o.campaign_id = c.id and o.status <> 'cancelled') >= c.max_uses then
    return jsonb_build_object('err', 'This code has been used up.'); end if;
  if c.one_per_customer and exists (select 1 from public.orders o where o.campaign_id = c.id and o.consumer_id = p_uid and o.status <> 'cancelled') then
    return jsonb_build_object('err', 'You have already used this code.'); end if;
  return jsonb_build_object('id', c.id);
end $$;
revoke all on function public._campaign_resolve(text, uuid, boolean) from public, anon, authenticated;

-- how many EC$ of this cart belong to one vendor (active products, price from the table, same rounding as place_order). Cart shape as place_order().
create or replace function public._cart_vendor_subtotal(p_cart jsonb, p_vendor uuid) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare el jsonb; k text; v jsonb; sub numeric := 0; line numeric; r record;
  ids uuid[] := '{}'; qs integer[] := '{}';
begin
  if p_cart is null then return 0; end if;
  if jsonb_typeof(p_cart) = 'array' then
    for el in select * from jsonb_array_elements(p_cart) loop
      if (el->>'product_id') ~* '^[0-9a-f-]{36}$' and (el->>'quantity') ~ '^[0-9]{1,3}$' then ids := ids || (el->>'product_id')::uuid; qs := qs || (el->>'quantity')::integer; end if;
    end loop;
  elsif jsonb_typeof(p_cart) = 'object' then
    for k, v in select * from jsonb_each(p_cart) loop
      if k ~* '^[0-9a-f-]{36}$' and (v #>> '{}') ~ '^[0-9]{1,3}$' then ids := ids || k::uuid; qs := qs || (v #>> '{}')::integer; end if;
    end loop;
  end if;
  -- merge duplicate product lines (cap 99 like place_order)
  for r in select u.id, least(99, sum(u.q))::integer as q from unnest(ids, qs) as u(id, q) group by u.id loop
    select coalesce(sum(round(p.price_xcd * r.q, 2)), 0) into line from public.products p where p.id = r.id and p.vendor_id = p_vendor and p.active;
    sub := sub + line;
  end loop;
  return sub;
end $$;
revoke all on function public._cart_vendor_subtotal(jsonb, uuid) from public, anon, authenticated;

-- Checkout preview: what would this code do to this cart? Wrong guesses are rate limited (10 per 10 minutes).
create or replace function public.check_campaign_code(p_code text, p_cart jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r jsonb; c public.campaigns; sub numeric; d numeric;
begin
  if uid is null then raise exception 'Please log in'; end if;
  perform public._pay_throttle(uid, 'campaign', 10, 'Too many wrong codes. Please wait a few minutes and try again.');
  r := public._campaign_resolve(p_code, uid, false);
  if r ? 'err' then
    if r ? 'bad' then insert into public.pay_attempts(user_id, kind) values (uid, 'campaign'); end if;
    return jsonb_build_object('ok', false, 'error', r->>'err');
  end if;
  select * into c from public.campaigns where id = (r->>'id')::uuid;
  sub := public._cart_vendor_subtotal(p_cart, c.vendor_id);
  if sub <= 0 then return jsonb_build_object('ok', false, 'error', 'This code does not apply to the items in your cart.'); end if;
  d := case when c.discount_pct is null then 0 else round(sub * c.discount_pct / 100, 2) end;
  return jsonb_build_object('ok', true, 'name', c.name, 'vendor_id', c.vendor_id, 'vendor_name', (select name from public.vendors where id = c.vendor_id),
    'discount_pct', c.discount_pct, 'subtotal_xcd', sub, 'discount_xcd', d);
end $$;

-- Orders: the discount and the tax/campaign snapshot are applied while the order row is inserted (so place_order stays as it is).
create or replace function public.orders_apply_campaign_tax() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare cid uuid; c public.campaigns; d numeric := 0; ts record;
begin
  begin cid := nullif(current_setting('cc.campaign_id', true), '')::uuid; exception when others then cid := null; end;
  if cid is not null then
    select * into c from public.campaigns where id = cid;
    if found and c.vendor_id = new.vendor_id then
      d := case when c.discount_pct is null then 0 else round(new.subtotal_xcd * c.discount_pct / 100, 2) end;
      new.discount_xcd := least(d, new.subtotal_xcd);
      new.total_xcd := greatest(0, new.total_xcd - new.discount_xcd);
      new.campaign_id := c.id;
    end if;
  end if;
  if new.tax_rate_pct is null then
    select s.tax_rate_pct, s.tax_inclusive into ts from public.vendor_tax_settings s where s.vendor_id = new.vendor_id and s.tax_rate_pct is not null;
    if found then new.tax_rate_pct := ts.tax_rate_pct; new.tax_inclusive := ts.tax_inclusive; end if;
  end if;
  return new;
end $$;
revoke all on function public.orders_apply_campaign_tax() from public, anon, authenticated;
drop trigger if exists trg_orders_apply_campaign_tax on public.orders;
create trigger trg_orders_apply_campaign_tax before insert on public.orders
  for each row execute function public.orders_apply_campaign_tax();

-- Place an order with an optional campaign code. Calls place_order() exactly as it is. Wrong/expired codes return {"error": ...}
-- and place NOTHING. The code only discounts the order of the campaign's own business; other vendors' orders in the cart are untouched.
create or replace function public.place_order_with_code(
  p_cart jsonb, p_fulfilment text, p_contact_phone text, p_delivery_address text default null, p_notes text default null,
  p_contact_name text default null, p_campaign_code text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r jsonb; c public.campaigns; res jsonb; fixed jsonb := '[]'::jsonb; el jsonb; o record;
begin
  if uid is null then raise exception 'Please log in to place an order'; end if;
  if nullif(btrim(coalesce(p_campaign_code, '')), '') is null then
    return public.place_order(p_cart, p_fulfilment, p_contact_phone, p_delivery_address, p_notes, p_contact_name);
  end if;
  perform public._pay_throttle(uid, 'campaign', 10, 'Too many wrong codes. Please wait a few minutes and try again.');
  r := public._campaign_resolve(p_campaign_code, uid, true);       -- locks the campaign row until this order commits (max_uses is race-safe)
  if r ? 'err' then
    if r ? 'bad' then insert into public.pay_attempts(user_id, kind) values (uid, 'campaign'); end if;
    return jsonb_build_object('error', r->>'err');
  end if;
  select * into c from public.campaigns where id = (r->>'id')::uuid;
  if public._cart_vendor_subtotal(p_cart, c.vendor_id) <= 0 then
    return jsonb_build_object('error', 'This code does not apply to the items in your cart.'); end if;
  perform set_config('cc.campaign_id', c.id::text, true);
  begin
    res := public.place_order(p_cart, p_fulfilment, p_contact_phone, p_delivery_address, p_notes, p_contact_name);
  exception when others then
    perform set_config('cc.campaign_id', '', true);
    raise;
  end;
  perform set_config('cc.campaign_id', '', true);
  -- max_uses is enforced against the discounted orders themselves: with the row locked, a second buyer waits and then sees this order
  for el in select * from jsonb_array_elements(res) loop
    select ord.id, ord.order_number, ord.vendor_id, ord.total_xcd, ord.discount_xcd, ord.campaign_id into o from public.orders ord where ord.id = (el->>'id')::uuid;
    fixed := fixed || jsonb_build_array((el - 'total_xcd') || jsonb_build_object('total_xcd', o.total_xcd, 'discount_xcd', o.discount_xcd, 'campaign_id', o.campaign_id));
  end loop;
  return fixed;
end $$;
revoke all on function public.place_order_with_code(jsonb, text, text, text, text, text, text) from public, anon;
grant execute on function public.place_order_with_code(jsonb, text, text, text, text, text, text) to authenticated;
revoke all on function public.check_campaign_code(text, jsonb) from public, anon;
grant execute on function public.check_campaign_code(text, jsonb) to authenticated;
revoke all on function public.vendor_product_costs(uuid) from public, anon;
grant execute on function public.vendor_product_costs(uuid) to authenticated;

-- =====================================================================================================
-- 5. POS attribution: who created each charge
-- =====================================================================================================
alter table public.pay_requests add column if not exists created_by uuid;
create or replace function public.pay_requests_set_creator() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.created_by is null then new.created_by := auth.uid(); end if;
  return new;
end $$;
revoke all on function public.pay_requests_set_creator() from public, anon, authenticated;
drop trigger if exists trg_pay_requests_set_creator on public.pay_requests;
create trigger trg_pay_requests_set_creator before insert on public.pay_requests
  for each row execute function public.pay_requests_set_creator();
create index if not exists pay_requests_creator_idx on public.pay_requests(vendor_id, created_by);

-- =====================================================================================================
-- 6. Standard analytics. All functions: SECURITY DEFINER but gated INSIDE by _std_gate():
--      logged in  +  owner or sub-admin of THAT business ('analytics' permission)  +  plan Standard or higher.
--    Sales = every order that is not cancelled and not refunded (same as Basic analytics). Days/hours are Grenada local time
--    (America/Grenada, UTC-4, no daylight saving). p_from / p_to are inclusive local dates.
-- =====================================================================================================
create or replace function public._std_gate(p_vendor uuid) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_vendor is null or not public.vendor_perm(p_vendor, 'analytics') then
    raise exception 'You do not have access to analytics for this business'; end if;
  if not public._std_tier_ok(p_vendor) then
    raise exception 'PLAN_REQUIRED: this report needs the Standard plan or higher' using errcode = '42501'; end if;
end $$;
revoke all on function public._std_gate(uuid) from public, anon, authenticated;

create or replace function public._gd_today() returns date language sql stable as $$ select (now() at time zone 'America/Grenada')::date $$;

-- ---- (1) profit per product ----
create or replace function public.vendor_profit_report(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._std_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with lines as (
    select oi.product_id, oi.product_name, oi.quantity,
           coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity)
             * (1 - case when o.subtotal_xcd > 0 then o.discount_xcd / o.subtotal_xcd else 0 end) as net,
           oi.unit_cost_xcd * oi.quantity as cost
      from public.orders o join public.order_items oi on oi.order_id = o.id
     where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  agg as (
    select product_id, max(product_name) as name, sum(quantity)::integer as qty, sum(net) as revenue,
           sum(quantity) filter (where cost is not null)::integer as qty_costed,
           sum(net) filter (where cost is not null) as rev_costed, sum(cost) as cost
      from lines group by coalesce(product_id::text, 'n:' || product_name), product_id)
  select jsonb_build_object(
    'totals', (select jsonb_build_object('revenue_xcd', round(coalesce(sum(revenue), 0), 2),
                 'revenue_costed_xcd', round(coalesce(sum(rev_costed), 0), 2), 'cost_xcd', round(coalesce(sum(cost), 0), 2),
                 'profit_xcd', round(coalesce(sum(rev_costed), 0) - coalesce(sum(cost), 0), 2),
                 'margin_pct', case when coalesce(sum(rev_costed), 0) > 0 then round((sum(rev_costed) - coalesce(sum(cost), 0)) / sum(rev_costed) * 100, 1) end,
                 'items_sold', coalesce(sum(qty), 0), 'items_costed', coalesce(sum(qty_costed), 0)) from agg),
    'products', coalesce((select jsonb_agg(jsonb_build_object('product_id', product_id, 'name', name, 'qty', qty, 'qty_costed', coalesce(qty_costed, 0),
        'revenue_xcd', round(revenue, 2), 'cost_xcd', case when cost is null then null else round(cost, 2) end,
        'profit_xcd', case when cost is null then null else round(rev_costed - cost, 2) end,
        'margin_pct', case when cost is not null and rev_costed > 0 then round((rev_costed - cost) / rev_costed * 100, 1) end)
        order by (case when cost is null then null else rev_costed - cost end) desc nulls last, revenue desc, name, product_id) from agg), '[]'::jsonb),
    'products_without_cost', (select count(*) from public.products p where p.vendor_id = p_vendor and p.active and p.cost_price is null))
  into res;
  return res;
end $$;

-- ---- (2) sales trends: last 12 months + like-for-like month-over-month and year-over-year ----
create or replace function public.vendor_sales_trends(p_vendor uuid, p_anchor date default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare today date := public._gd_today(); a date; am date; n integer; pm date; ym date; y0 date; part boolean; res jsonb;
begin
  perform public._std_gate(p_vendor);
  a := least(coalesce(p_anchor, today), today);
  if a < date '2000-01-01' then raise exception 'Choose a later month'; end if;
  am := date_trunc('month', a)::date;
  n := case when am = date_trunc('month', today)::date then extract(day from today)::integer
            else extract(day from (am + interval '1 month' - interval '1 day'))::integer end;
  part := am = date_trunc('month', today)::date;
  pm := (am - interval '1 month')::date; ym := (am - interval '1 year')::date;
  y0 := (am - interval '11 months')::date;
  with sales as (
    select (o.created_at at time zone 'America/Grenada')::date as d, o.total_xcd as t
      from public.orders o
     where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded'
       and o.created_at >= (least(ym, y0))::timestamp at time zone 'America/Grenada'
       and o.created_at < (am + interval '1 month')::timestamp at time zone 'America/Grenada'),
  months as (
    select gs::date as m, count(s.d) as orders, coalesce(sum(s.t), 0) as rev
      from generate_series(y0::timestamp, am::timestamp, interval '1 month') gs
      left join sales s on date_trunc('month', s.d)::date = gs::date group by gs),
  win as (
    select 'cur' as k, am as s, (am + n - 1)::date as e union all
    select 'prev', pm, case when part then pm + least(n, extract(day from (am - interval '1 day'))::integer) - 1 else (am - 1) end union all
    select 'yoy', ym, case when part then ym + least(n, extract(day from (ym + interval '1 month' - interval '1 day'))::integer) - 1
                           else (ym + interval '1 month' - interval '1 day')::date end),
  w as (select win.k, count(s.d) as orders, coalesce(sum(s.t), 0) as rev from win left join sales s on s.d between win.s and win.e group by win.k)
  select jsonb_build_object(
    'anchor_month', am, 'days_compared', n, 'partial', part,
    'months', (select jsonb_agg(jsonb_build_object('month', m, 'orders', orders, 'revenue_xcd', rev) order by m) from months),
    'current', (select jsonb_build_object('from', am, 'to', am + n - 1, 'orders', orders, 'revenue_xcd', rev) from w where k = 'cur'),
    'previous_month', (select jsonb_build_object('month', pm, 'orders', orders, 'revenue_xcd', rev) from w where k = 'prev'),
    'previous_year', (select jsonb_build_object('month', ym, 'orders', orders, 'revenue_xcd', rev) from w where k = 'yoy'),
    'mom_pct', (select case when p.rev > 0 then round((c.rev - p.rev) / p.rev * 100, 1) end from w c, w p where c.k = 'cur' and p.k = 'prev'),
    'yoy_pct', (select case when p.rev > 0 then round((c.rev - p.rev) / p.rev * 100, 1) end from w c, w p where c.k = 'cur' and p.k = 'yoy'))
  into res;
  return res;
end $$;

-- ---- (3) peak days and hours ----
create or replace function public.vendor_peak_times(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._std_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with s as (
    select extract(isodow from o.created_at at time zone 'America/Grenada')::integer as dow,
           extract(hour from o.created_at at time zone 'America/Grenada')::integer as hr, o.total_xcd as t
      from public.orders o
     where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  dows as (select g as dow, count(s.dow) as orders, coalesce(sum(s.t), 0) as rev from generate_series(1, 7) g left join s on s.dow = g group by g),
  hrs as (select g as hr, count(s.hr) as orders, coalesce(sum(s.t), 0) as rev from generate_series(0, 23) g left join s on s.hr = g group by g)
  select jsonb_build_object('timezone', 'America/Grenada',
    'by_dow', (select jsonb_agg(jsonb_build_object('dow', dow, 'orders', orders, 'revenue_xcd', rev) order by dow) from dows),
    'by_hour', (select jsonb_agg(jsonb_build_object('hour', hr, 'orders', orders, 'revenue_xcd', rev) order by hr) from hrs),
    'grid', coalesce((select jsonb_agg(jsonb_build_object('dow', dow, 'hour', hr, 'orders', c) order by dow, hr)
                        from (select dow, hr, count(*) as c from s group by dow, hr) x), '[]'::jsonb),
    'total_orders', (select count(*) from s))
  into res;
  return res;
end $$;

-- ---- (3b) seasonality: tourist season (Dec to Apr) vs off-season (May to Nov), last 24 months ending with the anchor month ----
create or replace function public.vendor_seasonality(p_vendor uuid, p_anchor date default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare today date := public._gd_today(); a date; e date; s date; res jsonb;
begin
  perform public._std_gate(p_vendor);
  a := least(coalesce(p_anchor, today), today);
  e := least(today, (date_trunc('month', a) + interval '1 month' - interval '1 day')::date);   -- last day counted (never the future)
  s := (date_trunc('month', a) - interval '23 months')::date;
  with days as (select gs::date as d from generate_series(s::timestamp, e::timestamp, interval '1 day') gs),
  sales as (
    select (o.created_at at time zone 'America/Grenada')::date as d, o.total_xcd as t
      from public.orders o
     where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded'
       and o.created_at >= s::timestamp at time zone 'America/Grenada' and o.created_at < (e + 1)::timestamp at time zone 'America/Grenada'),
  dd as (select d, extract(month from d)::integer as m, (extract(month from d)::integer in (12, 1, 2, 3, 4)) as tourist from days),
  by_m as (select g as m, (select count(*) from days x where extract(month from x.d)::integer = g) as ndays,
                  (select count(*) from sales z where extract(month from z.d)::integer = g) as orders,
                  (select coalesce(sum(z.t), 0) from sales z where extract(month from z.d)::integer = g) as rev
             from generate_series(1, 12) g),
  seas as (select 'tourist' as k, true as tourist union all select 'off', false)
  select jsonb_build_object('from', s, 'to', e, 'tourist_months', jsonb_build_array(12, 1, 2, 3, 4),
    'seasons', (select jsonb_agg(jsonb_build_object('season', k,
        'days', (select count(*) from dd where dd.tourist = seas.tourist),
        'orders', (select count(*) from sales z join dd on dd.d = z.d where dd.tourist = seas.tourist),
        'revenue_xcd', (select coalesce(sum(z.t), 0) from sales z join dd on dd.d = z.d where dd.tourist = seas.tourist),
        'revenue_per_day_xcd', (select round(coalesce(sum(z.t), 0) / nullif((select count(*) from dd where dd.tourist = seas.tourist), 0), 2) from sales z join dd on dd.d = z.d where dd.tourist = seas.tourist))
        order by k desc) from seas),
    'by_month', (select jsonb_agg(jsonb_build_object('month', m, 'tourist', m in (12, 1, 2, 3, 4), 'days', ndays, 'orders', orders, 'revenue_xcd', rev,
        'revenue_per_day_xcd', round(rev / nullif(ndays, 0), 2)) order by m) from by_m))
  into res;
  return res;
end $$;

-- ---- (4) staff sales, POS shifts, daily cash-up ----
-- Orders handled come from order_status_history.changed_by; POS charges from pay_requests.created_by (new in this file: charges made
-- before v1.1 have no creator and are listed as "Not recorded").
create or replace function public._std_person(p_user uuid, p_vendor uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('user_id', p_user,
    'name', case when p_user is null then 'Not recorded (before v1.1)'
                 else coalesce(nullif(btrim(p.full_name), ''), nullif(split_part(u.email, '@', 1), ''), 'Former team member') end,
    'role', case when v.owner_id = p_user then 'admin' else m.role end,
    'status', case when v.owner_id = p_user then 'active' else m.status end)
  from (select 1) x
  left join public.vendors v on v.id = p_vendor
  left join public.vendor_members m on m.vendor_id = p_vendor and m.user_id = p_user and m.role <> 'admin'
  left join public.profiles p on p.id = p_user
  left join auth.users u on u.id = p_user;
$$;
revoke all on function public._std_person(uuid, uuid) from public, anon, authenticated;

create or replace function public.vendor_staff_report(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._std_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with ord as (
    select h.changed_by as uid, h.to_status, o.id as oid, o.total_xcd, o.payment_status
      from public.order_status_history h join public.orders o on o.id = h.order_id
     where o.vendor_id = p_vendor and h.changed_at >= t0 and h.changed_at < t1 and h.changed_by is not null
       and h.to_status in ('confirmed', 'completed', 'cancelled')
       and h.changed_by is distinct from o.consumer_id),
  pos as (
    select pr.created_by as uid, pr.id, pr.status, pr.amount_cents, pr.created_at, tx.created_at as paid_at
      from public.pay_requests pr left join public.transactions tx on tx.id = pr.transaction_id
     where pr.vendor_id = p_vendor and pr.created_at >= t0 and pr.created_at < t1),
  people as (select uid from ord where uid is not null union select uid from pos),
  rows as (
    select pe.uid,
      (select count(*) from ord where ord.uid = pe.uid and to_status = 'confirmed') as accepted,
      (select count(*) from ord where ord.uid = pe.uid and to_status = 'completed') as completed,
      (select coalesce(sum(total_xcd), 0) from ord where ord.uid = pe.uid and to_status = 'completed' and payment_status <> 'refunded') as completed_xcd,
      (select count(*) from ord where ord.uid = pe.uid and to_status = 'cancelled') as cancelled,
      (select count(*) from pos where pos.uid is not distinct from pe.uid) as charges,
      (select count(*) from pos where pos.uid is not distinct from pe.uid and status = 'paid') as charges_paid,
      (select coalesce(sum(amount_cents), 0) from pos where pos.uid is not distinct from pe.uid and status = 'paid') as paid_cents
    from people pe),
  shifts as (
    select (pos.created_at at time zone 'America/Grenada')::date as day, pos.uid, min(pos.created_at) as first_at, max(pos.created_at) as last_at,
           count(*) as charges, count(*) filter (where status = 'paid') as paid_n,
           coalesce(sum(amount_cents) filter (where status = 'paid'), 0) as paid_cents,
           count(*) filter (where status = 'cancelled') as cancelled_n
      from pos group by 1, 2)
  select jsonb_build_object('timezone', 'America/Grenada', 'test_mode', true,
    'members', coalesce((select jsonb_agg((public._std_person(uid, p_vendor)) || jsonb_build_object('orders_accepted', accepted, 'orders_completed', completed,
        'orders_completed_xcd', completed_xcd, 'orders_cancelled', cancelled, 'pos_charges', charges, 'pos_paid', charges_paid, 'pos_paid_xcd', paid_cents / 100.0)
        order by completed_xcd desc, paid_cents desc, uid) from rows), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg((public._std_person(uid, p_vendor)) || jsonb_build_object('day', day, 'first_at', first_at, 'last_at', last_at,
        'charges', charges, 'paid', paid_n, 'paid_xcd', paid_cents / 100.0, 'cancelled', cancelled_n) order by day desc, first_at, uid) from shifts), '[]'::jsonb))
  into res;
  return res;
end $$;

create or replace function public.vendor_cashup(p_vendor uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; w uuid; res jsonb;
begin
  perform public._std_gate(p_vendor);
  if p_day is null then raise exception 'Choose a day'; end if;
  if p_day > public._gd_today() then raise exception 'The day cannot be in the future'; end if;
  t0 := p_day::timestamp at time zone 'America/Grenada'; t1 := (p_day + 1)::timestamp at time zone 'America/Grenada';
  select id into w from public.wallets where vendor_id = p_vendor and kind = 'vendor' order by created_at limit 1;
  with cash as (   -- orders finished that day that are paid on pickup/delivery: money the business collects itself
    select o.id, o.total_xcd, h.changed_by as uid
      from public.order_status_history h join public.orders o on o.id = h.order_id
     where o.vendor_id = p_vendor and h.to_status = 'completed' and h.changed_at >= t0 and h.changed_at < t1 and o.payment_status = 'unpaid'),
  wal as (
    select t.type, t.amount_cents, t.charge_id, t.created_by, case when t.to_wallet = w then 1 else -1 end as dir
      from public.transactions t
     where w is not null and (t.to_wallet = w or t.from_wallet = w) and t.created_at >= t0 and t.created_at < t1 and t.type in ('order_payment', 'transfer', 'refund')),
  posc as (select wal.created_by as payer, pr.created_by as uid, wal.amount_cents from wal join public.pay_requests pr on pr.id = wal.charge_id where wal.type = 'transfer' and wal.dir = 1 and wal.charge_id is not null)
  select jsonb_build_object('day', p_day, 'timezone', 'America/Grenada', 'test_mode', true,
    'cash_orders', (select count(*) from cash), 'cash_expected_xcd', (select coalesce(sum(total_xcd), 0) from cash),
    'wallet_order_payments', (select count(*) from wal where type = 'order_payment' and dir = 1),
    'wallet_order_xcd', (select coalesce(sum(amount_cents), 0) / 100.0 from wal where type = 'order_payment' and dir = 1),
    'pos_paid', (select count(*) from posc), 'pos_paid_xcd', (select coalesce(sum(amount_cents), 0) / 100.0 from posc),
    'other_wallet_in_xcd', (select coalesce(sum(amount_cents), 0) / 100.0 from wal where type = 'transfer' and dir = 1 and charge_id is null),
    'refunds', (select count(*) from wal where type = 'refund' and dir = -1), 'refunds_xcd', (select coalesce(sum(amount_cents), 0) / 100.0 from wal where type = 'refund' and dir = -1),
    'wallet_net_xcd', (select coalesce(sum(amount_cents * dir), 0) / 100.0 from wal),
    'pos_by_member', coalesce((select jsonb_agg((public._std_person(uid, p_vendor)) || jsonb_build_object('charges', c, 'xcd', s / 100.0) order by s desc, uid)
                                 from (select uid, count(*) as c, sum(amount_cents) as s from posc group by uid) x), '[]'::jsonb),
    'cash_by_member', coalesce((select jsonb_agg((public._std_person(uid, p_vendor)) || jsonb_build_object('orders', c, 'xcd', s) order by s desc, uid)
                                 from (select uid, count(*) as c, sum(total_xcd) as s from cash group by uid) x), '[]'::jsonb))
  into res;
  return res;
end $$;

-- ---- (5) customer basics: only customers who ordered from THIS business; the customer's account id/email is never returned ----
create or replace function public.vendor_customer_report(p_vendor uuid, p_from date, p_to date, p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; lim integer := least(greatest(coalesce(p_limit, 10), 1), 50); res jsonb;
begin
  perform public._std_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with s as (
    select o.consumer_id, o.created_at, o.total_xcd, o.contact_name, o.contact_phone
      from public.orders o where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  inr as (select * from s where created_at >= t0 and created_at < t1),
  cust as (
    select i.consumer_id, count(*) as orders, sum(i.total_xcd) as spent, max(i.created_at) as last_at,
           (array_agg(i.contact_name order by i.created_at desc))[1] as nm, (array_agg(i.contact_phone order by i.created_at desc))[1] as ph,
           exists (select 1 from s z where z.consumer_id = i.consumer_id and z.created_at < t0) as returning_c
      from inr i group by i.consumer_id)
  select jsonb_build_object(
    'customers', (select count(*) from cust), 'orders', (select count(*) from inr),
    'new_customers', (select count(*) from cust where not returning_c), 'returning_customers', (select count(*) from cust where returning_c),
    'new_revenue_xcd', (select coalesce(sum(spent), 0) from cust where not returning_c),
    'returning_revenue_xcd', (select coalesce(sum(spent), 0) from cust where returning_c),
    'repeat_rate_pct', (select case when count(*) > 0 then round(count(*) filter (where orders > 1 or returning_c) * 100.0 / count(*), 1) end from cust),
    'top', coalesce((select jsonb_agg(jsonb_build_object('rank', rn, 'name', coalesce(nullif(btrim(nm), ''), 'Customer'),
          'phone_hint', case when ph is not null and char_length(regexp_replace(ph, '\D', '', 'g')) >= 4 then 'ends ' || right(regexp_replace(ph, '\D', '', 'g'), 4) end,
          'orders', orders, 'spent_xcd', spent, 'last_order', last_at, 'is_new', not returning_c) order by rn)
        from (select *, row_number() over (order by spent desc, orders desc, last_at desc, consumer_id) as rn from cust) r where rn <= lim), '[]'::jsonb))
  into res;
  return res;
end $$;

-- ---- (6) campaign results (all campaigns that ran or have orders; orders counted by order date) ----
create or replace function public.vendor_campaign_report(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._std_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with s as (
    select o.id, o.campaign_id, o.consumer_id, o.total_xcd, o.discount_xcd
      from public.orders o where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  c as (
    select k.id, k.name, k.code, k.discount_pct, k.starts_on, k.ends_on, k.active, k.featured, k.max_uses,
           count(s.id) as orders, coalesce(sum(s.total_xcd), 0) as revenue, coalesce(sum(s.discount_xcd), 0) as discount, count(distinct s.consumer_id) as customers
      from public.campaigns k left join s on s.campaign_id = k.id where k.vendor_id = p_vendor
     group by k.id)
  select jsonb_build_object(
    'campaigns', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'code', code, 'discount_pct', discount_pct, 'starts_on', starts_on,
        'ends_on', ends_on, 'active', active, 'featured', featured, 'orders', orders, 'revenue_xcd', revenue, 'discount_given_xcd', discount, 'customers', customers,
        'avg_order_xcd', round(revenue / nullif(orders, 0), 2),
        'status', case when not active then 'paused' when ends_on < public._gd_today() then 'ended' when starts_on > public._gd_today() then 'scheduled' else 'running' end)
        order by orders desc, revenue desc, starts_on desc, id) from c where orders > 0 or ends_on >= p_from), '[]'::jsonb),
    'campaign_orders', (select count(*) from s where campaign_id is not null),
    'campaign_revenue_xcd', (select coalesce(sum(total_xcd), 0) from s where campaign_id is not null),
    'all_orders', (select count(*) from s), 'all_revenue_xcd', (select coalesce(sum(total_xcd), 0) from s),
    'discount_given_xcd', (select coalesce(sum(discount_xcd), 0) from s))
  into res;
  return res;
end $$;

-- ---- (7) tax summary: a summary for the vendor's records, NOT official tax advice ----
-- Each order uses the rate saved on it when it was placed (orders.tax_rate_pct); orders from before the rate was set use the business's CURRENT
-- setting. Inclusive: tax = total x r/(100+r) (prices already contain tax). Exclusive: tax = total x r/100 (the platform does not add tax to checkout totals).
create or replace function public.vendor_tax_report(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; cur record; res jsonb; lim constant integer := 5000;
begin
  perform public._std_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  select * into cur from public.vendor_tax_settings where vendor_id = p_vendor;
  with base as (
    select row_number() over (order by o.created_at desc, o.order_number)::integer as n, o.created_at as at,
           (o.created_at at time zone 'America/Grenada')::date as day, o.order_number as ref, o.total_xcd as total,
           coalesce(o.tax_rate_pct, cur.tax_rate_pct) as rate, coalesce(o.tax_inclusive, cur.tax_inclusive, true) as incl
      from public.orders o
     where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  r as (
    select base.*, case when rate is null then null when incl then round(total * rate / (100 + rate), 2) else round(total * rate / 100, 2) end as tax from base)
  select jsonb_build_object('settings', jsonb_build_object('tax_rate_pct', cur.tax_rate_pct, 'tax_inclusive', coalesce(cur.tax_inclusive, true),
         'license_number', cur.license_number, 'license_expiry', cur.license_expiry,
         'license_days_left', case when cur.license_expiry is null then null else cur.license_expiry - public._gd_today() end),
    'orders', (select count(*) from r), 'orders_without_rate', (select count(*) from r where rate is null),
    'sales_xcd', (select coalesce(sum(total), 0) from r),
    'taxed_sales_xcd', (select coalesce(sum(total), 0) from r where rate is not null),
    'tax_xcd', (select coalesce(sum(tax), 0) from r),
    'tax_inclusive_xcd', (select coalesce(sum(tax), 0) from r where incl),
    'tax_exclusive_xcd', (select coalesce(sum(tax), 0) from r where not incl),
    'by_month', coalesce((select jsonb_agg(jsonb_build_object('month', m, 'orders', c, 'sales_xcd', s, 'tax_xcd', x) order by m)
                           from (select date_trunc('month', day)::date as m, count(*) as c, sum(total) as s, coalesce(sum(tax), 0) as x from r group by 1) q), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'day', day, 'ref', ref, 'total_xcd', total, 'rate_pct', rate, 'inclusive', incl, 'tax_xcd', tax) order by n)
                       from r where n <= lim), '[]'::jsonb),
    'truncated', (select count(*) > lim from r), 'limit', lim)
  into res;
  return res;
end $$;

revoke all on function public.vendor_profit_report(uuid,date,date), public.vendor_sales_trends(uuid,date), public.vendor_peak_times(uuid,date,date),
  public.vendor_seasonality(uuid,date), public.vendor_staff_report(uuid,date,date), public.vendor_cashup(uuid,date),
  public.vendor_customer_report(uuid,date,date,integer), public.vendor_campaign_report(uuid,date,date), public.vendor_tax_report(uuid,date,date) from public, anon;
grant execute on function public.vendor_profit_report(uuid,date,date), public.vendor_sales_trends(uuid,date), public.vendor_peak_times(uuid,date,date),
  public.vendor_seasonality(uuid,date), public.vendor_staff_report(uuid,date,date), public.vendor_cashup(uuid,date),
  public.vendor_customer_report(uuid,date,date,integer), public.vendor_campaign_report(uuid,date,date), public.vendor_tax_report(uuid,date,date) to authenticated;
revoke all on function public._gd_today() from public, anon;
grant execute on function public._gd_today() to authenticated;

notify pgrst, 'reload schema';
