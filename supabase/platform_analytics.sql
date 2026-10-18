-- Carriacou Connect v1.2 : PLATFORM-LEVEL analytics for the operator (platform admin only). TEST MODE: no real money moves.
-- Run this whole file in Supabase SQL Editor AFTER: schema -> seed -> storage -> orders -> order_notes -> pay -> analytics -> staff -> photos -> standard_analytics.
-- Safe to re-run (idempotent). It redefines NO function from an earlier file, so re-running earlier files does not undo it
-- (but if you re-run an earlier file, re-run this one last anyway).
-- Supabase uses pg-safeupdate: every UPDATE / DELETE below has a WHERE.
--
-- WHO CAN USE IT: only profiles.role = 'admin'. Every function below is SECURITY DEFINER, starts with _require_platform_admin(),
-- is REVOKEd from public and anon, and is granted to `authenticated` only so the admin's browser can call it. A vendor, staff
-- member or consumer who calls it gets "Platform admins only". The new tables have RLS on and NO policies and no grants: clients cannot read or write them directly.
--
-- DEFINITIONS (all day boundaries are America/Grenada local days, UTC-4, no daylight saving; ranges are inclusive)
--   Sample vendors (vendors.is_sample) are excluded from every metric.
--   "Sales" = orders created in the range that are NOT cancelled and NOT refunded. GMV = sum of their total_xcd (after discounts, includes delivery fee).
--   Cancelled = status 'cancelled'. Refunded = not cancelled but payment_status 'refunded'. These are shown separately and are not in GMV.
--   Wallet volume (TEST MONEY) = order payments + POS charges + person-to-person transfers. Test top-ups, refunds and adjustments are listed separately.
--   Platform fee (ESTIMATE, nothing is charged or moved): fee = round(amount x rate in force at that moment / 100, 2), per item, summed. Items = wallet-paid orders
--   (by paid_at, still 'paid', not refunded) + paid POS charges (by ledger time). Cash orders are not counted: the platform does not handle that money.
--   The rate comes from platform_fee_history (append-only), so changing the rate never rewrites earlier months. Default rate 0%.
--   Category = products.category of each order line (line_total_xcd, before any campaign discount). Orders are counted once per category.
--   Privacy: aggregates and BUSINESS names only. Customers appear only as a masked id ('user-' + 8 hex of an md5 hash); no names, emails, phones, addresses.
--   Failed code attempts (pay_attempts) are deleted by pay.sql after 1 day, so that rule can only see roughly the last 24 hours.

-- =====================================================================================================
-- 1. Config tables (changed only through admin functions)
-- =====================================================================================================
create table if not exists public.platform_settings (
  id           boolean primary key default true check (id),
  fee_rate_pct numeric(5,2) not null default 0 check (fee_rate_pct >= 0 and fee_rate_pct <= 30),
  updated_by   uuid,
  updated_at   timestamptz not null default now()
);
insert into public.platform_settings(id) values (true) on conflict (id) do nothing;

create table if not exists public.platform_fee_history (
  id             bigint generated always as identity primary key,
  effective_from timestamptz not null,
  rate_pct       numeric(5,2) not null check (rate_pct >= 0 and rate_pct <= 30),
  set_by         uuid
);
create index if not exists platform_fee_history_idx on public.platform_fee_history(effective_from desc);
insert into public.platform_fee_history(effective_from, rate_pct)
  select '2000-01-01T00:00:00Z', 0 where not exists (select 1 from public.platform_fee_history);

create table if not exists public.platform_tier_prices (
  tier              text primary key references public.tier_limits(tier) on delete cascade,
  monthly_price_xcd numeric(10,2) not null default 0 check (monthly_price_xcd >= 0 and monthly_price_xcd <= 100000),
  is_placeholder    boolean not null default true,
  updated_by        uuid,
  updated_at        timestamptz not null default now()
);
-- PLACEHOLDER prices (not decided by the operator). They stay marked as placeholders until an admin edits them.
insert into public.platform_tier_prices(tier, monthly_price_xcd) values
  ('lite', 0), ('standard', 30), ('plus', 60), ('pro', 120), ('enterprise', 300)
  on conflict (tier) do nothing;

