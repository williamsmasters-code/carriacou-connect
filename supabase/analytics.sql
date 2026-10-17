-- Carriacou Connect v0.8 : BASIC vendor analytics (every tier) + optional stock tracking
-- Run AFTER schema.sql, orders.sql, order_notes.sql and pay.sql (in that order). Safe to re-run.
-- Order to run everything on a fresh project:  schema.sql > seed.sql > storage.sql > orders.sql > order_notes.sql > pay.sql > analytics.sql
-- Re-running orders.sql or pay.sql AFTER this file is fine: they never touch the stock triggers or the analytics
-- functions below (place_order stays exactly as in orders.sql; stock is handled by triggers on order_items / orders).
-- Every UPDATE has a WHERE (Supabase runs pg-safeupdate).

-- =====================================================================================================
-- 1. Stock tracking (optional per product): stock_qty NULL = not tracked
-- =====================================================================================================
alter table public.products add column if not exists stock_qty integer;
alter table public.products add column if not exists low_stock_threshold integer default 5;
update public.products set low_stock_threshold = 5 where low_stock_threshold is null;
alter table public.products drop constraint if exists products_stock_qty_check;
alter table public.products add constraint products_stock_qty_check check (stock_qty is null or (stock_qty >= 0 and stock_qty <= 1000000));
alter table public.products drop constraint if exists products_low_stock_threshold_check;
alter table public.products add constraint products_low_stock_threshold_check check (low_stock_threshold is null or (low_stock_threshold >= 0 and low_stock_threshold <= 1000000));

-- how many units each order line took out of stock (0 = product was not tracked when ordered). Lets a cancel
-- give back exactly what was taken, once, even if the vendor started/stopped tracking in between.
alter table public.order_items add column if not exists stock_deducted integer not null default 0;

-- ---- decrement stock when order lines are created (place_order inserts them; this runs in the same transaction) ----
-- (FOR NO KEY UPDATE, not FOR UPDATE: the order_items foreign key already holds a KEY SHARE lock, and upgrading that to FOR UPDATE deadlocks.)
-- Statement-level trigger: all products in the statement are locked in id order (no deadlocks between two carts),
-- then each tracked product is checked and decremented. Not enough stock => exception => the whole order rolls back.
create or replace function public.order_items_take_stock() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record;
begin
  perform 1 from public.products p
    where p.id in (select n.product_id from new_items n where n.product_id is not null)
    order by p.id for no key update;
  for r in
    select p.id, p.name, p.stock_qty, sum(n.quantity)::integer as q
      from new_items n join public.products p on p.id = n.product_id
     where p.stock_qty is not null
     group by p.id, p.name, p.stock_qty
     order by p.id
  loop
    if r.stock_qty < r.q then
      raise exception 'Not enough stock for "%": % left, you asked for %. Lower the quantity and try again.', r.name, r.stock_qty, r.q;
    end if;
    update public.products set stock_qty = stock_qty - r.q where id = r.id;
  end loop;
  update public.order_items oi set stock_deducted = oi.quantity
    from new_items n join public.products p on p.id = n.product_id
   where oi.id = n.id and p.stock_qty is not null;
  return null;
end $$;
revoke all on function public.order_items_take_stock() from public, anon, authenticated;
drop trigger if exists trg_order_items_take_stock on public.order_items;
create trigger trg_order_items_take_stock after insert on public.order_items
  referencing new table as new_items for each statement execute function public.order_items_take_stock();

-- ---- give stock back when an order is cancelled (by the customer or the vendor) ----
-- Only a cancel restores stock. A wallet refund alone does not (the goods were handed over). Done once per order.
create or replace function public.orders_give_back_stock() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform 1 from public.products p
    where p.id in (select oi.product_id from public.order_items oi where oi.order_id = new.id and oi.stock_deducted > 0 and oi.product_id is not null)
    order by p.id for no key update;
  update public.products p set stock_qty = least(1000000, p.stock_qty + s.q)
    from (select oi.product_id, sum(oi.stock_deducted)::integer as q from public.order_items oi
           where oi.order_id = new.id and oi.stock_deducted > 0 and oi.product_id is not null group by oi.product_id) s
   where p.id = s.product_id and p.stock_qty is not null;
  update public.order_items set stock_deducted = 0 where order_id = new.id and stock_deducted > 0;
  return null;
end $$;
revoke all on function public.orders_give_back_stock() from public, anon, authenticated;
drop trigger if exists trg_orders_give_back_stock on public.orders;
create trigger trg_orders_give_back_stock after update of status on public.orders
  for each row when (new.status = 'cancelled' and old.status is distinct from 'cancelled')
  execute function public.orders_give_back_stock();

