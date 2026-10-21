-- =====================================================================================================
-- admin_vat.sql (v1.10) - platform admin tax summary: POS takings shown as net / VAT / gross next to order VAT.
-- RUN ORDER: LAST, after pos_tax.sql (needs pay_requests.tax_cents). Re-running tax_delivery.sql reverts
--   admin_pa_tax_summary to the orders-only version: re-run admin_vat.sql afterwards.
-- Idempotent. No UPDATE/DELETE. Only redefines admin_pa_tax_summary (same signature and grants).
-- =====================================================================================================
alter table public.pay_requests add column if not exists tax_cents bigint;
alter table public.pay_requests add column if not exists tax_inclusive boolean;

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
  -- v1.10: POS takings split into net / VAT / gross. Paid charges in range (by payment time); charges without a VAT snapshot count as VAT 0.
  r := r || (select jsonb_build_object(
    'pos_charges', count(*),
    'pos_gross_xcd', coalesce(round(sum(pr.amount_cents) / 100.0, 2), 0),
    'pos_vat_xcd', coalesce(round(sum(coalesce(pr.tax_cents, 0)) / 100.0, 2), 0),
    'pos_net_xcd', coalesce(round(sum(pr.amount_cents - coalesce(pr.tax_cents, 0)) / 100.0, 2), 0),
    'pos_vat_inside_prices_xcd', coalesce(round(sum(coalesce(pr.tax_cents, 0)) filter (where pr.tax_inclusive) / 100.0, 2), 0),
    'pos_vat_added_on_top_xcd', coalesce(round(sum(coalesce(pr.tax_cents, 0)) filter (where pr.tax_inclusive = false) / 100.0, 2), 0),
    'pos_taxed_charges', count(*) filter (where coalesce(pr.tax_cents, 0) > 0),
    'pos_without_tax_record', count(*) filter (where pr.tax_cents is null))
    from public.pay_requests pr join public.transactions t on t.id = pr.transaction_id join public.vendors v on v.id = pr.vendor_id and not v.is_sample
    where pr.status = 'paid' and t.created_at >= lo and t.created_at < hi);
  r := r || jsonb_build_object('total_vat_xcd', round((r->>'tax_collected_xcd')::numeric + (r->>'pos_vat_xcd')::numeric, 2));
  return r;
end $$;
revoke all on function public.admin_pa_tax_summary(date, date) from public, anon;
grant execute on function public.admin_pa_tax_summary(date, date) to authenticated;

notify pgrst, 'reload schema';
