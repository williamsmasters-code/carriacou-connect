-- Carriacou Connect v1.3 : ADVANCED (Pro, Enterprise) and PREMIUM (Enterprise) vendor analytics. TEST MODE wallets unchanged.
-- Safe to re-run (idempotent). It contains no UPDATE and no DELETE statement (Supabase runs pg-safeupdate), and it redefines NO function
-- from an earlier file, so re-running earlier files does not undo it. Run it LAST (after platform_analytics.sql) anyway.
--
-- RUN ORDER on a fresh project:
--   schema > seed > storage > orders > order_notes > pay > analytics > staff > photos > standard_analytics > platform_analytics > advanced_analytics
-- Existing v1.2 project: just run this file.
--
-- WHO CAN USE IT: the business OWNER and SUB-ADMINS of THAT business ('analytics' permission, same as every analytics report).
--   Advanced reports   : business plan Pro or Enterprise  (tier_limits.rank >= 4)
--   Premium reports    : business plan Enterprise only    (tier_limits.rank >= 5)
-- Plan and role are checked INSIDE every function (_adv_gate / _prem_gate) and in the RLS policies of the new tables, so the website cannot
-- bypass them. Logged-out callers are refused; the functions are revoked from public and anon.
--
-- DEFINITIONS (day boundaries are America/Grenada local days, UTC-4, no daylight saving; ranges are inclusive)
--   Sales = orders that are NOT cancelled and NOT refunded (same as Basic and Standard). Revenue = orders.total_xcd.
--   COGS = order_items.unit_cost_xcd x quantity (cost snapshot taken when the order was placed). Items without a cost are NOT guessed:
--   they are reported as "revenue without a cost" and the cost coverage % is shown next to every profit number.
--   Expenses = vendor_expenses rows (entered by the owner). Do NOT enter stock purchases there: stock is already counted through product
--   cost prices (COGS), entering it again would count it twice.

-- =====================================================================================================
-- 1. Plan helpers and gates
-- =====================================================================================================
create or replace function public._adv_tier_ok(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select t.rank >= 4 from public.vendors v join public.tier_limits t on t.tier = v.tier where v.id = p_vendor), false);
$$;
create or replace function public._prem_tier_ok(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select t.rank >= 5 from public.vendors v join public.tier_limits t on t.tier = v.tier where v.id = p_vendor), false);
$$;
revoke all on function public._adv_tier_ok(uuid), public._prem_tier_ok(uuid) from public, anon;
grant execute on function public._adv_tier_ok(uuid), public._prem_tier_ok(uuid) to authenticated;   -- needed by the RLS policies below

create or replace function public._adv_gate(p_vendor uuid) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_vendor is null or not public.vendor_perm(p_vendor, 'analytics') then
    raise exception 'You do not have access to analytics for this business'; end if;
  if not public._adv_tier_ok(p_vendor) then
    raise exception 'PLAN_REQUIRED: Advanced analytics needs the Pro plan or higher' using errcode = '42501'; end if;
end $$;
create or replace function public._prem_gate(p_vendor uuid) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_vendor is null or not public.vendor_perm(p_vendor, 'analytics') then
    raise exception 'You do not have access to analytics for this business'; end if;
  if not public._prem_tier_ok(p_vendor) then
    raise exception 'PLAN_REQUIRED: Premium analytics needs the Enterprise plan' using errcode = '42501'; end if;
end $$;
revoke all on function public._adv_gate(uuid), public._prem_gate(uuid) from public, anon, authenticated;

-- =====================================================================================================
-- 2. Expense tracking (Advanced). Owner writes, owner + sub-admin read. Pro or Enterprise only.
-- =====================================================================================================
create table if not exists public.vendor_expenses (
  id          uuid primary key default gen_random_uuid(),
  vendor_id   uuid not null references public.vendors(id) on delete cascade,
  spent_on    date not null,
  category    text not null check (category in ('rent','wages','utilities','transport','marketing','fees','equipment','other')),
  description text check (description is null or char_length(description) <= 120),
  amount_xcd  numeric(12,2) not null check (amount_xcd > 0 and amount_xcd <= 10000000),
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index if not exists vendor_expenses_vendor_idx on public.vendor_expenses(vendor_id, spent_on desc);

create or replace function public.vendor_expenses_before() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.description := nullif(btrim(coalesce(new.description, '')), '');
  if new.description is not null and new.description ~ '[[:cntrl:]]' then raise exception 'The description has invalid characters'; end if;
  if new.spent_on < date '2000-01-01' or new.spent_on > public._gd_today() then raise exception 'Choose a date between 2000 and today'; end if;
  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.created_by);
    if (select count(*) from public.vendor_expenses where vendor_id = new.vendor_id) >= 20000 then
      raise exception 'A business can keep at most 20,000 expense rows'; end if;
  else
    new.vendor_id := old.vendor_id; new.created_by := old.created_by; new.created_at := old.created_at;
  end if;
  return new;
end $$;
revoke all on function public.vendor_expenses_before() from public, anon, authenticated;
drop trigger if exists trg_vendor_expenses_before on public.vendor_expenses;
create trigger trg_vendor_expenses_before before insert or update on public.vendor_expenses
  for each row execute function public.vendor_expenses_before();

alter table public.vendor_expenses enable row level security;
drop policy if exists vendor_expenses_select on public.vendor_expenses;
create policy vendor_expenses_select on public.vendor_expenses for select
  using (public.vendor_perm(vendor_id, 'analytics') and public._adv_tier_ok(vendor_id));
drop policy if exists vendor_expenses_insert on public.vendor_expenses;
create policy vendor_expenses_insert on public.vendor_expenses for insert
  with check (public.vendor_perm(vendor_id, 'vendor_edit') and public._adv_tier_ok(vendor_id));
drop policy if exists vendor_expenses_update on public.vendor_expenses;
create policy vendor_expenses_update on public.vendor_expenses for update
  using (public.vendor_perm(vendor_id, 'vendor_edit') and public._adv_tier_ok(vendor_id))
  with check (public.vendor_perm(vendor_id, 'vendor_edit') and public._adv_tier_ok(vendor_id));
drop policy if exists vendor_expenses_delete on public.vendor_expenses;
create policy vendor_expenses_delete on public.vendor_expenses for delete
  using (public.vendor_perm(vendor_id, 'vendor_edit') and public._adv_tier_ok(vendor_id));
revoke all on public.vendor_expenses from anon, authenticated;
grant select, insert, update, delete on public.vendor_expenses to authenticated;

-- =====================================================================================================
-- 3. Custom dashboard layout (Premium, Enterprise): which report cards show, in which order
-- =====================================================================================================
create table if not exists public.vendor_dashboard_prefs (
  vendor_id  uuid primary key references public.vendors(id) on delete cascade,
  widgets    jsonb not null default '[]'::jsonb,
  updated_by uuid,
  updated_at timestamptz not null default now()
);
create or replace function public.vendor_dashboard_prefs_before() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare allowed constant text[] := array['forecast','pnl','expenses','inventory','clv','accounting','benchmark','pricing','fraud','credit','export'];
        k text; seen text[] := '{}';