-- =====================================================================================================
-- 2. Analytics functions. SECURITY INVOKER: Row Level Security applies, AND every query is also filtered to
--    vendors owned by the caller (auth.uid()), so even an admin only sees their own business here.
--    Day boundaries use America/Grenada (UTC-4, no daylight saving). p_from / p_to are inclusive local dates.
--    Definitions (the three order groups never overlap):
--      refunded   = payment_status 'refunded' (wallet money returned)         -> shown separately
--      cancelled  = status 'cancelled' and not refunded                        -> excluded from sales
--      sales      = everything else (placed ... completed): order count, revenue (total_xcd), average order value
-- =====================================================================================================
create or replace function public._an_check(p_from date, p_to date) returns void
language plpgsql immutable set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_from is null or p_to is null then raise exception 'Choose a start and end date'; end if;
  if p_to < p_from then raise exception 'The end date is before the start date'; end if;
  if p_to - p_from > 731 then raise exception 'Date range too long (max 2 years)'; end if;
end $$;
revoke all on function public._an_check(date, date) from public, anon;
grant execute on function public._an_check(date, date) to authenticated;

create or replace function public.vendor_sales_summary(p_from date, p_to date) returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada';
  t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with mine as (
    select o.id, o.status, o.payment_status, o.total_xcd, (o.created_at at time zone 'America/Grenada')::date as d
      from public.orders o join public.vendors v on v.id = o.vendor_id
     where v.owner_id = auth.uid() and o.created_at >= t0 and o.created_at < t1),
  grp as (
    select m.*, case when m.payment_status = 'refunded' then 'refunded'
                     when m.status = 'cancelled' then 'cancelled' else 'sales' end as g from mine m),
  daily as (
    select gs::date as day, count(g.id) filter (where g.g = 'sales') as orders,
           coalesce(sum(g.total_xcd) filter (where g.g = 'sales'), 0) as rev
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') gs left join grp g on g.d = gs::date group by gs)
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', 'America/Grenada',
    'orders', (select count(*) from grp where g = 'sales'),
    'revenue_xcd', (select coalesce(sum(total_xcd), 0) from grp where g = 'sales'),
    'avg_order_xcd', (select coalesce(round(sum(total_xcd) / nullif(count(*), 0), 2), 0) from grp where g = 'sales'),
    'items_sold', (select coalesce(sum(oi.quantity), 0) from public.order_items oi join grp on grp.id = oi.order_id where grp.g = 'sales'),
    'open_orders', (select count(*) from grp where g = 'sales' and status <> 'completed'),
    'refunded_orders', (select count(*) from grp where g = 'refunded'),
    'refunded_xcd', (select coalesce(sum(total_xcd), 0) from grp where g = 'refunded'),
    'cancelled_orders', (select count(*) from grp where g = 'cancelled'),
    'cancelled_xcd', (select coalesce(sum(total_xcd), 0) from grp where g = 'cancelled'),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', day, 'orders', orders, 'revenue_xcd', rev) order by day), '[]'::jsonb) from daily))
  into res;
  return res;
end $$;

create or replace function public.vendor_top_products(p_from date, p_to date, p_limit integer default 5) returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; lim integer := least(greatest(coalesce(p_limit, 5), 1), 50); res jsonb;
begin
  perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada';
  t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with sold as (
    select oi.product_id, max(oi.product_name) as name, sum(oi.quantity)::integer as qty,
           sum(coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity)) as rev
      from public.orders o join public.vendors v on v.id = o.vendor_id join public.order_items oi on oi.order_id = o.id
     where v.owner_id = auth.uid() and o.created_at >= t0 and o.created_at < t1
       and o.status <> 'cancelled' and o.payment_status <> 'refunded'
     group by coalesce(oi.product_id::text, 'n:' || oi.product_name), oi.product_id),
  best as (select * from sold order by qty desc, rev desc, name, product_id limit lim),
  worst as (
    select p.id as product_id, p.name, coalesce(s.qty, 0) as qty, coalesce(s.rev, 0) as rev
      from public.products p join public.vendors v on v.id = p.vendor_id left join sold s on s.product_id = p.id
     where v.owner_id = auth.uid() and p.active
     order by coalesce(s.qty, 0) asc, coalesce(s.rev, 0) asc, p.name, p.id limit lim)
  select jsonb_build_object(
    'best',  (select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'name', name, 'qty', qty, 'revenue_xcd', rev) order by qty desc, rev desc, name, product_id), '[]'::jsonb) from best),
    'worst', (select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'name', name, 'qty', qty, 'revenue_xcd', rev) order by qty asc, rev asc, name, product_id), '[]'::jsonb) from worst))
  into res;
  return res;
end $$;

