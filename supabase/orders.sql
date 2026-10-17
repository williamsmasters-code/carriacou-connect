-- Carriacou Connect v0.4 : orders + checkout WITHOUT online payment
-- Run this whole file once in Supabase Dashboard > SQL Editor (after schema.sql). Safe to re-run.
-- Payment is pay_on_pickup / pay_on_delivery only. Connect Pay comes later.

-- ---------- profile: saved delivery address ----------
alter table public.profiles add column if not exists address text;

-- ---------- orders: finalize columns ----------
create sequence if not exists public.order_number_seq start 1001;

alter table public.orders add column if not exists order_number text;
alter table public.orders add column if not exists fulfilment text not null default 'pickup';
alter table public.orders add column if not exists payment_method text not null default 'pay_on_pickup';
alter table public.orders add column if not exists contact_name text;
alter table public.orders add column if not exists contact_phone text;
alter table public.orders add column if not exists delivery_address text;
alter table public.orders add column if not exists notes text;
alter table public.orders add column if not exists subtotal_xcd numeric(10,2) not null default 0;
alter table public.orders add column if not exists delivery_fee_xcd numeric(10,2) not null default 0;
alter table public.orders add column if not exists currency text not null default 'XCD';
alter table public.orders add column if not exists status_updated_at timestamptz not null default now();

-- backfill order numbers for any pre-existing rows, then default + unique
update public.orders set order_number = 'CC-' || lpad(nextval('public.order_number_seq')::text, 6, '0') where order_number is null;
alter table public.orders alter column order_number set default ('CC-' || lpad(nextval('public.order_number_seq')::text, 6, '0'));
alter table public.orders alter column order_number set not null;
create unique index if not exists orders_order_number_key on public.orders(order_number);

-- status: replace the old check (which allowed 'pending') with the final list
update public.orders set status = 'placed' where status = 'pending';
do $$ declare c record; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.orders'::regclass and contype = 'c'
             and (pg_get_constraintdef(oid) ilike '%status%' or pg_get_constraintdef(oid) ilike '%fulfilment%' or pg_get_constraintdef(oid) ilike '%payment_method%')
  loop execute format('alter table public.orders drop constraint %I', c.conname); end loop;
end $$;
alter table public.orders alter column status set default 'placed';
alter table public.orders add constraint orders_status_check
  check (status in ('placed','confirmed','ready','out_for_delivery','completed','cancelled'));
alter table public.orders add constraint orders_fulfilment_check check (fulfilment in ('pickup','delivery'));
alter table public.orders add constraint orders_payment_check check (payment_method in ('pay_on_pickup','pay_on_delivery'));
alter table public.orders add constraint orders_payment_matches check (
  (fulfilment = 'pickup' and payment_method = 'pay_on_pickup') or (fulfilment = 'delivery' and payment_method = 'pay_on_delivery'));
alter table public.orders add constraint orders_delivery_address_check check (fulfilment <> 'delivery' or char_length(coalesce(delivery_address,'')) >= 5);

-- items: snapshot of price + line total
alter table public.order_items add column if not exists line_total_xcd numeric(10,2);
update public.order_items set line_total_xcd = unit_price_xcd * quantity where line_total_xcd is null;

-- ---------- status history ----------
create table if not exists public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  from_status text,
  to_status text not null,
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now()
);
create index if not exists order_history_order_idx on public.order_status_history(order_id, changed_at);

-- ---------- status-change guard (who may move an order where) ----------
-- Clients can only update the status column (column grant below). This trigger enforces the transitions
-- and records history. Changes from the SQL editor (no logged-in user) and admins are not restricted.
create or replace function public.orders_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare is_vendor boolean; is_cons boolean; ok boolean := false;
begin
  if auth.uid() is not null and not public.is_admin() then
    if new.id is distinct from old.id or new.order_number is distinct from old.order_number
       or new.consumer_id is distinct from old.consumer_id or new.vendor_id is distinct from old.vendor_id
       or new.fulfilment is distinct from old.fulfilment or new.payment_method is distinct from old.payment_method
       or new.total_xcd is distinct from old.total_xcd or new.subtotal_xcd is distinct from old.subtotal_xcd
       or new.delivery_fee_xcd is distinct from old.delivery_fee_xcd
       or new.contact_name is distinct from old.contact_name or new.contact_phone is distinct from old.contact_phone
       or new.delivery_address is distinct from old.delivery_address or new.notes is distinct from old.notes
       or new.created_at is distinct from old.created_at then
      raise exception 'Only the order status can be changed';
    end if;
    if new.status is distinct from old.status then
      is_cons := old.consumer_id = auth.uid();
      is_vendor := exists (select 1 from public.vendors v where v.id = old.vendor_id and v.owner_id = auth.uid());
      if is_cons and old.status = 'placed' and new.status = 'cancelled' then ok := true; end if;
      if is_vendor then
        ok := ok or case
          when old.status = 'placed'    and new.status in ('confirmed','cancelled') then true
          when old.status = 'confirmed' and new.status in ('ready','cancelled') then true
          when old.status = 'ready'     and new.status = 'completed'        and old.fulfilment = 'pickup' then true
          when old.status = 'ready'     and new.status = 'out_for_delivery' and old.fulfilment = 'delivery' then true
          when old.status = 'ready'     and new.status = 'cancelled' then true
          when old.status = 'out_for_delivery' and new.status in ('completed','cancelled') then true
          else false end;
      end if;
      if not ok then
        raise exception 'This status change is not allowed (% to %)', old.status, new.status;
      end if;
    end if;
  end if;
  if new.status is distinct from old.status then
    new.status_updated_at := now();
    insert into public.order_status_history(order_id, from_status, to_status, changed_by)
    values (old.id, old.status, new.status, auth.uid());
  end if;
  return new;