begin
  if jsonb_typeof(new.widgets) is distinct from 'array' then raise exception 'Widgets must be a list'; end if;
  if jsonb_array_length(new.widgets) > 11 then raise exception 'Too many widgets'; end if;
  for k in select jsonb_array_elements(new.widgets) #>> '{}' loop
    if k is null or not (k = any(allowed)) then raise exception 'Unknown widget: %', coalesce(left(k, 30), 'null'); end if;
    if k = any(seen) then raise exception 'Duplicate widget: %', k; end if;
    seen := seen || k;
  end loop;
  new.updated_by := auth.uid(); new.updated_at := now();
  return new;
end $$;
revoke all on function public.vendor_dashboard_prefs_before() from public, anon, authenticated;
drop trigger if exists trg_vendor_dashboard_prefs_before on public.vendor_dashboard_prefs;
create trigger trg_vendor_dashboard_prefs_before before insert or update on public.vendor_dashboard_prefs
  for each row execute function public.vendor_dashboard_prefs_before();
alter table public.vendor_dashboard_prefs enable row level security;
drop policy if exists dash_prefs_select on public.vendor_dashboard_prefs;
create policy dash_prefs_select on public.vendor_dashboard_prefs for select
  using (public.vendor_perm(vendor_id, 'analytics') and public._prem_tier_ok(vendor_id));
drop policy if exists dash_prefs_insert on public.vendor_dashboard_prefs;
create policy dash_prefs_insert on public.vendor_dashboard_prefs for insert
  with check (public.vendor_perm(vendor_id, 'vendor_edit') and public._prem_tier_ok(vendor_id));
drop policy if exists dash_prefs_update on public.vendor_dashboard_prefs;
create policy dash_prefs_update on public.vendor_dashboard_prefs for update
  using (public.vendor_perm(vendor_id, 'vendor_edit') and public._prem_tier_ok(vendor_id))
  with check (public.vendor_perm(vendor_id, 'vendor_edit') and public._prem_tier_ok(vendor_id));
revoke all on public.vendor_dashboard_prefs from anon, authenticated;
grant select, insert, update on public.vendor_dashboard_prefs to authenticated;

-- =====================================================================================================
-- 4. ADVANCED reports
-- =====================================================================================================

-- ---- (A1) sales forecast + cash-flow projection ----
-- Method (simple on purpose, so it can be checked by hand): history window = the last 84 days up to YESTERDAY (or since the first sale,
-- if shorter; at least 14 days needed). Forecast for each weekday = the average revenue of that weekday in the window (days with no sales
-- count as zero). Next 28 days (starting tomorrow) = sum of those weekday averages. Range = the lowest and highest full 7-day totals seen
-- in the window x 4 (shown only when the window has at least 4 full weeks). This is an ESTIMATE from past sales; it does not know about
-- holidays, campaigns or weather.
-- Cash flow = forecast revenue - estimated cost of goods (window cost % of revenue, only items with a cost) - estimated expenses (window average per day x 28).
create or replace function public.vendor_forecast(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare today date := public._gd_today(); y date; first_day date; s date; nd integer; res jsonb;
begin
  perform public._adv_gate(p_vendor);
  y := today - 1;
  select min((o.created_at at time zone 'America/Grenada')::date) into first_day
    from public.orders o where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded';
  if first_day is null or first_day > y then
    return jsonb_build_object('insufficient', true, 'days_of_history', 0, 'needed_days', 14); end if;
  s := greatest(first_day, y - 83); nd := y - s + 1;
  if nd < 14 then return jsonb_build_object('insufficient', true, 'days_of_history', nd, 'needed_days', 14); end if;
  with days as (select gs::date as d from generate_series(s::timestamp, y::timestamp, interval '1 day') gs),
  sales as (
    select o.id, (o.created_at at time zone 'America/Grenada')::date as d, o.total_xcd as t
      from public.orders o
     where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded'
       and o.created_at >= s::timestamp at time zone 'America/Grenada' and o.created_at < (y + 1)::timestamp at time zone 'America/Grenada'),
  dd as (select days.d, extract(isodow from days.d)::integer as dow, coalesce(sum(sa.t), 0) as rev, count(sa.id) as n
           from days left join sales sa on sa.d = days.d group by days.d),
  dowavg as (select dow, avg(rev) as rev, avg(n) as n, count(*) as occ from dd group by dow),
  weeks as (select (d - s) / 7 as w, sum(rev) as rev from dd group by 1 having count(*) = 7),
  fut as (select (today + g)::date as d, extract(isodow from (today + g)::date)::integer as dow, g as k from generate_series(1, 28) g),
  fc as (select fut.d, fut.dow, fut.k, dowavg.rev, dowavg.n from fut join dowavg on dowavg.dow = fut.dow),
  costs as (
    select coalesce(sum(oi.unit_cost_xcd * oi.quantity), 0) as cogs,
           coalesce(sum(coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity)
                        * (1 - case when o.subtotal_xcd > 0 then o.discount_xcd / o.subtotal_xcd else 0 end)) filter (where oi.unit_cost_xcd is not null), 0) as rev_costed
      from public.orders o join public.order_items oi on oi.order_id = o.id
     where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded'
       and o.created_at >= s::timestamp at time zone 'America/Grenada' and o.created_at < (y + 1)::timestamp at time zone 'America/Grenada'),
  exp as (select coalesce(sum(e.amount_xcd), 0) as total from public.vendor_expenses e where e.vendor_id = p_vendor and e.spent_on between s and y)
  select jsonb_build_object('insufficient', false, 'timezone', 'America/Grenada',
    'history_from', s, 'history_to', y, 'history_days', nd,
    'weekday_avg', (select jsonb_agg(jsonb_build_object('dow', dow, 'revenue_xcd', round(rev, 2), 'orders', round(n, 2)) order by dow) from dowavg),
    'next7_revenue_xcd', (select round(coalesce(sum(rev), 0), 2) from fc where k <= 7),
    'next7_orders', (select round(coalesce(sum(n), 0), 1) from fc where k <= 7),
    'next28_revenue_xcd', (select round(coalesce(sum(rev), 0), 2) from fc),
    'next28_orders', (select round(coalesce(sum(n), 0), 1) from fc),
    'full_weeks', (select count(*) from weeks),
    'next28_low_xcd', (select case when count(*) >= 4 then round(min(rev) * 4, 2) end from weeks),
    'next28_high_xcd', (select case when count(*) >= 4 then round(max(rev) * 4, 2) end from weeks),
    'days', (select jsonb_agg(jsonb_build_object('day', d, 'dow', dow, 'revenue_xcd', round(rev, 2), 'orders', round(n, 2)) order by k) from fc),
    'history_revenue_xcd', (select round(coalesce(sum(rev), 0), 2) from dd),
    'cost_ratio_pct', (select case when rev_costed > 0 then round(cogs / rev_costed * 100, 1) end from costs),
    'expenses_per_day_xcd', (select round(total / nd, 2) from exp),
    'cashflow', (select jsonb_build_object(
        'revenue_xcd', round(coalesce((select sum(rev) from fc), 0), 2),
        'cost_of_goods_xcd', round(coalesce((select sum(rev) from fc), 0) * coalesce((select cogs / nullif(rev_costed, 0) from costs), 0), 2),
        'expenses_xcd', round((select total from exp) / nd * 28, 2),
        'net_xcd', round(coalesce((select sum(rev) from fc), 0) * (1 - coalesce((select cogs / nullif(rev_costed, 0) from costs), 0)) - (select total from exp) / nd * 28, 2))))
  into res;
  return res;
end $$;