create or replace function public.vendor_payment_breakdown(p_from date, p_to date) returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada';
  t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with mine as (
    select o.* from public.orders o join public.vendors v on v.id = o.vendor_id
     where v.owner_id = auth.uid() and o.created_at >= t0 and o.created_at < t1),
  m(method) as (values ('pay_on_pickup'), ('pay_on_delivery'), ('pay_with_wallet'))
  select jsonb_build_object(
    'methods', (select jsonb_agg(jsonb_build_object('method', m.method,
                  'orders', (select count(*) from mine x where x.payment_method = m.method and x.status <> 'cancelled' and x.payment_status <> 'refunded'),
                  'revenue_xcd', (select coalesce(sum(x.total_xcd), 0) from mine x where x.payment_method = m.method and x.status <> 'cancelled' and x.payment_status <> 'refunded'))
                  order by m.method) from m),
    'refunds', jsonb_build_object(
       'orders', (select count(*) from mine where payment_status = 'refunded'),
       'amount_xcd', (select coalesce(sum(total_xcd), 0) from mine where payment_status = 'refunded')))
  into res;
  return res;
end $$;

create or replace function public.vendor_low_stock() returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'stock_qty', p.stock_qty,
            'low_stock_threshold', coalesce(p.low_stock_threshold, 5)) order by p.stock_qty, p.name, p.id)
     from public.products p join public.vendors v on v.id = p.vendor_id
    where v.owner_id = auth.uid() and p.active and p.stock_qty is not null
      and p.stock_qty <= coalesce(p.low_stock_threshold, 5)), '[]'::jsonb);
end $$;

-- wallet balance (TEST MODE play money) + money still to come in
create or replace function public.vendor_wallet_overview() returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare w record;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select min(w2.code) as code, sum(w2.balance_cents)::bigint as bal, count(*) as n into w
    from public.wallets w2 join public.vendors v on v.id = w2.vendor_id
   where w2.kind = 'vendor' and v.owner_id = auth.uid();
  return jsonb_build_object('test_mode', true,
    'has_wallet', w.n > 0, 'wallet_code', w.code, 'balance_cents', w.bal,
    -- customer will pay the vendor directly (cash) and the order is not finished yet
    'awaiting_cash_xcd', (select coalesce(sum(o.total_xcd), 0) from public.orders o join public.vendors v on v.id = o.vendor_id
        where v.owner_id = auth.uid() and o.status not in ('completed','cancelled') and o.payment_status = 'unpaid'),
    -- already paid from a test wallet, order still open (could still be cancelled and refunded)
    'open_wallet_paid_xcd', (select coalesce(sum(o.total_xcd), 0) from public.orders o join public.vendors v on v.id = o.vendor_id
        where v.owner_id = auth.uid() and o.status not in ('completed','cancelled') and o.payment_status = 'paid'));
end $$;

-- simple history: orders + wallet ledger rows for my business(es), newest first. Counterparty names are NOT included for wallet rows.
create or replace function public.vendor_transactions(p_from date, p_to date, p_limit integer default 1000) returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; lim integer := least(greatest(coalesce(p_limit, 1000), 1), 5000); rows jsonb; n integer;
begin
  perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada';
  t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with u as (
    select o.created_at as at, 'order'::text as kind, o.order_number as ref, o.payment_method as method, o.status as status,
           o.payment_status as payment_status, o.total_xcd as amount_xcd, coalesce(o.contact_name, '') as note
      from public.orders o join public.vendors v on v.id = o.vendor_id
     where v.owner_id = auth.uid() and o.created_at >= t0 and o.created_at < t1
    union all
    select t.created_at, 'wallet', coalesce(o.order_number, ''), t.type,
           case when t.to_wallet = w.id then 'in' else 'out' end, 'completed',
           case when t.to_wallet = w.id then 1 else -1 end * t.amount_cents / 100.0, coalesce(t.note, '')
      from public.wallets w join public.vendors v on v.id = w.vendor_id
      join public.transactions t on t.to_wallet = w.id or t.from_wallet = w.id
      left join public.orders o on o.id = t.order_id
     where w.kind = 'vendor' and v.owner_id = auth.uid() and t.created_at >= t0 and t.created_at < t1),
  lim_rows as (select * from u order by at desc, kind, ref limit lim + 1)
  select (select count(*) from lim_rows)::integer, coalesce(jsonb_agg(jsonb_build_object('at', at, 'kind', kind, 'ref', ref, 'method', method, 'status', status,
         'payment_status', payment_status, 'amount_xcd', amount_xcd, 'note', note,
         'day', (at at time zone 'America/Grenada')::date) order by at desc, kind, ref), '[]'::jsonb)
    into n, rows from (select * from lim_rows order by at desc, kind, ref limit lim) x;
  return jsonb_build_object('rows', rows, 'truncated', n > lim, 'limit', lim);
end $$;

revoke all on function public.vendor_sales_summary(date,date), public.vendor_top_products(date,date,integer),
  public.vendor_payment_breakdown(date,date), public.vendor_low_stock(), public.vendor_wallet_overview(),
  public.vendor_transactions(date,date,integer) from public, anon;
grant execute on function public.vendor_sales_summary(date,date), public.vendor_top_products(date,date,integer),
  public.vendor_payment_breakdown(date,date), public.vendor_low_stock(), public.vendor_wallet_overview(),
  public.vendor_transactions(date,date,integer) to authenticated;

notify pgrst, 'reload schema';
