-- =====================================================================================================
-- pos_tax.sql (v1.9) - VAT on POS charges + tax columns in the Premium data export.
-- RUN ORDER: after tax_delivery.sql (needs vendor_checkout_settings + _vat_default) and after advanced_analytics.sql
--   (it redefines vendor_data_export). Put it LAST, after realtime.sql. Re-running advanced_analytics.sql
--   reverts the export to the old (no-tax) version until pos_tax.sql is re-run. Re-running pay.sql / staff.sql is safe
--   (create_charge is NOT redefined here; tax is applied by a trigger on pay_requests).
-- Idempotent. No UPDATE/DELETE statements.
-- Rule (same as _order_money in tax_delivery.sql): only if the business is VAT registered:
--   rate = vat_rate_pct or the platform default; base = amount the vendor entered.
--   inclusive: tax = round(base*r/(100+r),2), customer pays base.
--   exclusive: tax = round(base*r/100,2),  customer pays base + tax.
-- Snapshots on the charge: base_cents, tax_cents, tax_rate_pct, tax_inclusive, vendor_vat_number.
-- Charges created before this file keep NULL tax_cents (= no tax recorded).
-- =====================================================================================================

alter table public.pay_requests add column if not exists base_cents bigint;
alter table public.pay_requests add column if not exists tax_cents bigint;
alter table public.pay_requests add column if not exists tax_rate_pct numeric(5,2);
alter table public.pay_requests add column if not exists tax_inclusive boolean;
alter table public.pay_requests add column if not exists vendor_vat_number text;

create or replace function public._pos_tax(p_vendor uuid, p_base_cents bigint) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.vendor_checkout_settings; rate numeric := 0; incl boolean := true; vat text; base numeric; tax numeric := 0;
begin
  select * into s from public.vendor_checkout_settings where vendor_id = p_vendor;
  if found and s.vat_registered then rate := coalesce(s.vat_rate_pct, public._vat_default()); incl := s.prices_include_tax; vat := s.vat_number; end if;
  base := coalesce(p_base_cents, 0) / 100.0;
  if rate > 0 then tax := case when incl then round(base * rate / (100 + rate), 2) else round(base * rate / 100, 2) end; end if;
  return jsonb_build_object('base_cents', p_base_cents, 'tax_cents', (tax * 100)::bigint, 'tax_rate_pct', rate, 'tax_inclusive', incl,
    'vat_number', vat, 'amount_cents', p_base_cents + case when incl then 0 else (tax * 100)::bigint end);
end $$;
revoke all on function public._pos_tax(uuid, bigint) from public, anon, authenticated;

create or replace function public.pay_requests_apply_tax() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare m jsonb;
begin
  if new.tax_cents is not null then return new; end if;
  m := public._pos_tax(new.vendor_id, new.amount_cents);
  new.base_cents := new.amount_cents;
  new.tax_cents := (m->>'tax_cents')::bigint;
  new.tax_rate_pct := (m->>'tax_rate_pct')::numeric;
  new.tax_inclusive := (m->>'tax_inclusive')::boolean;
  new.vendor_vat_number := m->>'vat_number';
  new.amount_cents := (m->>'amount_cents')::bigint;
  if new.amount_cents > 200000 then raise exception 'Amount plus VAT (EC$%) is over the test limit of EC$2000', round(new.amount_cents / 100.0, 2); end if;
  return new;
end $$;
revoke all on function public.pay_requests_apply_tax() from public, anon, authenticated;
drop trigger if exists trg_pr_zz_tax on public.pay_requests;
create trigger trg_pr_zz_tax before insert on public.pay_requests for each row execute function public.pay_requests_apply_tax();

-- customer preview shows the VAT line
create or replace function public.charge_preview(p_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); c record; s text := upper(regexp_replace(btrim(coalesce(p_code,'')), '\s+', '', 'g'));
begin
  if uid is null then raise exception 'Please log in'; end if;
  perform public._pay_throttle(uid, 'lookup', 10, 'Too many unknown codes. Please wait a few minutes.');
  if s ~ '^PAY[A-Z2-9]{8}$' then s := 'PAY-' || substr(s,4,4) || '-' || substr(s,8,4); end if;
  select pr.*, v.name as vname into c from public.pay_requests pr join public.vendors v on v.id = pr.vendor_id where pr.code = s;
  if not found then insert into public.pay_attempts(user_id, kind) values (uid, 'lookup'); return jsonb_build_object('ok', false, 'error', 'charge_not_found'); end if;
  return jsonb_build_object('ok', true, 'code', c.code, 'vendor_name', c.vname, 'amount_cents', c.amount_cents, 'note', c.note, 'items', c.items,
    'status', case when c.status = 'open' and c.expires_at <= now() then 'expired' else c.status end, 'expires_at', c.expires_at,
    'base_cents', c.base_cents, 'tax_cents', c.tax_cents, 'tax_rate_pct', c.tax_rate_pct, 'tax_inclusive', c.tax_inclusive, 'vat_number', c.vendor_vat_number);
end $$;
revoke all on function public.charge_preview(text) from public, anon;
grant execute on function public.charge_preview(text) to authenticated;

-- Premium export: tax columns on orders + a pos_charges list (paid charges in range)
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
        'tax_xcd', ol.tax_xcd, 'tax_rate_pct', ol.tax_rate_pct, 'tax_inclusive', ol.tax_inclusive,
        'campaign_code', (select k.code from public.campaigns k where k.id = ol.campaign_id)) order by ol.n) from ol), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('order', ol.order_number, 'product', oi.product_name, 'quantity', oi.quantity, 'unit_price_xcd', oi.unit_price_xcd,
        'line_total_xcd', coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity), 'unit_cost_xcd', oi.unit_cost_xcd) order by ol.n, oi.product_name, oi.id)
        from ol join public.order_items oi on oi.order_id = ol.id), '[]'::jsonb),
    'pos_charges', coalesce((select jsonb_agg(jsonb_build_object('code', pr.code, 'at', pr.created_at, 'day', (pr.created_at at time zone 'America/Grenada')::date,
        'note', pr.note, 'total_xcd', round(pr.amount_cents / 100.0, 2), 'tax_xcd', round(pr.tax_cents / 100.0, 2), 'tax_rate_pct', pr.tax_rate_pct,
        'tax_inclusive', pr.tax_inclusive) order by pr.created_at)
        from public.pay_requests pr where pr.vendor_id = p_vendor and pr.status = 'paid' and pr.created_at >= t0 and pr.created_at < t1), '[]'::jsonb))
  into res;
  return res;
end $$;
revoke all on function public.vendor_data_export(uuid,date,date) from public, anon;
grant execute on function public.vendor_data_export(uuid,date,date) to authenticated;

notify pgrst, 'reload schema';