-- ---- (A2) profit and loss, by month ----
create or replace function public.vendor_pnl(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._adv_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with months as (select gs::date as m from generate_series(date_trunc('month', p_from)::timestamp, date_trunc('month', p_to)::timestamp, interval '1 month') gs),
  s as (
    select o.id, date_trunc('month', o.created_at at time zone 'America/Grenada')::date as m, o.total_xcd as rev, o.discount_xcd as disc, o.delivery_fee_xcd as dlv, o.subtotal_xcd as sub
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
  sm as (select m, count(*) as orders, sum(rev) as rev, sum(disc) as disc, sum(dlv) as dlv from s group by m),
  rows as (
    select mo.m, coalesce(sm.orders, 0) as orders, coalesce(sm.rev, 0) as rev, coalesce(sm.disc, 0) as disc, coalesce(sm.dlv, 0) as dlv,
           coalesce(l.cogs, 0) as cogs, coalesce(l.unc, 0) as unc, coalesce(l.cst, 0) as cst, coalesce(e.amt, 0) as exp
      from months mo left join sm on sm.m = mo.m left join l on l.m = mo.m left join e on e.m = mo.m)
  select jsonb_build_object('timezone', 'America/Grenada', 'from', p_from, 'to', p_to,
    'months', (select jsonb_agg(jsonb_build_object('month', m, 'orders', orders, 'revenue_xcd', rev, 'discounts_xcd', disc, 'delivery_xcd', dlv,
          'cogs_xcd', round(cogs, 2), 'uncosted_revenue_xcd', round(unc, 2), 'gross_profit_xcd', round(rev - cogs, 2),
          'expenses_xcd', exp, 'net_profit_xcd', round(rev - cogs - exp, 2)) order by m) from rows),
    'totals', (select jsonb_build_object('orders', coalesce(sum(orders), 0), 'revenue_xcd', coalesce(sum(rev), 0), 'discounts_xcd', coalesce(sum(disc), 0),
          'delivery_xcd', coalesce(sum(dlv), 0), 'cogs_xcd', round(coalesce(sum(cogs), 0), 2), 'uncosted_revenue_xcd', round(coalesce(sum(unc), 0), 2),
          'gross_profit_xcd', round(coalesce(sum(rev), 0) - coalesce(sum(cogs), 0), 2), 'expenses_xcd', coalesce(sum(exp), 0),
          'net_profit_xcd', round(coalesce(sum(rev), 0) - coalesce(sum(cogs), 0) - coalesce(sum(exp), 0), 2),
          'cost_coverage_pct', case when coalesce(sum(cst), 0) + coalesce(sum(unc), 0) > 0 then round(sum(cst) / (sum(cst) + sum(unc)) * 100, 1) end) from rows),
    'expenses_by_category', coalesce((select jsonb_agg(jsonb_build_object('category', category, 'amount_xcd', amt) order by amt desc, category)
          from (select x.category, sum(x.amount_xcd) as amt from public.vendor_expenses x
                 where x.vendor_id = p_vendor and x.spent_on between p_from and p_to group by x.category) q), '[]'::jsonb))
  into res;
  return res;
end $$;

-- ---- (A3) inventory valuation, turnover, reorder suggestions (products with stock tracking switched on) ----
-- Valuation = stock x cost price (at cost) and stock x selling price (at retail). Turnover = cost of goods sold in the range / value of stock NOW
-- (the database keeps no daily stock history, so today's stock stands in for the average; treat it as approximate). Annualised = x 365 / days.
-- Reorder: velocity = units sold / days in range. Suggested order = velocity x (lead days + cover days) - stock, rounded up.
create or replace function public.vendor_inventory_report(p_vendor uuid, p_from date, p_to date, p_lead_days integer default 7, p_cover_days integer default 14) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; nd integer; lead integer := coalesce(p_lead_days, 7); cover integer := coalesce(p_cover_days, 14); res jsonb;
begin
  perform public._adv_gate(p_vendor); perform public._an_check(p_from, p_to);
  if lead < 0 or lead > 90 then raise exception 'Delivery time must be between 0 and 90 days'; end if;
  if cover < 1 or cover > 180 then raise exception 'Days of stock to keep must be between 1 and 180'; end if;
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada'; nd := p_to - p_from + 1;
  with sold as (
    select oi.product_id, sum(oi.quantity)::integer as qty, coalesce(sum(oi.unit_cost_xcd * oi.quantity), 0) as cogs
      from public.orders o join public.order_items oi on oi.order_id = o.id
     where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded' and oi.product_id is not null
     group by oi.product_id),
  p as (
    select pr.id, pr.name, pr.stock_qty, pr.cost_price, pr.price_xcd, coalesce(sd.qty, 0) as qty, coalesce(sd.cogs, 0) as cogs,
           coalesce(sd.qty, 0)::numeric / nd as vel
      from public.products pr left join sold sd on sd.product_id = pr.id
     where pr.vendor_id = p_vendor and pr.active and pr.stock_qty is not null),
  r as (
    select p.*, case when p.cost_price is not null then round(p.stock_qty * p.cost_price, 2) end as val_cost, round(p.stock_qty * p.price_xcd, 2) as val_retail,
           case when p.vel > 0 then round(p.stock_qty / p.vel, 1) end as cover_days,
           greatest(0, ceil(p.vel * (lead + cover) - p.stock_qty))::integer as sugg,
           case when p.stock_qty = 0 and p.qty > 0 then 'out'
                when p.vel > 0 and p.stock_qty / p.vel < lead then 'reorder'
                when p.vel > 0 and p.stock_qty / p.vel < lead + cover then 'soon'
                when p.qty = 0 then 'no_sales' else 'ok' end as status
      from p)
  select jsonb_build_object('from', p_from, 'to', p_to, 'days', nd, 'lead_days', lead, 'cover_days', cover,
    'tracked_products', (select count(*) from r),
    'untracked_products', (select count(*) from public.products x where x.vendor_id = p_vendor and x.active and x.stock_qty is null),
    'products_without_cost', (select count(*) from r where cost_price is null),
    'units_in_stock', (select coalesce(sum(stock_qty), 0) from r),
    'value_at_cost_xcd', (select coalesce(sum(val_cost), 0) from r),
    'value_at_retail_xcd', (select coalesce(sum(val_retail), 0) from r),
    'cogs_xcd', (select round(coalesce(sum(cogs) filter (where cost_price is not null), 0), 2) from r),
    'turnover', (select case when sum(val_cost) > 0 then round(sum(cogs) filter (where cost_price is not null) / sum(val_cost), 2) end from r),
    'turnover_annualised', (select case when sum(val_cost) > 0 then round(sum(cogs) filter (where cost_price is not null) / sum(val_cost) * 365 / nd, 2) end from r),
    'products', coalesce((select jsonb_agg(jsonb_build_object('product_id', id, 'name', name, 'stock', stock_qty, 'cost_price', cost_price, 'price_xcd', price_xcd,
        'value_at_cost_xcd', val_cost, 'value_at_retail_xcd', val_retail, 'sold', qty, 'per_day', round(vel, 3), 'days_of_stock', cover_days,
        'suggested_order', case when status in ('out', 'reorder', 'soon') then sugg else 0 end, 'status', status,
        'turnover', case when val_cost > 0 then round(cogs / val_cost, 2) end)
        order by case status when 'out' then 0 when 'reorder' then 1 when 'soon' then 2 when 'ok' then 3 else 4 end, cover_days nulls last, name, id) from r), '[]'::jsonb))
  into res;
  return res;
end $$;

-- ---- (A4) customer lifetime value, segments, local vs overseas phone ----
-- All-time sales per customer of THIS business (the customer's account id and email are never returned).
-- Segments are checked in this order, using days since the last order (Grenada days):
--   lapsed = last order more than 120 days ago      champion = 3+ orders, last order within 30 days    loyal = 2+ orders, last within 60 days
--   at_risk = 2+ orders, last 61 to 120 days ago    new = 1 order within 30 days                       one_time = 1 order, 31 to 120 days ago
-- Phone origin is only a PROXY (a visitor may use a local SIM, a local may use an overseas number): a 7-digit number or one starting 473 / 1473
-- = local number; any other number with 10+ digits = overseas number; otherwise unknown.
create or replace function public._phone_origin(p text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case when p is null or btrim(p) = '' then 'unknown'
              when regexp_replace(p, '\D', '', 'g') ~ '^(1?473)?[0-9]{7}$' then 'local'
              when char_length(regexp_replace(p, '\D', '', 'g')) >= 10 then 'overseas'
              else 'unknown' end;
$$;
revoke all on function public._phone_origin(text) from public, anon, authenticated;

create or replace function public.vendor_clv_report(p_vendor uuid, p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare today date := public._gd_today(); lim integer := least(greatest(coalesce(p_limit, 10), 1), 50); res jsonb;
begin
  perform public._adv_gate(p_vendor);
  with s as (
    select o.consumer_id, o.created_at, (o.created_at at time zone 'America/Grenada')::date as d, o.total_xcd, o.contact_name, o.contact_phone
      from public.orders o where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  c as (
    select consumer_id, count(*) as orders, sum(total_xcd) as spent, min(d) as first_d, max(d) as last_d,
           (array_agg(contact_name order by created_at desc))[1] as nm, (array_agg(contact_phone order by created_at desc))[1] as ph
      from s group by consumer_id),
  g as (
    select c.*, today - last_d as since,
           case when today - last_d > 120 then 'lapsed'
                when orders >= 3 and today - last_d <= 30 then 'champion'
                when orders >= 2 and today - last_d <= 60 then 'loyal'
                when orders >= 2 then 'at_risk'
                when today - last_d <= 30 then 'new' else 'one_time' end as seg,
           public._phone_origin(ph) as origin
      from c),
  segs as (select * from (values ('champion', 1), ('loyal', 2), ('new', 3), ('one_time', 4), ('at_risk', 5), ('lapsed', 6)) as t(seg, ord)),
  orgs as (select * from (values ('local', 1), ('overseas', 2), ('unknown', 3)) as t(origin, ord))
  select jsonb_build_object('timezone', 'America/Grenada', 'as_of', today,
    'customers', (select count(*) from g), 'orders', (select coalesce(sum(orders), 0) from g),
    'revenue_xcd', (select coalesce(sum(spent), 0) from g),
    'avg_clv_xcd', (select round(avg(spent), 2) from g),
    'avg_orders_per_customer', (select round(avg(orders), 2) from g),
    'avg_order_xcd', (select round(sum(spent) / nullif(sum(orders), 0), 2) from g),
    'repeat_rate_pct', (select case when count(*) > 0 then round(count(*) filter (where orders > 1) * 100.0 / count(*), 1) end from g),
    'segments', (select jsonb_agg(jsonb_build_object('segment', sg.seg, 'customers', coalesce(x.n, 0), 'revenue_xcd', coalesce(x.r, 0), 'avg_clv_xcd', round(x.r / nullif(x.n, 0), 2)) order by sg.ord)
                   from segs sg left join (select seg, count(*) as n, sum(spent) as r from g group by seg) x on x.seg = sg.seg),
    'origins', (select jsonb_agg(jsonb_build_object('origin', og.origin, 'customers', coalesce(x.n, 0), 'orders', coalesce(x.o, 0), 'revenue_xcd', coalesce(x.r, 0),
                   'avg_order_xcd', round(x.r / nullif(x.o, 0), 2)) order by og.ord)
                   from orgs og left join (select origin, count(*) as n, sum(orders) as o, sum(spent) as r from g group by origin) x on x.origin = og.origin),
    'top', coalesce((select jsonb_agg(jsonb_build_object('rank', rn, 'name', coalesce(nullif(btrim(nm), ''), 'Customer'),
          'phone_hint', case when ph is not null and char_length(regexp_replace(ph, '\D', '', 'g')) >= 4 then 'ends ' || right(regexp_replace(ph, '\D', '', 'g'), 4) end,
          'orders', orders, 'spent_xcd', spent, 'first_order', first_d, 'last_order', last_d, 'days_since', since, 'segment', seg, 'origin', origin) order by rn)
        from (select *, row_number() over (order by spent desc, orders desc, last_d desc, consumer_id) as rn from g) r where rn <= lim), '[]'::jsonb))
  into res;
  return res;
end $$;

-- ---- (A5) accounting export data (QuickBooks / Xero CSV files are built in the browser from this) ----
-- One row per day and payment method (what you would see on a bank/cash statement), plus the expense rows. Nothing is sent anywhere.
create or replace function public.vendor_accounting_export(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb; lim constant integer := 5000;
begin
  perform public._adv_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with s as (
    select (o.created_at at time zone 'America/Grenada')::date as d, o.payment_method as pm, o.total_xcd as t, o.discount_xcd as disc, o.delivery_fee_xcd as dlv
      from public.orders o
     where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded'),
  ex as (
    select row_number() over (order by e.spent_on, e.created_at, e.id)::integer as n, e.spent_on, e.category, e.description, e.amount_xcd
      from public.vendor_expenses e where e.vendor_id = p_vendor and e.spent_on between p_from and p_to)
  select jsonb_build_object('timezone', 'America/Grenada', 'from', p_from, 'to', p_to,
    'sales', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'method', pm, 'orders', c, 'total_xcd', t, 'discounts_xcd', disc, 'delivery_xcd', dlv) order by d, pm)
                         from (select d, pm, count(*) as c, sum(t) as t, sum(disc) as disc, sum(dlv) as dlv from s group by d, pm) q), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('day', spent_on, 'category', category, 'description', description, 'amount_xcd', amount_xcd) order by n) from ex where n <= lim), '[]'::jsonb),
    'expenses_truncated', (select count(*) > lim from ex), 'limit', lim)
  into res;
  return res;
end $$;

-- =====================================================================================================
-- 5. PREMIUM reports (Enterprise)
-- =====================================================================================================

-- ---- (P1) benchmark against anonymous averages of similar Carriacou businesses ----
-- "Similar" = other real (non-sample) businesses, owned by someone else, whose most common ACTIVE product category is the same as yours and
-- that had at least one sale in the range. Only the median and the 25th-75th percentile band of the group are shown, and ONLY when there are
-- at least 5 such businesses (otherwise nothing about them is returned, not even their number). No peer name, id or single value is returned.
create or replace function public._bench_metrics(p_vendor uuid, p_cat text, p_owner uuid, t0 timestamptz, t1 timestamptz)
returns table(id uuid, orders bigint, rev numeric, aov numeric, problem_pct numeric, repeat_pct numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  with cats as (
    select v.id, (select x.category from public.products x where x.vendor_id = v.id and x.active group by x.category order by count(*) desc, x.category limit 1) as cat
      from public.vendors v where not v.is_sample and (v.id = p_vendor or v.owner_id is distinct from p_owner)),
  base as (
    select cs.id, o.status, o.payment_status, o.consumer_id, o.total_xcd
      from cats cs join public.orders o on o.vendor_id = cs.id
     where cs.cat is not distinct from p_cat and o.created_at >= t0 and o.created_at < t1),
  per as (
    select b.id, count(*) filter (where b.status <> 'cancelled' and b.payment_status <> 'refunded') as orders,
           coalesce(sum(b.total_xcd) filter (where b.status <> 'cancelled' and b.payment_status <> 'refunded'), 0) as rev,
           count(*) as allo, count(*) filter (where b.status = 'cancelled' or b.payment_status = 'refunded') as bad,
           count(distinct b.consumer_id) filter (where b.status <> 'cancelled' and b.payment_status <> 'refunded') as custs
      from base b group by b.id),
  rep as (
    select q.id, count(*) filter (where q.n > 1) as repeaters from (
      select b.id, b.consumer_id, count(*) as n from base b where b.status <> 'cancelled' and b.payment_status <> 'refunded' group by b.id, b.consumer_id) q group by q.id)
  select per.id, per.orders, per.rev, round(per.rev / nullif(per.orders, 0), 2), round(per.bad * 100.0 / nullif(per.allo, 0), 1),
         round(coalesce(rep.repeaters, 0) * 100.0 / nullif(per.custs, 0), 1)
    from per left join rep on rep.id = per.id where per.orders > 0 or per.id = p_vendor;
$$;
revoke all on function public._bench_metrics(uuid, text, uuid, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.vendor_benchmark(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; cat text; owner uuid; nb integer; res jsonb; minp constant integer := 5;
begin
  perform public._prem_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  select v.owner_id into owner from public.vendors v where v.id = p_vendor;
  select x.category into cat from public.products x where x.vendor_id = p_vendor and x.active group by x.category order by count(*) desc, x.category limit 1;
  nb := 0;
  if cat is not null then select count(*) into nb from public._bench_metrics(p_vendor, cat, owner, t0, t1) m where m.id <> p_vendor and m.orders > 0; end if;
  if nb < minp then
    return jsonb_build_object('available', false, 'category', cat, 'min_peers', minp, 'from', p_from, 'to', p_to,
      'yours', (select jsonb_build_object('orders', count(*) filter (where o.status <> 'cancelled' and o.payment_status <> 'refunded'),
                  'revenue_xcd', coalesce(sum(o.total_xcd) filter (where o.status <> 'cancelled' and o.payment_status <> 'refunded'), 0))
                  from public.orders o where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1));
  end if;
  with m as (select * from public._bench_metrics(p_vendor, cat, owner, t0, t1)),
  me as (select * from m where id = p_vendor),
  peers as (select * from m where id <> p_vendor and orders > 0),
  mt as (
    select * from (values
      ('orders', 'Orders', 1, true), ('revenue', 'Revenue (EC$)', 2, true), ('aov', 'Average order (EC$)', 3, true),
      ('problem_pct', 'Cancelled or refunded orders (%)', 4, false), ('repeat_pct', 'Repeat customers (%)', 5, true)) as t(k, label, ord, higher_better)),
  vals as (
    select mt.k, mt.label, mt.ord, mt.higher_better,
           case mt.k when 'orders' then (select orders from me)::numeric when 'revenue' then (select rev from me) when 'aov' then (select aov from me)
                     when 'problem_pct' then (select problem_pct from me) else (select repeat_pct from me) end as mine,
           (select array_agg(case mt.k when 'orders' then p.orders::numeric when 'revenue' then p.rev when 'aov' then p.aov when 'problem_pct' then p.problem_pct else p.repeat_pct end)
              from peers p) as arr
      from mt)
  select jsonb_build_object('available', true, 'category', cat, 'min_peers', minp, 'peer_group_size', nb, 'from', p_from, 'to', p_to,
    'metrics', (select jsonb_agg(jsonb_build_object('key', k, 'label', label, 'higher_is_better', higher_better, 'yours', mine,
        'peer_median', (select round((percentile_cont(0.5) within group (order by x))::numeric, 2) from unnest(arr) x where x is not null),
        'peer_p25', (select round((percentile_cont(0.25) within group (order by x))::numeric, 2) from unnest(arr) x where x is not null),
        'peer_p75', (select round((percentile_cont(0.75) within group (order by x))::numeric, 2) from unnest(arr) x where x is not null),
        'percentile', case when mine is null then null else
           (select round(((count(*) filter (where x < mine)) + 0.5 * (count(*) filter (where x = mine))) * 100.0 / nullif(count(*), 0), 0) from unnest(arr) x where x is not null) end)
        order by ord) from vals))
  into res;
  return res;
end $$;

-- ---- (P2) pricing and discount insights (rules-based suggestions; nothing is changed automatically) ----
-- Product rules (range = p_from..p_to, velocity = units per day):
--   raise_price : stock is tracked, stock would run out in under 14 days, and the product sells at least as fast as 75% of your products that sold
--                 (needs 4+ products with sales). Suggests +5%.
--   discount    : stock is tracked and would last 90+ days, or the product had no sales in the range and is more than 30 days old.
--                 With a cost price the safe maximum discount is half the margin (at most 20%); under 10% margin: hold.
--   hold        : otherwise.
-- Campaign check: for each campaign with a discount that has run 3+ days, revenue per day during the campaign vs the 14 days before it
-- (all your sales). It shows what happened next to a campaign, not proof that the campaign caused it.
create or replace function public.vendor_pricing_insights(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; nd integer; today date := public._gd_today(); first_day date; res jsonb;
begin
  perform public._prem_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada'; nd := p_to - p_from + 1;
  select min((o.created_at at time zone 'America/Grenada')::date) into first_day
    from public.orders o where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded';
  with sold as (
    select oi.product_id, sum(oi.quantity)::integer as qty, sum(coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity)) as rev,
           count(distinct oi.unit_price_xcd) as prices
      from public.orders o join public.order_items oi on oi.order_id = o.id
     where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1 and o.status <> 'cancelled' and o.payment_status <> 'refunded' and oi.product_id is not null
     group by oi.product_id),
  p as (
    select pr.id, pr.name, pr.price_xcd, pr.cost_price, pr.stock_qty, pr.created_at, coalesce(sd.qty, 0) as qty, coalesce(sd.rev, 0) as rev, coalesce(sd.prices, 0) as prices,
           coalesce(sd.qty, 0)::numeric / nd as vel
      from public.products pr left join sold sd on sd.product_id = pr.id where pr.vendor_id = p_vendor and pr.active),
  q as (select case when count(*) filter (where qty > 0) >= 4 then (percentile_cont(0.75) within group (order by vel) filter (where qty > 0))::numeric end as p75 from p),
  r as (
    select p.*, case when p.cost_price is not null and p.price_xcd > 0 then round((p.price_xcd - p.cost_price) / p.price_xcd * 100, 1) end as margin,
           case when p.stock_qty is not null and p.vel > 0 then p.stock_qty / p.vel end as cover,
           (select p75 from q) as p75
      from p),
  d as (
    select r.*, case
        when r.stock_qty is not null and r.cover is not null and r.cover < 14 and r.p75 is not null and r.vel >= r.p75 and r.qty > 0 then 'raise_price'
        when (r.stock_qty is not null and r.stock_qty > 0 and r.cover is not null and r.cover >= 90)
          or (r.qty = 0 and r.created_at < (p_to::timestamp at time zone 'America/Grenada') - interval '30 days') then
          case when r.margin is not null and r.margin < 10 then 'hold' else 'discount' end
        else 'hold' end as action
      from r),
  camp as (
    select k.id, k.name, k.code, k.discount_pct, k.starts_on, least(k.ends_on, today) as e_on, k.ends_on
      from public.campaigns k
     where k.vendor_id = p_vendor and k.discount_pct is not null and k.starts_on <= today
     order by k.starts_on desc, k.id limit 20),
  cres as (
    select c.*, (c.e_on - c.starts_on + 1) as ndays,
           (select coalesce(sum(o.total_xcd), 0) from public.orders o where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded'
               and (o.created_at at time zone 'America/Grenada')::date between c.starts_on and c.e_on) as rev_during,
           (select coalesce(sum(o.total_xcd), 0) from public.orders o where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded'
               and (o.created_at at time zone 'America/Grenada')::date between c.starts_on - 14 and c.starts_on - 1) as rev_before,
           (select count(*) from public.orders o where o.vendor_id = p_vendor and o.campaign_id = c.id and o.status <> 'cancelled' and o.payment_status <> 'refunded') as c_orders,
           (select coalesce(sum(o.discount_xcd), 0) from public.orders o where o.vendor_id = p_vendor and o.campaign_id = c.id and o.status <> 'cancelled' and o.payment_status <> 'refunded') as c_disc,
           (first_day is not null and first_day <= c.starts_on - 14) as has_base
      from camp c),
  cv as (
    select cres.*, case when cres.has_base and cres.ndays >= 3 and cres.rev_before > 0
                then round(((cres.rev_during / cres.ndays) - (cres.rev_before / 14.0)) / (cres.rev_before / 14.0) * 100, 1) end as lift
      from cres)
  select jsonb_build_object('from', p_from, 'to', p_to, 'days', nd,
    'products', coalesce((select jsonb_agg(jsonb_build_object('product_id', id, 'name', name, 'price_xcd', price_xcd, 'cost_price', cost_price, 'margin_pct', margin,
        'sold', qty, 'revenue_xcd', rev, 'per_day', round(vel, 3), 'stock', stock_qty, 'days_of_stock', case when cover is null then null else round(cover, 1) end,
        'prices_seen', prices, 'action', action,
        'suggested_price_xcd', case when action = 'raise_price' then round(price_xcd * 1.05, 2) end,
        'max_discount_pct', case when action = 'discount' and margin is not null then least(20, floor(margin / 2)) end)
        order by case action when 'raise_price' then 0 when 'discount' then 1 else 2 end, vel desc, name, id) from d), '[]'::jsonb),
    'demand_threshold_per_day', (select case when p75 is null then null else round(p75, 3) end from q),
    'campaigns', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'code', code, 'discount_pct', discount_pct, 'starts_on', starts_on, 'ends_on', ends_on,
        'days_run', ndays, 'orders', c_orders, 'discount_given_xcd', c_disc, 'revenue_per_day_during_xcd', round(rev_during / ndays, 2),
        'revenue_per_day_before_xcd', case when has_base then round(rev_before / 14.0, 2) end, 'lift_pct', lift,
        'verdict', case when ndays < 3 then 'too_early' when not has_base or rev_before <= 0 then 'no_baseline'
                        when lift >= 20 then 'lift' when lift <= -10 then 'down' else 'flat' end) order by starts_on desc, id) from cv), '[]'::jsonb))
  into res;
  return res;
end $$;

-- ---- (P3) fraud monitoring on YOUR orders (window = last p_days Grenada days, 1 to 90) ----
-- Fixed rules, all explained on screen:
--   customer_cancels : a customer who cancelled 3+ of their own orders (cancelled by the customer, not by you)
--   refund_rate      : 3+ refunded orders and refunds are at least 10% of orders
--   big_first_order  : a first-ever order from a customer worth at least EC$100 and at least 3x your average order (last 90 days)
--   shared_phone     : the same phone number (last 7 digits) used by 3+ different accounts
--   order_burst      : 5+ orders from one customer within one hour
-- CHARGEBACKS: Connect Pay is play money and no card payments exist yet, so there are no chargebacks to monitor. Refunds and customer
-- cancellations are shown as the nearest signal. A flag is a prompt to take a look, not proof of fraud.
create or replace function public.vendor_fraud_monitor(p_vendor uuid, p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare today date := public._gd_today(); nd integer := least(greatest(coalesce(p_days, 30), 1), 90); t0 timestamptz; t1 timestamptz; res jsonb; avg_order numeric;
begin
  perform public._prem_gate(p_vendor);
  t0 := (today - nd + 1)::timestamp at time zone 'America/Grenada'; t1 := (today + 1)::timestamp at time zone 'America/Grenada';
  select avg(o.total_xcd) into avg_order from public.orders o
   where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded' and o.created_at >= (today - 89)::timestamp at time zone 'America/Grenada' and o.created_at < t1;
  with w as (
    select o.id, o.order_number, o.consumer_id, o.created_at, o.status, o.payment_status, o.total_xcd, o.contact_name,
           regexp_replace(coalesce(o.contact_phone, ''), '\D', '', 'g') as dig
      from public.orders o where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1),
  cx as (
    select w.* from w where w.status = 'cancelled'
       and exists (select 1 from public.order_status_history h where h.order_id = w.id and h.to_status = 'cancelled' and h.changed_by = w.consumer_id)),
  cc as (
    select consumer_id, count(*) as n, sum(total_xcd) as val, (array_agg(contact_name order by created_at desc))[1] as nm, (array_agg(dig order by created_at desc))[1] as dg
      from cx group by consumer_id having count(*) >= 3),
  stats as (select (select count(*) from w) as orders, (select count(*) from w where payment_status = 'refunded') as refunded, (select count(*) from cx) as cust_cancelled),
  bf as (
    select w.order_number, w.total_xcd, w.contact_name, w.dig, w.created_at
      from w where w.status <> 'cancelled' and w.payment_status <> 'refunded'
       and not exists (select 1 from public.orders p where p.vendor_id = p_vendor and p.consumer_id = w.consumer_id and p.created_at < w.created_at and p.status <> 'cancelled')
       and w.total_xcd >= 100 and avg_order is not null and w.total_xcd >= 3 * avg_order),
  sp as (
    select right(dig, 7) as k, count(distinct consumer_id) as accounts, count(*) as n, (array_agg(contact_name order by created_at desc))[1] as nm, (array_agg(dig order by created_at desc))[1] as dg
      from w where char_length(dig) >= 7 group by right(dig, 7) having count(distinct consumer_id) >= 3),
  bu as (
    select w1.consumer_id, max(w1.burst) as n, (array_agg(w1.contact_name order by w1.created_at desc))[1] as nm
      from (select w.*, (select count(*) from w w2 where w2.consumer_id = w.consumer_id and w2.created_at >= w.created_at and w2.created_at < w.created_at + interval '1 hour') as burst from w) w1
     where w1.burst >= 5 group by w1.consumer_id)
  select jsonb_build_object('timezone', 'America/Grenada', 'days', nd, 'from', today - nd + 1, 'to', today,
    'orders', (select orders from stats), 'refunded_orders', (select refunded from stats), 'customer_cancelled_orders', (select cust_cancelled from stats),
    'chargebacks_supported', false,
    'chargeback_note', 'Connect Pay is play money and no card payments exist yet, so there are no chargebacks. Refunds and customer cancellations are the nearest signal.',
    'refund_rate_pct', (select case when orders > 0 then round(refunded * 100.0 / orders, 1) end from stats),
    'flag_refund_rate', (select refunded >= 3 and refunded * 100.0 / nullif(orders, 0) >= 10 from stats),
    'customer_cancels', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(nullif(btrim(nm), ''), 'Customer'), 'phone_hint', case when char_length(dg) >= 4 then 'ends ' || right(dg, 4) end,
        'cancelled', n, 'value_xcd', val) order by n desc, val desc, consumer_id) from cc), '[]'::jsonb),
    'big_first_orders', coalesce((select jsonb_agg(jsonb_build_object('order', order_number, 'name', coalesce(nullif(btrim(contact_name), ''), 'Customer'),
        'phone_hint', case when char_length(dig) >= 4 then 'ends ' || right(dig, 4) end, 'total_xcd', total_xcd, 'at', created_at) order by total_xcd desc, order_number) from bf), '[]'::jsonb),
    'shared_phones', coalesce((select jsonb_agg(jsonb_build_object('phone_hint', 'ends ' || right(dg, 4), 'accounts', accounts, 'orders', n, 'name', coalesce(nullif(btrim(nm), ''), 'Customer')) order by accounts desc, n desc, k) from sp), '[]'::jsonb),
    'order_bursts', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(nullif(btrim(nm), ''), 'Customer'), 'orders_in_an_hour', n) order by n desc, consumer_id) from bu), '[]'::jsonb),
    'flag_count', (select count(*) from cc) + (select count(*) from bf) + (select count(*) from sp) + (select count(*) from bu)
                  + (select case when refunded >= 3 and refunded * 100.0 / nullif(orders, 0) >= 10 then 1 else 0 end from stats))
  into res;
  return res;