create table if not exists public.platform_flag_config (
  key       text primary key,
  value     numeric not null,
  label     text not null,
  min_value numeric not null,
  max_value numeric not null,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  check (value >= min_value and value <= max_value)
);
insert into public.platform_flag_config(key, value, label, min_value, max_value) values
  ('window_hours',            24,   'Velocity window (hours)',                         1, 168),
  ('order_amount_xcd',        1500, 'Unusually large single order (EC$ or more)',      1, 1000000),
  ('order_velocity_count',    6,    'Orders by one customer within the window',        2, 1000),
  ('transfer_amount_xcd',     1000, 'Unusually large wallet transfer (EC$ or more)',   1, 100000),
  ('transfer_velocity_count', 10,   'Wallet transfers by one person within the window',2, 1000),
  ('cancel_refund_count',     3,    'Cancelled or refunded orders by one customer',    1, 1000),
  ('cancel_refund_ratio_pct', 50,   '...and at least this % of that customer''s orders',1, 100),
  ('failed_attempts_count',   6,    'Failed code lookups by one person (last ~24h only)',1, 1000),
  ('low_activity_max_orders', 0,    'Low activity: at most this many orders in the range',0, 1000),
  ('low_activity_min_age_days',14,  'Low activity: only businesses at least this many days old',0, 3650)
  on conflict (key) do update set label = excluded.label, min_value = excluded.min_value, max_value = excluded.max_value;

alter table public.platform_settings    enable row level security;
alter table public.platform_fee_history enable row level security;
alter table public.platform_tier_prices enable row level security;
alter table public.platform_flag_config enable row level security;
revoke all on public.platform_settings, public.platform_fee_history, public.platform_tier_prices, public.platform_flag_config from public, anon, authenticated;

create index if not exists orders_created_at_idx on public.orders(created_at);
create index if not exists transactions_created_at_idx on public.transactions(created_at);

-- =====================================================================================================
-- 2. Internal helpers (not callable by clients)
-- =====================================================================================================
create or replace function public._pa_range(p_from date, p_to date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  if p_from is null or p_to is null then raise exception 'Choose a start and end date'; end if;
  if p_to < p_from then raise exception 'The end date is before the start date'; end if;
  if p_to - p_from > 731 then raise exception 'Date range too long (max 2 years)'; end if;
  if p_to > (now() at time zone 'America/Grenada')::date then raise exception 'The end date cannot be in the future'; end if;
end $$;
revoke all on function public._pa_range(date, date) from public, anon, authenticated;

create or replace function public._pa_mask(p_id uuid) returns text
language sql immutable as $$ select case when p_id is null then null else 'user-' || left(md5(p_id::text), 8) end $$;
revoke all on function public._pa_mask(uuid) from public, anon, authenticated;

create or replace function public._pa_cfg(p_key text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$ select value from public.platform_flag_config where key = p_key $$;
revoke all on function public._pa_cfg(text) from public, anon, authenticated;

create or replace function public._pa_rate_at(p_ts timestamptz) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select rate_pct from public.platform_fee_history where effective_from <= p_ts order by effective_from desc, id desc limit 1), 0) $$;
revoke all on function public._pa_rate_at(timestamptz) from public, anon, authenticated;