end $$;
drop trigger if exists trg_orders_guard on public.orders;
create trigger trg_orders_guard before update on public.orders
  for each row execute function public.orders_before_update();

-- ---------- Row Level Security ----------
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_history enable row level security;

-- read: consumer own, vendor own business, admin
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select
  using (consumer_id = auth.uid() or public.is_admin()
         or exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()));

-- insert: NOT allowed directly. Orders are created only by place_order() below, which recomputes prices.
drop policy if exists orders_insert on public.orders;

-- update (status only, see trigger): consumer own order, vendor own business, admin
drop policy if exists orders_update on public.orders;
create policy orders_update on public.orders for update
  using (consumer_id = auth.uid() or public.is_admin()
         or exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()))
  with check (consumer_id = auth.uid() or public.is_admin()
         or exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()));

-- no delete policies on any order table (deletes are impossible for clients)
drop policy if exists orders_delete on public.orders;
drop policy if exists order_items_delete on public.order_items;

drop policy if exists order_items_select on public.order_items;
create policy order_items_select on public.order_items for select
  using (exists (select 1 from public.orders o where o.id = order_id
         and (o.consumer_id = auth.uid() or public.is_admin()
              or exists (select 1 from public.vendors v where v.id = o.vendor_id and v.owner_id = auth.uid()))));

drop policy if exists order_history_select on public.order_status_history;
create policy order_history_select on public.order_status_history for select
  using (exists (select 1 from public.orders o where o.id = order_id
         and (o.consumer_id = auth.uid() or public.is_admin()
              or exists (select 1 from public.vendors v where v.id = o.vendor_id and v.owner_id = auth.uid()))));

-- ---------- grants ----------
revoke all on public.orders, public.order_items, public.order_status_history from anon, authenticated;
grant select on public.orders, public.order_items, public.order_status_history to authenticated;
grant update (status) on public.orders to authenticated;

-- ---------- place_order(): the only way to create orders ----------
-- p_cart: json array like [{"product_id":"<uuid>","quantity":2}, ...] (an object {"<uuid>":2} also works).
-- Validates every product is active, recomputes prices from the products table (client prices are never
-- trusted), splits the cart into ONE order per vendor, and returns [{id, order_number, vendor_id, vendor_name, total_xcd}].
-- All or nothing: if any item is invalid or unavailable, nothing is created.
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
  lines jsonb := '[]'::jsonb;
  el jsonb; k text; v jsonb; pid uuid; q integer;
  vrec record; oid uuid; onum text; sub numeric(10,2);
  result jsonb := '[]'::jsonb; missing text;
begin
  if uid is null then raise exception 'Please log in to place an order'; end if;
  if p_fulfilment is null or p_fulfilment not in ('pickup','delivery') then raise exception 'Choose pickup or delivery'; end if;
  if char_length(ph) < 7 or char_length(ph) > 30 then raise exception 'Enter a contact phone number'; end if;
  if p_fulfilment = 'delivery' and (addr is null or char_length(addr) < 5) then raise exception 'Enter a delivery address'; end if;
  if p_fulfilment = 'pickup' then addr := null; end if;
  if char_length(coalesce(addr,'')) > 300 or char_length(coalesce(nts,'')) > 500 or char_length(coalesce(cname,'')) > 80 then
    raise exception 'Address, notes or name too long';
  end if;
  if p_cart is null then raise exception 'Your cart is empty'; end if;

  -- normalise the cart into lines (merge duplicates)
  create temp table if not exists _cart_lines(product_id uuid primary key, qty integer not null) on commit drop;
  delete from _cart_lines;
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
    select coalesce(sum(round(p.price_xcd * c.qty, 2)),0) into sub
      from _cart_lines c join public.products p on p.id = c.product_id where p.vendor_id = vrec.id;

    insert into public.orders(consumer_id, vendor_id, status, fulfilment, payment_method, contact_name, contact_phone,
                              delivery_address, notes, subtotal_xcd, delivery_fee_xcd, total_xcd)
    values (uid, vrec.id, 'placed', p_fulfilment,
            case p_fulfilment when 'pickup' then 'pay_on_pickup' else 'pay_on_delivery' end,
            cname, ph, addr, nts, sub, 0, sub)
    returning id, order_number into oid, onum;

    insert into public.order_items(order_id, product_id, product_name, unit_price_xcd, quantity, line_total_xcd)
    select oid, p.id, p.name, p.price_xcd, c.qty, round(p.price_xcd * c.qty, 2)
      from _cart_lines c join public.products p on p.id = c.product_id where p.vendor_id = vrec.id;

    insert into public.order_status_history(order_id, from_status, to_status, changed_by) values (oid, null, 'placed', uid);

    result := result || jsonb_build_array(jsonb_build_object('id', oid, 'order_number', onum,
              'vendor_id', vrec.id, 'vendor_name', vrec.name, 'total_xcd', sub));
  end loop;
  return result;
end $$;

revoke all on function public.place_order(jsonb, text, text, text, text, text) from public, anon;
grant execute on function public.place_order(jsonb, text, text, text, text, text) to authenticated;

-- make the API pick up the new table/columns/function right away
notify pgrst, 'reload schema';