end $$;

-- ---- (P4) loan / credit-readiness report ----
-- A transparent 100-point checklist over the last 12 months (Grenada months, current month included). It is NOT a credit score and no lender
-- uses it automatically: it is a summary a business can print and bring to a lender. Points:
--   30 trading history   30 x (months with sales, max 12) / 12
--   15 steady sales      variation of monthly revenue over completed months (needs 3+): <=30% 15, <=60% 9, <=100% 4, else 0
--   15 growth            last 3 completed months vs the 3 before (needs 6+ completed months): >=0% 15, >=-20% 8, else 0
--   15 clean orders      cancelled or refunded share of all orders (needs 10+ orders): <=5% 15, <=10% 8, else 0
--   10 repeat customers  share of customers who bought twice or more (needs 5+ customers): >=30% 10, >=15% 5, else 0
--    5 expense records   expenses entered in 3 or more of the last 6 months
--    5 costs known       at least 80% of units sold had a cost price
--    5 licence current   licence number saved and not expired (Tax and license settings)
-- 70+ Strong, 40-69 Building, below 40 Early.
create or replace function public.vendor_credit_readiness(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare today date := public._gd_today(); m0 date; cm date; t0 timestamptz; t1 timestamptz; fm date; mj jsonb; first_sale date;
  ncomp integer; avgm numeric; cv numeric; g_cur numeric; g_prev numeric; growth numeric; n_all integer; n_bad integer; n_cust integer; n_rep integer;
  months_sales integer; exp_months integer; units integer; units_c integer; lic record; rev12 numeric; cogs12 numeric; exp12 numeric;
  p_hist integer; p_stab integer; p_grow integer; p_clean integer; p_rep integer; p_exp integer; p_cost integer; p_lic integer;
  prob numeric; repr numeric; costpct numeric; total integer; comps jsonb;
begin
  perform public._prem_gate(p_vendor);
  cm := date_trunc('month', today)::date; m0 := (cm - interval '11 months')::date;
  t0 := m0::timestamp at time zone 'America/Grenada'; t1 := (today + 1)::timestamp at time zone 'America/Grenada';
  select min((o.created_at at time zone 'America/Grenada')::date) into first_sale
    from public.orders o where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded';
  select jsonb_agg(jsonb_build_object('m', g::date, 'rev', coalesce((select sum(o.total_xcd) from public.orders o where o.vendor_id = p_vendor
          and o.status <> 'cancelled' and o.payment_status <> 'refunded' and date_trunc('month', o.created_at at time zone 'America/Grenada')::date = g::date), 0)) order by g)
    into mj from generate_series(m0::timestamp, cm::timestamp, interval '1 month') g;
  select coalesce(sum(x.rev), 0), count(*) filter (where x.rev > 0) into rev12, months_sales from jsonb_to_recordset(mj) as x(m date, rev numeric);
  fm := case when first_sale is null then null else greatest(m0, date_trunc('month', first_sale)::date) end;   -- first month that counts for stability / growth
  select count(*), avg(x.rev), case when avg(x.rev) > 0 then stddev_pop(x.rev) / avg(x.rev) end into ncomp, avgm, cv
    from jsonb_to_recordset(mj) as x(m date, rev numeric) where fm is not null and x.m >= fm and x.m < cm;
  select coalesce(sum(q.rev), 0) into g_cur from (select x.rev from jsonb_to_recordset(mj) as x(m date, rev numeric) where fm is not null and x.m >= fm and x.m < cm order by x.m desc limit 3) q;
  select coalesce(sum(q.rev), 0) into g_prev from (select x.rev from jsonb_to_recordset(mj) as x(m date, rev numeric) where fm is not null and x.m >= fm and x.m < cm order by x.m desc offset 3 limit 3) q;
  growth := case when ncomp >= 6 and g_prev > 0 then round((g_cur - g_prev) / g_prev * 100, 1) end;
  select count(*), count(*) filter (where o.status = 'cancelled' or o.payment_status = 'refunded') into n_all, n_bad
    from public.orders o where o.vendor_id = p_vendor and o.created_at >= t0 and o.created_at < t1;
  prob := case when n_all >= 10 then round(n_bad * 100.0 / n_all, 1) end;
  select count(*), count(*) filter (where q.n > 1) into n_cust, n_rep from (
    select o.consumer_id, count(*) as n from public.orders o where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded'
       and o.created_at >= t0 and o.created_at < t1 group by o.consumer_id) q;
  repr := case when n_cust >= 5 then round(n_rep * 100.0 / n_cust, 1) end;
  select count(distinct date_trunc('month', e.spent_on)) into exp_months from public.vendor_expenses e
   where e.vendor_id = p_vendor and e.spent_on >= (cm - interval '5 months')::date and e.spent_on <= today;
  select coalesce(sum(oi.quantity), 0), coalesce(sum(oi.quantity) filter (where oi.unit_cost_xcd is not null), 0), coalesce(sum(oi.unit_cost_xcd * oi.quantity), 0)
    into units, units_c, cogs12
    from public.orders o join public.order_items oi on oi.order_id = o.id
   where o.vendor_id = p_vendor and o.status <> 'cancelled' and o.payment_status <> 'refunded' and o.created_at >= t0 and o.created_at < t1;
  costpct := case when units > 0 then round(units_c * 100.0 / units, 1) end;
  select coalesce(sum(e.amount_xcd), 0) into exp12 from public.vendor_expenses e where e.vendor_id = p_vendor and e.spent_on >= m0 and e.spent_on <= today;
  select s.license_number, s.license_expiry into lic from public.vendor_tax_settings s where s.vendor_id = p_vendor;

  p_hist := round(30 * least(months_sales, 12) / 12.0);
  p_stab := case when ncomp >= 3 and cv is not null then (case when cv <= 0.3 then 15 when cv <= 0.6 then 9 when cv <= 1.0 then 4 else 0 end) else 0 end;
  p_grow := case when growth is not null then (case when growth >= 0 then 15 when growth >= -20 then 8 else 0 end) else 0 end;
  p_clean := case when prob is not null then (case when prob <= 5 then 15 when prob <= 10 then 8 else 0 end) else 0 end;
  p_rep := case when repr is not null then (case when repr >= 30 then 10 when repr >= 15 then 5 else 0 end) else 0 end;
  p_exp := case when exp_months >= 3 then 5 else 0 end;
  p_cost := case when costpct is not null and costpct >= 80 then 5 else 0 end;
  p_lic := case when lic.license_number is not null and lic.license_expiry is not null and lic.license_expiry >= today then 5 else 0 end;
  total := p_hist + p_stab + p_grow + p_clean + p_rep + p_exp + p_cost + p_lic;
  comps := jsonb_build_array(
    jsonb_build_object('key', 'history', 'label', 'Trading history', 'points', p_hist, 'max', 30, 'value', months_sales, 'unit', 'of the last 12 months had sales', 'scored', true,
      'tip', 'Keep trading through Connect: each month with a sale adds 2.5 points (up to 12 months).'),
    jsonb_build_object('key', 'steady', 'label', 'Steady sales', 'points', p_stab, 'max', 15, 'value', case when cv is null then null else round(cv * 100, 0) end, 'unit', '% variation between months',
      'scored', ncomp >= 3 and cv is not null, 'tip', 'Needs 3 completed months of sales. Lower variation between months scores higher.'),
    jsonb_build_object('key', 'growth', 'label', 'Growth', 'points', p_grow, 'max', 15, 'value', growth, 'unit', '% last 3 months vs the 3 before',
      'scored', growth is not null, 'tip', 'Needs 6 completed months of sales.'),
    jsonb_build_object('key', 'clean', 'label', 'Clean orders', 'points', p_clean, 'max', 15, 'value', prob, 'unit', '% cancelled or refunded',
      'scored', prob is not null, 'tip', 'Needs 10 orders in the last 12 months. 5% or less scores full points.'),
    jsonb_build_object('key', 'repeat', 'label', 'Repeat customers', 'points', p_rep, 'max', 10, 'value', repr, 'unit', '% of customers bought twice or more',
      'scored', repr is not null, 'tip', 'Needs 5 customers. 30% or more scores full points.'),
    jsonb_build_object('key', 'expenses', 'label', 'Expense records', 'points', p_exp, 'max', 5, 'value', exp_months, 'unit', 'of the last 6 months have expenses entered', 'scored', true,
      'tip', 'Enter your expenses in the Expenses section for at least 3 of the last 6 months.'),
    jsonb_build_object('key', 'costs', 'label', 'Costs known', 'points', p_cost, 'max', 5, 'value', costpct, 'unit', '% of items sold had a cost price',
      'scored', costpct is not null, 'tip', 'Add a cost price to your products (80% or more of items sold).'),
    jsonb_build_object('key', 'licence', 'label', 'Licence current', 'points', p_lic, 'max', 5, 'value', case when lic.license_expiry is null then null else (lic.license_expiry - today) end,
      'unit', 'days until the licence expires', 'scored', lic.license_expiry is not null, 'tip', 'Save your licence number and a future expiry date under Tax and license.'));
  return jsonb_build_object('timezone', 'America/Grenada', 'as_of', today, 'window_from', m0, 'window_to', today,
    'score', total, 'band', case when total >= 70 then 'strong' when total >= 40 then 'building' else 'early' end,
    'components', comps,
    'facts', jsonb_build_object('first_sale', first_sale, 'months_with_sales', months_sales, 'revenue_12m_xcd', rev12, 'avg_monthly_revenue_xcd', round(avgm, 2),
      'completed_months', ncomp, 'orders_12m', n_all, 'customers_12m', n_cust, 'cost_of_goods_12m_xcd', round(cogs12, 2), 'expenses_12m_xcd', exp12,
      'net_profit_12m_xcd', round(rev12 - cogs12 - exp12, 2), 'expense_months_last6', exp_months, 'cost_coverage_pct', costpct,
      'licence_number', lic.license_number, 'licence_expiry', lic.license_expiry),
    'monthly', mj);
end $$;

-- ---- (P5) data export (orders + order lines) for the business's own records ----
-- Customer phone numbers and addresses are NOT included (names only). Capped at 20,000 orders per export.
create or replace function public.vendor_data_export(p_vendor uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb; lim constant integer := 20000;
begin
  perform public._prem_gate(p_vendor); perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada'; t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with o as (
    select row_number() over (order by x.created_at, x.order_number)::integer as n, x.*
      from public.orders x where x.vendor_id = p_vendor and x.created_at >= t0 and x.created_at < t1),
  ol as (select * from o where n <= lim)
  select jsonb_build_object('timezone', 'America/Grenada', 'from', p_from, 'to', p_to, 'limit', lim, 'truncated', (select count(*) > lim from o),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('order', ol.order_number, 'at', ol.created_at, 'day', (ol.created_at at time zone 'America/Grenada')::date,
        'status', ol.status, 'payment_status', ol.payment_status, 'method', ol.payment_method, 'fulfilment', ol.fulfilment, 'customer', ol.contact_name,
        'subtotal_xcd', ol.subtotal_xcd, 'discount_xcd', ol.discount_xcd, 'delivery_xcd', ol.delivery_fee_xcd, 'total_xcd', ol.total_xcd,
        'campaign_code', (select k.code from public.campaigns k where k.id = ol.campaign_id)) order by ol.n) from ol), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('order', ol.order_number, 'product', oi.product_name, 'quantity', oi.quantity, 'unit_price_xcd', oi.unit_price_xcd,
        'line_total_xcd', coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity), 'unit_cost_xcd', oi.unit_cost_xcd) order by ol.n, oi.product_name, oi.id)
        from ol join public.order_items oi on oi.order_id = ol.id), '[]'::jsonb))
  into res;
  return res;
end $$;

-- =====================================================================================================
-- 6. Grants
-- =====================================================================================================
revoke all on function public.vendor_forecast(uuid), public.vendor_pnl(uuid,date,date), public.vendor_inventory_report(uuid,date,date,integer,integer),
  public.vendor_clv_report(uuid,integer), public.vendor_accounting_export(uuid,date,date), public.vendor_benchmark(uuid,date,date),
  public.vendor_pricing_insights(uuid,date,date), public.vendor_fraud_monitor(uuid,integer), public.vendor_credit_readiness(uuid),
  public.vendor_data_export(uuid,date,date) from public, anon;
grant execute on function public.vendor_forecast(uuid), public.vendor_pnl(uuid,date,date), public.vendor_inventory_report(uuid,date,date,integer,integer),
  public.vendor_clv_report(uuid,integer), public.vendor_accounting_export(uuid,date,date), public.vendor_benchmark(uuid,date,date),
  public.vendor_pricing_insights(uuid,date,date), public.vendor_fraud_monitor(uuid,integer), public.vendor_credit_readiness(uuid),
  public.vendor_data_export(uuid,date,date) to authenticated;

notify pgrst, 'reload schema';