-- =====================================================================================================
-- 3. Reports (platform admin only)
-- =====================================================================================================
create or replace function public.admin_pa_overview(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare lo timestamptz; hi timestamptz; r jsonb; fee numeric; fee_base numeric; fee_n int; daily jsonb;
begin
  perform public._pa_range(p_from, p_to);
  lo := p_from::timestamp at time zone 'America/Grenada';
  hi := (p_to + 1)::timestamp at time zone 'America/Grenada';
  select jsonb_build_object(
    'orders_placed',   count(*),
    'sales_orders',    count(*) filter (where o.status <> 'cancelled' and o.payment_status <> 'refunded'),
    'gmv_xcd',         coalesce(round(sum(o.total_xcd) filter (where o.status <> 'cancelled' and o.payment_status <> 'refunded'), 2), 0),
    'avg_order_xcd',   coalesce(round(avg(o.total_xcd) filter (where o.status <> 'cancelled' and o.payment_status <> 'refunded'), 2), 0),
    'cancelled_orders',count(*) filter (where o.status = 'cancelled'),
    'cancelled_xcd',   coalesce(round(sum(o.total_xcd) filter (where o.status = 'cancelled'), 2), 0),
    'refunded_orders', count(*) filter (where o.status <> 'cancelled' and o.payment_status = 'refunded'),
    'refunded_xcd',    coalesce(round(sum(o.total_xcd) filter (where o.status <> 'cancelled' and o.payment_status = 'refunded'), 2), 0),
    'delivery_orders', count(*) filter (where o.status <> 'cancelled' and o.payment_status <> 'refunded' and o.fulfilment = 'delivery'),
    'vendors_with_sales', count(distinct o.vendor_id) filter (where o.status <> 'cancelled' and o.payment_status <> 'refunded'),
    'customers_with_sales', count(distinct o.consumer_id) filter (where o.status <> 'cancelled' and o.payment_status <> 'refunded'))
  into r
  from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
  where o.created_at >= lo and o.created_at < hi;

  r := r || (select jsonb_build_object('wallet', jsonb_build_object(
      'test_mode', true,
      'volume_xcd',        round(coalesce(sum(t.amount_cents) filter (where t.type in ('order_payment') or (t.type = 'transfer')), 0) / 100.0, 2),
      'order_payments_xcd',round(coalesce(sum(t.amount_cents) filter (where t.type = 'order_payment'), 0) / 100.0, 2),
      'order_payments',    count(*) filter (where t.type = 'order_payment'),
      'pos_xcd',           round(coalesce(sum(t.amount_cents) filter (where t.type = 'transfer' and t.charge_id is not null), 0) / 100.0, 2),
      'pos_charges',       count(*) filter (where t.type = 'transfer' and t.charge_id is not null),
      'transfers_xcd',     round(coalesce(sum(t.amount_cents) filter (where t.type = 'transfer' and t.charge_id is null), 0) / 100.0, 2),
      'transfers',         count(*) filter (where t.type = 'transfer' and t.charge_id is null),
      'refunds_xcd',       round(coalesce(sum(t.amount_cents) filter (where t.type = 'refund'), 0) / 100.0, 2),
      'refunds',           count(*) filter (where t.type = 'refund'),
      'topups_xcd',        round(coalesce(sum(t.amount_cents) filter (where t.type = 'topup_test'), 0) / 100.0, 2),
      'topups',            count(*) filter (where t.type = 'topup_test'),
      'adjustments_xcd',   round(coalesce(sum(t.amount_cents) filter (where t.type = 'adjustment'), 0) / 100.0, 2)))
    from public.transactions t where t.created_at >= lo and t.created_at < hi);

  -- estimated platform fee (nothing is charged): per wallet-paid order and per paid POS charge, at the rate in force then
  select coalesce(sum(round(x.amt * public._pa_rate_at(x.ts) / 100.0, 2)), 0), coalesce(sum(x.amt), 0), count(*)
    into fee, fee_base, fee_n
  from (
    select o.total_xcd as amt, o.paid_at as ts
      from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
     where o.payment_status = 'paid' and o.status <> 'cancelled' and o.paid_at >= lo and o.paid_at < hi
    union all
    select t.amount_cents / 100.0, t.created_at
      from public.pay_requests pr join public.transactions t on t.id = pr.transaction_id join public.vendors v on v.id = pr.vendor_id and not v.is_sample
     where pr.status = 'paid' and t.created_at >= lo and t.created_at < hi
  ) x;
  r := r || jsonb_build_object('fee', jsonb_build_object('estimate', true, 'test_mode', true, 'current_rate_pct', (select fee_rate_pct from public.platform_settings where id),
      'fee_xcd', round(fee, 2), 'eligible_xcd', round(fee_base, 2), 'eligible_items', fee_n));

  select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'orders', coalesce(s.n, 0), 'gmv_xcd', coalesce(s.g, 0), 'wallet_xcd', coalesce(w.v, 0)) order by d.day), '[]'::jsonb) into daily
  from generate_series(p_from, p_to, interval '1 day') g(day0)
  cross join lateral (select g.day0::date as day) d
  left join (select (o.created_at at time zone 'America/Grenada')::date as day, count(*) as n, round(sum(o.total_xcd), 2) as g
               from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
              where o.created_at >= lo and o.created_at < hi and o.status <> 'cancelled' and o.payment_status <> 'refunded' group by 1) s on s.day = d.day
  left join (select (t.created_at at time zone 'America/Grenada')::date as day, round(sum(t.amount_cents) / 100.0, 2) as v
               from public.transactions t where t.created_at >= lo and t.created_at < hi and t.type in ('order_payment','transfer') group by 1) w on w.day = d.day;

  return r || jsonb_build_object('from', p_from, 'to', p_to, 'timezone', 'America/Grenada', 'test_mode', true, 'daily', daily);
end $$;

create or replace function public.admin_pa_growth(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare lo timestamptz; hi timestamptz; m0 date; months jsonb; r jsonb; at_start int; down int; removed int;
begin
  perform public._pa_range(p_from, p_to);
  lo := p_from::timestamp at time zone 'America/Grenada';
  hi := (p_to + 1)::timestamp at time zone 'America/Grenada';
  m0 := (date_trunc('month', p_to::timestamp) - interval '11 months')::date;
  select coalesce(jsonb_agg(jsonb_build_object('month', mm.m, 'new_vendors', coalesce(nv.n, 0), 'new_consumers', coalesce(nc.n, 0),
        'active_vendors', coalesce(av.n, 0), 'downgrades', coalesce(dg.n, 0), 'upgrades', coalesce(ug.n, 0)) order by mm.m), '[]'::jsonb) into months
  from (select (m0 + (i || ' months')::interval)::date as m from generate_series(0, 11) i) mm
  left join (select date_trunc('month', v.created_at at time zone 'America/Grenada')::date as m, count(*) n from public.vendors v where not v.is_sample group by 1) nv on nv.m = mm.m
  left join (select date_trunc('month', p.created_at at time zone 'America/Grenada')::date as m, count(*) n from public.profiles p where p.role = 'consumer' group by 1) nc on nc.m = mm.m
  left join (select date_trunc('month', o.created_at at time zone 'America/Grenada')::date as m, count(distinct o.vendor_id) n
               from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
              where o.status <> 'cancelled' and o.payment_status <> 'refunded' group by 1) av on av.m = mm.m
  left join (select date_trunc('month', a.at at time zone 'America/Grenada')::date as m, count(*) n from public.audit_log a
              where a.action = 'tier_changed' and (select rank from public.tier_limits where tier = a.details->>'to') < (select rank from public.tier_limits where tier = a.details->>'from') group by 1) dg on dg.m = mm.m
  left join (select date_trunc('month', a.at at time zone 'America/Grenada')::date as m, count(*) n from public.audit_log a
              where a.action = 'tier_changed' and (select rank from public.tier_limits where tier = a.details->>'to') > (select rank from public.tier_limits where tier = a.details->>'from') group by 1) ug on ug.m = mm.m;

  select count(*) into at_start from public.vendors v where not v.is_sample and v.created_at < lo;
  select count(distinct a.vendor_id) into down from public.audit_log a
   where a.action = 'tier_changed' and a.at >= lo and a.at < hi
     and (select rank from public.tier_limits where tier = a.details->>'to') < (select rank from public.tier_limits where tier = a.details->>'from');
  -- removed businesses: the audit log keeps the vendor id after the business row is deleted. Dated by their last audit entry (approximate).
  select count(*) into removed from (select a.vendor_id, max(a.at) last_at from public.audit_log a
     where a.vendor_id is not null and not exists (select 1 from public.vendors v where v.id = a.vendor_id) group by a.vendor_id) x
   where x.last_at >= lo and x.last_at < hi;

  r := jsonb_build_object('from', p_from, 'to', p_to, 'timezone', 'America/Grenada', 'months', months,
    'vendors_total',   (select count(*) from public.vendors v where not v.is_sample and v.created_at < hi),
    'vendors_new',     (select count(*) from public.vendors v where not v.is_sample and v.created_at >= lo and v.created_at < hi),
    'vendors_active',  (select count(distinct o.vendor_id) from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
                         where o.created_at >= lo and o.created_at < hi and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
    'consumers_total', (select count(*) from public.profiles p where p.role = 'consumer' and p.created_at < hi),
    'consumers_new',   (select count(*) from public.profiles p where p.role = 'consumer' and p.created_at >= lo and p.created_at < hi),
    'consumers_active',(select count(distinct o.consumer_id) from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
                         where o.created_at >= lo and o.created_at < hi and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
    'churn', jsonb_build_object('vendors_at_start', at_start, 'downgraded_vendors', down, 'removed_businesses', removed,
       'churn_pct', case when at_start > 0 then round((down + removed) * 100.0 / at_start, 1) end,
       'upgrades', (select count(*) from public.audit_log a where a.action = 'tier_changed' and a.at >= lo and a.at < hi
                      and (select rank from public.tier_limits where tier = a.details->>'to') > (select rank from public.tier_limits where tier = a.details->>'from'))));
  return r;
end $$;

create or replace function public.admin_pa_plans() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare tiers jsonb; mrr numeric;
begin
  perform public._require_platform_admin();
  select coalesce(jsonb_agg(jsonb_build_object('tier', tl.tier, 'label', tl.label, 'vendors', coalesce(c.n, 0), 'price_xcd', p.monthly_price_xcd,
      'is_placeholder', p.is_placeholder, 'est_monthly_xcd', round(coalesce(c.n, 0) * p.monthly_price_xcd, 2)) order by tl.rank), '[]'::jsonb),
    coalesce(sum(coalesce(c.n, 0) * p.monthly_price_xcd), 0)
    into tiers, mrr
  from public.tier_limits tl
  left join public.platform_tier_prices p on p.tier = tl.tier
  left join (select v.tier, count(*) n from public.vendors v where not v.is_sample group by v.tier) c on c.tier = tl.tier;
  return jsonb_build_object('test_mode', true, 'billing', 'none: estimate only', 'tiers', tiers, 'est_monthly_revenue_xcd', round(mrr, 2),
    'vendors_total', (select count(*) from public.vendors v where not v.is_sample),
    'pending_requests', (select count(*) from public.tier_requests where status = 'pending'),
    'approved_last_30d', (select count(*) from public.tier_requests where status = 'approved' and decided_at >= now() - interval '30 days'),
    'prices_are_placeholders', (select coalesce(bool_or(is_placeholder), true) from public.platform_tier_prices));
end $$;

create or replace function public.admin_pa_categories(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare lo timestamptz; hi timestamptz;
begin
  perform public._pa_range(p_from, p_to);
  lo := p_from::timestamp at time zone 'America/Grenada';
  hi := (p_to + 1)::timestamp at time zone 'America/Grenada';
  return jsonb_build_object('from', p_from, 'to', p_to, 'categories', coalesce((select jsonb_agg(jsonb_build_object('category', x.cat, 'orders', x.orders, 'units', x.units,
      'revenue_xcd', x.rev) order by x.rev desc, x.cat) from (
    select coalesce(p.category, 'unknown') as cat, count(distinct o.id) as orders, sum(oi.quantity) as units,
           round(sum(coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity)), 2) as rev
      from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
      join public.order_items oi on oi.order_id = o.id left join public.products p on p.id = oi.product_id
     where o.created_at >= lo and o.created_at < hi and o.status <> 'cancelled' and o.payment_status <> 'refunded'
     group by 1) x), '[]'::jsonb));
end $$;

create or replace function public.admin_pa_vendors(p_from date, p_to date, p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare lo timestamptz; hi timestamptz; lim int := least(greatest(coalesce(p_limit, 10), 1), 50); tot numeric; maxo numeric; minage numeric;
begin
  perform public._pa_range(p_from, p_to);
  lo := p_from::timestamp at time zone 'America/Grenada';
  hi := (p_to + 1)::timestamp at time zone 'America/Grenada';
  maxo := public._pa_cfg('low_activity_max_orders'); minage := public._pa_cfg('low_activity_min_age_days');
  select coalesce(sum(o.total_xcd), 0) into tot from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
   where o.created_at >= lo and o.created_at < hi and o.status <> 'cancelled' and o.payment_status <> 'refunded';
  return jsonb_build_object('from', p_from, 'to', p_to,
    'top', coalesce((select jsonb_agg(jsonb_build_object('vendor_id', t.id, 'name', t.name, 'tier', t.tier, 'orders', t.n, 'gmv_xcd', round(t.g, 2),
         'avg_order_xcd', round(t.g / t.n, 2), 'share_pct', case when tot > 0 then round(t.g * 100 / tot, 1) end) order by t.g desc, t.name)
       from (select v.id, v.name, v.tier, count(*) n, sum(o.total_xcd) g from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
              where o.created_at >= lo and o.created_at < hi and o.status <> 'cancelled' and o.payment_status <> 'refunded'
              group by v.id, v.name, v.tier order by sum(o.total_xcd) desc, v.name limit lim) t), '[]'::jsonb),
    'low_activity', coalesce((select jsonb_agg(jsonb_build_object('vendor_id', l.id, 'name', l.name, 'tier', l.tier, 'orders_in_range', l.n, 'products', l.prods,
         'created_at', l.created_at, 'last_order_at', l.last_order) order by l.n, l.created_at, l.name)
       from (select v.id, v.name, v.tier, v.created_at,
                    (select count(*) from public.orders o where o.vendor_id = v.id and o.created_at >= lo and o.created_at < hi and o.status <> 'cancelled' and o.payment_status <> 'refunded') n,
                    (select count(*) from public.products p where p.vendor_id = v.id) prods,
                    (select max(o.created_at) from public.orders o where o.vendor_id = v.id) last_order
               from public.vendors v where not v.is_sample and v.created_at < hi - (minage || ' days')::interval) l
        where l.n <= maxo), '[]'::jsonb),
    'low_activity_rule', jsonb_build_object('max_orders', maxo, 'min_age_days', minage));
end $$;

create or replace function public.admin_pa_flags(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare lo timestamptz; hi timestamptz; w interval; c_oa numeric; c_ov numeric; c_ta numeric; c_tv numeric; c_cr numeric; c_cp numeric; c_fa numeric; res jsonb;
begin
  perform public._pa_range(p_from, p_to);
  lo := p_from::timestamp at time zone 'America/Grenada';
  hi := (p_to + 1)::timestamp at time zone 'America/Grenada';
  w := (public._pa_cfg('window_hours') || ' hours')::interval;
  c_oa := public._pa_cfg('order_amount_xcd'); c_ov := public._pa_cfg('order_velocity_count'); c_ta := public._pa_cfg('transfer_amount_xcd');
  c_tv := public._pa_cfg('transfer_velocity_count'); c_cr := public._pa_cfg('cancel_refund_count'); c_cp := public._pa_cfg('cancel_refund_ratio_pct');
  c_fa := public._pa_cfg('failed_attempts_count');
  select coalesce(jsonb_agg(jsonb_build_object('rule', f.rule, 'severity', f.sev, 'subject', f.subject, 'ref', f.ref, 'vendor', f.vendor, 'value', f.val,
         'threshold', f.thr, 'at', f.at, 'detail', f.detail) order by (f.sev = 'high') desc, f.at desc nulls last, f.rule), '[]'::jsonb)
  into res
  from (
    select * from (
      -- unusually large single order
      select 'large_order'::text as rule, case when o.total_xcd >= 2 * c_oa then 'high' else 'medium' end as sev, public._pa_mask(o.consumer_id) as subject,
             o.order_number as ref, v.name as vendor, o.total_xcd as val, c_oa as thr, o.created_at as at,
             'Order total EC$' || o.total_xcd as detail
        from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
       where o.created_at >= lo and o.created_at < hi and o.total_xcd >= c_oa and o.status <> 'cancelled'
      union all
      -- order velocity: most orders by one customer in any window
      select 'order_velocity', case when z.n >= 2 * c_ov then 'high' else 'medium' end, public._pa_mask(z.consumer_id), null, null, z.n, c_ov, z.start_at,
             z.n || ' orders within ' || public._pa_cfg('window_hours') || ' hours'
        from (select distinct on (k.consumer_id) k.consumer_id, k.n, k.start_at from (
                select o1.consumer_id, o1.created_at as start_at, count(*) as n
                  from public.orders o1 join public.orders o2 on o2.consumer_id = o1.consumer_id and o2.created_at >= o1.created_at and o2.created_at < o1.created_at + w
                 where o1.created_at >= lo and o1.created_at < hi and o2.created_at < hi
                 group by o1.id, o1.consumer_id, o1.created_at having count(*) >= c_ov) k
               order by k.consumer_id, k.n desc, k.start_at) z
      union all
      select 'large_transfer', case when t.amount_cents / 100.0 >= 2 * c_ta then 'high' else 'medium' end, public._pa_mask(t.created_by), null, null, t.amount_cents / 100.0, c_ta, t.created_at,
             'Wallet transfer of EC$' || round(t.amount_cents / 100.0, 2) || ' (test money)'
        from public.transactions t
       where t.created_at >= lo and t.created_at < hi and t.type = 'transfer' and t.charge_id is null and t.amount_cents / 100.0 >= c_ta
      union all
      select 'transfer_velocity', case when z.n >= 2 * c_tv then 'high' else 'medium' end, public._pa_mask(z.uid), null, null, z.n, c_tv, z.start_at,
             z.n || ' wallet transfers within ' || public._pa_cfg('window_hours') || ' hours (test money)'
        from (select distinct on (k.uid) k.uid, k.n, k.start_at from (
                select t1.created_by as uid, t1.created_at as start_at, count(*) as n
                  from public.transactions t1 join public.transactions t2 on t2.created_by = t1.created_by and t2.type = 'transfer' and t2.charge_id is null
                       and t2.created_at >= t1.created_at and t2.created_at < t1.created_at + w
                 where t1.type = 'transfer' and t1.charge_id is null and t1.created_by is not null and t1.created_at >= lo and t1.created_at < hi and t2.created_at < hi
                 group by t1.id, t1.created_by, t1.created_at having count(*) >= c_tv) k
               order by k.uid, k.n desc, k.start_at) z
      union all
      select 'cancel_refund', case when z.bad >= 2 * c_cr then 'high' else 'medium' end, public._pa_mask(z.consumer_id), null, null, z.bad, c_cr, z.last_at,
             z.bad || ' of ' || z.total || ' orders cancelled or refunded'
        from (select o.consumer_id, count(*) total, count(*) filter (where o.status = 'cancelled' or o.payment_status = 'refunded') bad,
                     max(o.created_at) filter (where o.status = 'cancelled' or o.payment_status = 'refunded') last_at
                from public.orders o join public.vendors v on v.id = o.vendor_id and not v.is_sample
               where o.created_at >= lo and o.created_at < hi group by o.consumer_id) z
       where z.bad >= c_cr and z.bad * 100.0 / z.total >= c_cp
      union all
      select 'failed_codes', case when z.n >= 2 * c_fa then 'high' else 'medium' end, public._pa_mask(z.user_id), null, null, z.n, c_fa, z.last_at,
             z.n || ' failed code lookups (last ~24h only)'
        from (select a.user_id, count(*) n, max(a.at) last_at from public.pay_attempts a where a.at >= lo and a.at < hi group by a.user_id) z
       where z.n >= c_fa
    ) u order by (u.sev = 'high') desc, u.at desc nulls last limit 200
  ) f;
  return jsonb_build_object('from', p_from, 'to', p_to, 'timezone', 'America/Grenada', 'flags', res,
    'count', jsonb_array_length(res), 'truncated', jsonb_array_length(res) >= 200,
    'note', 'Rule-based hints only, not proof of fraud. Customers are shown as masked ids.',
    'config', (select jsonb_object_agg(key, value) from public.platform_flag_config));
end $$;

-- =====================================================================================================
-- 4. Settings: read and change (platform admin only, audited, never moves money)
-- =====================================================================================================
create or replace function public.admin_pa_settings() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  return jsonb_build_object('test_mode', true,
    'fee_rate_pct', (select fee_rate_pct from public.platform_settings where id),
    'fee_history', coalesce((select jsonb_agg(jsonb_build_object('effective_from', h.effective_from, 'rate_pct', h.rate_pct) order by h.effective_from desc, h.id desc)
                     from (select * from public.platform_fee_history order by effective_from desc, id desc limit 20) h), '[]'::jsonb),
    'tier_prices', coalesce((select jsonb_agg(jsonb_build_object('tier', p.tier, 'label', tl.label, 'monthly_price_xcd', p.monthly_price_xcd, 'is_placeholder', p.is_placeholder) order by tl.rank)
                     from public.platform_tier_prices p join public.tier_limits tl on tl.tier = p.tier), '[]'::jsonb),
    'flag_config', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'label', label, 'value', value, 'min', min_value, 'max', max_value) order by key) from public.platform_flag_config), '[]'::jsonb));
end $$;

create or replace function public.admin_pa_set_fee(p_rate numeric) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare old numeric;
begin
  perform public._require_platform_admin();
  if p_rate is null or p_rate < 0 or p_rate > 30 then raise exception 'The fee rate must be between 0 and 30 percent'; end if;
  if p_rate <> round(p_rate, 2) then raise exception 'Use at most two decimal places'; end if;
  perform pg_advisory_xact_lock(hashtext('platform_fee'));
  select fee_rate_pct into old from public.platform_settings where id;
  if old = p_rate then return jsonb_build_object('ok', true, 'unchanged', true, 'rate_pct', p_rate); end if;
  update public.platform_settings set fee_rate_pct = p_rate, updated_by = auth.uid(), updated_at = now() where id;
  insert into public.platform_fee_history(effective_from, rate_pct, set_by) values (clock_timestamp(), p_rate, auth.uid());
  perform public._audit(null, 'platform_fee_changed', null, jsonb_build_object('from', old, 'to', p_rate));
  return jsonb_build_object('ok', true, 'rate_pct', p_rate, 'note', 'Estimate only. No money is charged or moved. Earlier periods keep the rate that applied then.');
end $$;

create or replace function public.admin_pa_set_tier_price(p_tier text, p_price numeric) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  if p_price is null or p_price < 0 or p_price > 100000 then raise exception 'The price must be between 0 and 100,000'; end if;
  if p_price <> round(p_price, 2) then raise exception 'Use at most two decimal places'; end if;
  if not exists (select 1 from public.platform_tier_prices where tier = p_tier) then raise exception 'Unknown plan'; end if;
  update public.platform_tier_prices set monthly_price_xcd = p_price, is_placeholder = false, updated_by = auth.uid(), updated_at = now() where tier = p_tier;
  perform public._audit(null, 'platform_tier_price_changed', null, jsonb_build_object('tier', p_tier, 'price', p_price));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_pa_set_flag(p_key text, p_value numeric) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.platform_flag_config;
begin
  perform public._require_platform_admin();
  select * into c from public.platform_flag_config where key = p_key;
  if not found then raise exception 'Unknown setting'; end if;
  if p_value is null or p_value < c.min_value or p_value > c.max_value then raise exception 'Choose a value between % and %', c.min_value, c.max_value; end if;
  update public.platform_flag_config set value = p_value, updated_by = auth.uid(), updated_at = now() where key = p_key;
  perform public._audit(null, 'platform_flag_changed', null, jsonb_build_object('key', p_key, 'from', c.value, 'to', p_value));
  return jsonb_build_object('ok', true);
end $$;

-- =====================================================================================================
-- 5. Permissions: platform admin only (enforced inside every function; anon cannot even call them)
-- =====================================================================================================
revoke all on function public.admin_pa_overview(date,date), public.admin_pa_growth(date,date), public.admin_pa_plans(), public.admin_pa_categories(date,date),
  public.admin_pa_vendors(date,date,integer), public.admin_pa_flags(date,date), public.admin_pa_settings(), public.admin_pa_set_fee(numeric),
  public.admin_pa_set_tier_price(text,numeric), public.admin_pa_set_flag(text,numeric) from public, anon;
grant execute on function public.admin_pa_overview(date,date), public.admin_pa_growth(date,date), public.admin_pa_plans(), public.admin_pa_categories(date,date),
  public.admin_pa_vendors(date,date,integer), public.admin_pa_flags(date,date), public.admin_pa_settings(), public.admin_pa_set_fee(numeric),
  public.admin_pa_set_tier_price(text,numeric), public.admin_pa_set_flag(text,numeric) to authenticated;

notify pgrst, 'reload schema';
