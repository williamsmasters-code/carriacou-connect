-- Carriacou Connect v1.20: MOCK card payment processor (TEST MODE, no real money).
-- RUN AFTER financial_v2.sql. Idempotent (safe to re-run). Not yet run anywhere.
--
-- What it does
--  * platform_flags.payments_mode: 'off' (default) | 'mock' | 'live'. Card checkout works only when it is not 'off'.
--    'mock' = this test gateway. 'live' = a real processor (WiPay / bank gateway) once connected. Once any real
--    (non-mock) payment exists, the mode can never go back to 'mock', and every mock RPC refuses while the mode is 'live'.
--  * Provider interface: _pay_provider_authorise / _pay_provider_capture / _pay_provider_refund dispatch on the provider
--    name. Only 'mock' is implemented; a real processor is added as another branch without touching the flows.
--  * Card data: the browser "tokenises" the card (pay_gateway.js, like a real processor's hosted fields). The server only
--    ever receives a token + brand + last 4 + expiry. It refuses anything that looks like a full card number or a CVC,
--    and stores only brand, last 4 and expiry.
--  * Statuses: pending -> authorised -> paid (after the simulated webhook) | failed; paid -> partially_refunded -> refunded.
--  * Every mock payment, event and order is flagged is_test / payment_is_test, so it can be filtered or wiped
--    (admin_wipe_test_payments, admin only).
--  * Wired into: orders (paid / refunded), CC Points (earn on a completed paid card order, reversed by refunds,
--    proportionally for partial refunds), platform fees (card rate; refunded with the order), order_payments records,
--    vendor analytics (vendor_payment_breakdown), receipts (order_card_payment), admin transactions (admin_card_payments).

-- ---------- 1. flag ----------
alter table public.platform_flags add column if not exists payments_mode text not null default 'off';
alter table public.platform_flags drop constraint if exists platform_flags_paymode_ck;
alter table public.platform_flags add constraint platform_flags_paymode_ck check (payments_mode in ('off','mock','live')
  and (not card_payments_enabled or payments_mode in ('mock','live')));

-- ---------- 2. tables ----------
create table if not exists public.card_payments (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders(id) on delete cascade,
  vendor_id       uuid not null references public.vendors(id) on delete restrict,
  consumer_id     uuid not null,
  provider        text not null check (provider in ('mock','wipay','bank')),
  is_test         boolean not null,
  status          text not null default 'pending' check (status in ('pending','authorised','paid','failed','refunded','partially_refunded')),
  amount_cents    bigint not null check (amount_cents > 0),
  refunded_cents  bigint not null default 0,
  currency        text not null default 'XCD',
  brand           text not null check (brand in ('visa','mastercard','amex','discover','card')),
  last4           text not null check (last4 ~ '^[0-9]{4}$'),
  exp_month       int not null check (exp_month between 1 and 12),
  exp_year        int not null check (exp_year between 2000 and 2100),
  provider_ref    text,
  decline_code    text,
  decline_message text,
  idempotency_key text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  authorised_at   timestamptz, captured_at timestamptz, failed_at timestamptz, refunded_at timestamptz,
  constraint card_payments_refund_ok check (refunded_cents >= 0 and refunded_cents <= amount_cents)
);
create index if not exists card_payments_order_idx on public.card_payments(order_id, created_at desc);
create index if not exists card_payments_vendor_idx on public.card_payments(vendor_id, created_at desc);
create unique index if not exists card_payments_one_paid on public.card_payments(order_id) where status in ('paid','partially_refunded','refunded');
create unique index if not exists card_payments_idem on public.card_payments(order_id, idempotency_key) where idempotency_key is not null;
create table if not exists public.card_payment_events (
  id            bigint generated always as identity primary key,
  payment_id    uuid not null references public.card_payments(id) on delete cascade,
  kind          text not null check (kind in ('authorise','capture','decline','webhook','refund')),
  amount_cents  bigint not null default 0,
  status_after  text not null,
  provider_ref  text,
  payload       jsonb not null default '{}'::jsonb,
  is_test       boolean not null,
  created_by    uuid,
  created_at    timestamptz not null default now()
);
create index if not exists card_payment_events_pay_idx on public.card_payment_events(payment_id, id);
alter table public.card_payments enable row level security;
alter table public.card_payment_events enable row level security;
revoke all on public.card_payments, public.card_payment_events from public, anon, authenticated;
drop policy if exists card_payments_select on public.card_payments;
create policy card_payments_select on public.card_payments for select
  using (consumer_id = auth.uid() or public.vendor_perm(vendor_id, 'orders_view') or public.is_admin());
grant select on public.card_payments to authenticated;

alter table public.orders add column if not exists payment_is_test boolean not null default false;
alter table public.orders add column if not exists card_refunded_xcd numeric(10,2) not null default 0;
-- the new payment columns change only inside the payment functions
create or replace function public.orders_cardpay_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is not null and not public.is_admin() and coalesce(current_setting('cc.pay_internal', true), '') <> '1'
     and (new.payment_is_test is distinct from old.payment_is_test or new.card_refunded_xcd is distinct from old.card_refunded_xcd) then
    raise exception 'Card payment fields are set by the payment processor only';
  end if;
  return new;
end $$;
revoke all on function public.orders_cardpay_guard() from public, anon, authenticated;
drop trigger if exists trg_orders_cardpay_guard on public.orders;
create trigger trg_orders_cardpay_guard before update on public.orders for each row execute function public.orders_cardpay_guard();

-- ---------- 3. provider interface ----------
-- MOCK gateway. Tokens come from pay_gateway.js, which maps the standard test card numbers:
--   4242 4242 4242 4242 -> tok_mock_ok (approved)        4000 0000 0000 0002 -> tok_mock_declined
--   4000 0000 0000 9995 -> tok_mock_insufficient          4000 0000 0000 0069 -> tok_mock_expired
--   any other valid (Luhn) number -> tok_mock_ok. An expiry date in the past is always declined as expired.
create or replace function public._mock_gateway(p_op text, p_token text, p_amount bigint, p_exp_month int, p_exp_year int, p_ref text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare ref text := coalesce(p_ref, 'mock_ch_' || replace(gen_random_uuid()::text, '-', ''));
  exp_end date := (make_date(p_exp_year, p_exp_month, 1) + interval '1 month')::date;
begin
  if (public._flags()).payments_mode <> 'mock' then raise exception 'The mock card gateway is switched off'; end if;
  if p_op = 'authorise' then
    if p_token is null or p_token !~ '^tok_mock_[a-z]+$' then
      return jsonb_build_object('ok', false, 'code', 'invalid_token', 'message', 'The card details could not be read. Please check them and try again.', 'provider_ref', ref); end if;
    if exp_end <= (now() at time zone 'America/Grenada')::date or p_token = 'tok_mock_expired' then
      return jsonb_build_object('ok', false, 'code', 'expired_card', 'message', 'Your card has expired. Try another card.', 'provider_ref', ref); end if;
    if p_token = 'tok_mock_declined' then
      return jsonb_build_object('ok', false, 'code', 'card_declined', 'message', 'Your card was declined. Try another card or pay on pickup.', 'provider_ref', ref); end if;
    if p_token = 'tok_mock_insufficient' then
      return jsonb_build_object('ok', false, 'code', 'insufficient_funds', 'message', 'Your card has insufficient funds. Try another card or pay on pickup.', 'provider_ref', ref); end if;
    return jsonb_build_object('ok', true, 'code', 'approved', 'provider_ref', ref, 'amount_cents', p_amount);
  elsif p_op in ('capture','refund') then
    return jsonb_build_object('ok', true, 'code', p_op || 'd', 'provider_ref', ref, 'amount_cents', p_amount);
  end if;
  raise exception 'Unknown gateway operation';
end $$;
revoke all on function public._mock_gateway(text, text, bigint, int, int, text) from public, anon, authenticated;

create or replace function public._pay_provider(p_provider text, p_op text, p_token text, p_amount bigint, p_exp_month int, p_exp_year int, p_ref text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_provider = 'mock' then return public._mock_gateway(p_op, p_token, p_amount, p_exp_month, p_exp_year, p_ref); end if;
  -- a real processor (WiPay, bank gateway) is added here as another branch; the flows below do not change
  raise exception 'The card processor % is not connected yet', p_provider;
end $$;
revoke all on function public._pay_provider(text, text, text, bigint, int, int, text) from public, anon, authenticated;

create or replace function public._pay_provider_name() returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m text := (public._flags()).payments_mode;
begin
  if m = 'mock' then return 'mock'; end if;
  if m = 'live' then raise exception 'Card payments go through the live processor, which is not connected in this build'; end if;
  raise exception 'CARD_COMING_SOON: Paying online by card is coming soon. Choose pay on pickup for now.';
end $$;
revoke all on function public._pay_provider_name() from public, anon, authenticated;

-- simulated webhook: the processor tells us the payment succeeded. Marks the payment and the order paid (once).
create or replace function public._card_webhook(p_payment uuid, p_event text, p_ref text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare cp public.card_payments; o public.orders;
begin
  select * into cp from public.card_payments where id = p_payment for update;
  if not found then raise exception 'Payment not found'; end if;
  insert into public.card_payment_events(payment_id, kind, amount_cents, status_after, provider_ref, payload, is_test, created_by)
    values (cp.id, 'webhook', cp.amount_cents, case when p_event = 'payment.succeeded' then 'paid' else cp.status end, p_ref,
            jsonb_build_object('event', p_event, 'simulated', cp.is_test), cp.is_test, auth.uid());
  if p_event <> 'payment.succeeded' or cp.status <> 'authorised' then return; end if;
  update public.card_payments set status = 'paid', captured_at = now() where id = cp.id;
  select * into o from public.orders where id = cp.order_id for update;
  perform set_config('cc.pay_internal', '1', true);
  update public.orders set payment_status = 'paid', paid_at = now(), payment_is_test = cp.is_test where id = o.id and payment_status = 'unpaid';
  perform set_config('cc.pay_internal', '', true);
  perform set_config('cc.card_processor', '1', true);
  insert into public.order_payments(order_id, vendor_id, amount_xcd, kind, method, note, recorded_by)
    values (o.id, o.vendor_id, cp.amount_cents / 100.0, 'full', 'card_online',
            initcap(cp.brand) || ' ending ' || cp.last4 || case when cp.is_test then ' (TEST, no real money)' else '' end, null);
  perform set_config('cc.card_processor', '', true);
  begin
    perform public._rt_add(u, 'card_paid', 'Card payment received: ' || o.order_number,
      public._rt_money(cp.amount_cents / 100.0) || case when cp.is_test then ' · TEST, no real money' else '' end,
      'dashboard-vendor.html?v=' || o.vendor_id || '#orders', 'order', o.id, o.vendor_id, false)
      from public._rt_team(o.vendor_id, 'orders_view') u;
  exception when others then null; end;
end $$;
revoke all on function public._card_webhook(uuid, text, text) from public, anon, authenticated;

-- ---------- 4. customer: pay card orders ----------
create or replace function public.card_pay_orders(p_order_ids uuid[], p_card jsonb, p_key text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare prov text; oid uuid; o public.orders; cp public.card_payments; res jsonb := '[]'::jsonb; a jsonb; c jsonb;
  tok text := p_card->>'token'; br text := lower(coalesce(p_card->>'brand', 'card')); l4 text := p_card->>'last4';
  em int; ey int; k text := left(nullif(btrim(coalesce(p_key, '')), ''), 60); amt bigint; pid uuid;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  prov := public._pay_provider_name();
  -- never accept a full card number or a CVC: the browser sends a token only
  if p_card ?| array['number','pan','card_number','cvc','cvv','cvv2','security_code'] or coalesce(tok, '') ~ '[0-9]{12,}' then
    raise exception 'CARD_DATA: Full card numbers and security codes must never be sent to Carriacou Connect'; end if;
  if l4 is null or l4 !~ '^[0-9]{4}$' then raise exception 'Card details are incomplete'; end if;
  begin em := (p_card->>'exp_month')::int; ey := (p_card->>'exp_year')::int; exception when others then raise exception 'Enter a valid expiry date'; end;
  if em is null or ey is null or em not between 1 and 12 then raise exception 'Enter a valid expiry date'; end if;
  if ey < 100 then ey := 2000 + ey; end if;
  if br not in ('visa','mastercard','amex','discover') then br := 'card'; end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 or array_length(p_order_ids, 1) > 20 then raise exception 'Choose the orders to pay'; end if;
  foreach oid in array p_order_ids loop
    select * into o from public.orders where id = oid for update;
    if not found or o.consumer_id <> auth.uid() then raise exception 'Order not found'; end if;
    if o.payment_method <> 'pay_card_online' then raise exception 'Order % is pay on pickup', o.order_number; end if;
    if o.status = 'cancelled' then raise exception 'Order % was cancelled', o.order_number; end if;
    -- replay / already paid
    select * into cp from public.card_payments where order_id = o.id and (status in ('paid','partially_refunded','refunded') or (k is not null and idempotency_key = k))
      order by created_at desc limit 1;
    if found then
      res := res || jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'status', cp.status, 'replay', true,
                                       'decline_code', cp.decline_code, 'message', cp.decline_message, 'brand', cp.brand, 'last4', cp.last4);
      continue;
    end if;
    if o.payment_status <> 'unpaid' then raise exception 'Order % is already %', o.order_number, o.payment_status; end if;
    amt := round(o.total_xcd * 100)::bigint;
    insert into public.card_payments(order_id, vendor_id, consumer_id, provider, is_test, status, amount_cents, brand, last4, exp_month, exp_year, idempotency_key, created_by)
      values (o.id, o.vendor_id, o.consumer_id, prov, prov = 'mock', 'pending', amt, br, l4, em, ey, k, auth.uid()) returning id into pid;
    a := public._pay_provider(prov, 'authorise', tok, amt, em, ey, null);
    if not (a->>'ok')::boolean then
      update public.card_payments set status = 'failed', failed_at = now(), decline_code = a->>'code', decline_message = a->>'message', provider_ref = a->>'provider_ref' where id = pid;
      insert into public.card_payment_events(payment_id, kind, amount_cents, status_after, provider_ref, payload, is_test, created_by)
        values (pid, 'decline', amt, 'failed', a->>'provider_ref', jsonb_build_object('code', a->>'code'), prov = 'mock', auth.uid());
      res := res || jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'status', 'failed', 'decline_code', a->>'code', 'message', a->>'message', 'brand', br, 'last4', l4);
      continue;
    end if;
    update public.card_payments set status = 'authorised', authorised_at = now(), provider_ref = a->>'provider_ref' where id = pid;
    insert into public.card_payment_events(payment_id, kind, amount_cents, status_after, provider_ref, payload, is_test, created_by)
      values (pid, 'authorise', amt, 'authorised', a->>'provider_ref', '{}'::jsonb, prov = 'mock', auth.uid());
    c := public._pay_provider(prov, 'capture', null, amt, em, ey, a->>'provider_ref');
    insert into public.card_payment_events(payment_id, kind, amount_cents, status_after, provider_ref, payload, is_test, created_by)
      values (pid, 'capture', amt, 'authorised', c->>'provider_ref', '{}'::jsonb, prov = 'mock', auth.uid());
    -- the processor's webhook confirms the capture (simulated straight away in mock mode)
    perform public._card_webhook(pid, 'payment.succeeded', c->>'provider_ref');
    res := res || jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'status', 'paid', 'brand', br, 'last4', l4,
                                     'amount_cents', amt, 'test', prov = 'mock');
  end loop;
  return res;
end $$;
revoke all on function public.card_pay_orders(uuid[], jsonb, text) from public, anon;
grant execute on function public.card_pay_orders(uuid[], jsonb, text) to authenticated;

-- declined and want to pay on pickup instead (only before any payment and before the shop accepts)
create or replace function public.card_order_to_pickup(p_order_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare oid uuid; o public.orders; f public.platform_flags := public._flags(); n int := 0;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  foreach oid in array coalesce(p_order_ids, '{}') loop
    select * into o from public.orders where id = oid for update;
    if not found or o.consumer_id <> auth.uid() then raise exception 'Order not found'; end if;
    if o.payment_method <> 'pay_card_online' or o.payment_status <> 'unpaid' or o.status <> 'placed' or o.fulfilment <> 'pickup' then
      raise exception 'Order % cannot be switched to pay on pickup', o.order_number; end if;
    perform set_config('cc.pay_internal', '1', true);
    update public.orders set payment_method = 'pay_on_pickup' where id = o.id;
    perform set_config('cc.pay_internal', '', true);
    update public.order_fees set fee_class = 'direct', rate_pct = f.fee_direct_pct, fee_cents = round(base_cents * f.fee_direct_pct / 100)
      where order_id = o.id and billed_at is null and status = 'charged';
    n := n + 1;
  end loop;
  return jsonb_build_object('switched', n);
end $$;
revoke all on function public.card_order_to_pickup(uuid[]) from public, anon;
grant execute on function public.card_order_to_pickup(uuid[]) to authenticated;

-- ---------- 5. vendor: refund (full or partial) ----------
create or replace function public.vendor_refund_card(p_order uuid, p_amount_cents bigint default null, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders; cp public.card_payments; amt bigint; r jsonb; full_ref boolean; earn int; rev int; target int; bal int;
begin
  select * into o from public.orders where id = p_order for update;
  if not found or not (public.vendor_perm(o.vendor_id, 'refunds') or public.is_admin()) then raise exception 'Only the owner or a sub-admin can refund'; end if;
  select * into cp from public.card_payments where order_id = o.id and status in ('paid','partially_refunded') for update;
  if not found then raise exception 'This order has no card payment to refund'; end if;
  if cp.provider = 'mock' and (public._flags()).payments_mode <> 'mock' then raise exception 'Test card payments can only be refunded while the mock gateway is on'; end if;
  amt := coalesce(p_amount_cents, cp.amount_cents - cp.refunded_cents);
  if amt <= 0 or amt > cp.amount_cents - cp.refunded_cents then
    raise exception 'Refund between EC$0.01 and %', public._rt_money((cp.amount_cents - cp.refunded_cents) / 100.0); end if;
  r := public._pay_provider(cp.provider, 'refund', null, amt, cp.exp_month, cp.exp_year, cp.provider_ref);
  full_ref := cp.refunded_cents + amt = cp.amount_cents;
  update public.card_payments set refunded_cents = refunded_cents + amt, refunded_at = now(),
    status = case when full_ref then 'refunded' else 'partially_refunded' end where id = cp.id;
  insert into public.card_payment_events(payment_id, kind, amount_cents, status_after, provider_ref, payload, is_test, created_by)
    values (cp.id, 'refund', amt, case when full_ref then 'refunded' else 'partially_refunded' end, r->>'provider_ref',
            jsonb_build_object('reason', left(coalesce(p_reason, ''), 200)), cp.is_test, auth.uid());
  perform set_config('cc.pay_internal', '1', true);
  update public.orders set card_refunded_xcd = (cp.refunded_cents + amt) / 100.0,
    payment_status = case when full_ref then 'refunded' else payment_status end where id = o.id;   -- full: points + fee reversed by triggers
  perform set_config('cc.pay_internal', '', true);
  if not full_ref then
    -- partial: take back the same share of the points already earned
    select delta into earn from public.cc_points_ledger where order_id = o.id and kind = 'earn';
    if earn is not null then
      target := floor(earn::numeric * (cp.refunded_cents + amt) / cp.amount_cents)::int;
      rev := -coalesce((select sum(delta) from public.cc_points_ledger where order_id = o.id and kind = 'reverse'), 0);
      bal := greatest(public._points_bal(o.consumer_id), 0);
      if target - rev > 0 and bal > 0 then
        insert into public.cc_points_ledger(user_id, delta, kind, order_id, note)
          values (o.consumer_id, -least(target - rev, bal), 'reverse', o.id, 'Order ' || o.order_number || ' part refunded');
      end if;
    end if;
  end if;
  perform public._audit(o.vendor_id, 'card_refund', o.id, jsonb_build_object('cents', amt, 'full', full_ref, 'test', cp.is_test));
  return jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'refunded_cents', amt, 'total_refunded_cents', cp.refunded_cents + amt,
    'status', case when full_ref then 'refunded' else 'partially_refunded' end, 'test', cp.is_test);
end $$;
revoke all on function public.vendor_refund_card(uuid, bigint, text) from public, anon;
grant execute on function public.vendor_refund_card(uuid, bigint, text) to authenticated;

-- ---------- 6. receipts / order pages ----------
create or replace function public.order_card_payment(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order;
  if not found or not (o.consumer_id = auth.uid() or public.vendor_perm(o.vendor_id, 'orders_view') or public.is_admin()) then raise exception 'Order not found'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', cp.id, 'status', cp.status, 'amount_cents', cp.amount_cents, 'refunded_cents', cp.refunded_cents,
      'brand', cp.brand, 'last4', cp.last4, 'exp', lpad(cp.exp_month::text, 2, '0') || '/' || right(cp.exp_year::text, 2), 'test', cp.is_test, 'provider', cp.provider,
      'decline_message', cp.decline_message, 'created_at', cp.created_at, 'captured_at', cp.captured_at, 'refunded_at', cp.refunded_at,
      'events', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'amount_cents', e.amount_cents, 'status_after', e.status_after, 'at', e.created_at) order by e.id)
                 from public.card_payment_events e where e.payment_id = cp.id)) order by cp.created_at desc)
    from public.card_payments cp where cp.order_id = o.id), '[]'::jsonb);
end $$;
revoke all on function public.order_card_payment(uuid) from public, anon;
grant execute on function public.order_card_payment(uuid) to authenticated;

-- ---------- 7. vendor analytics: card payments in the payment breakdown ----------
create or replace function public.vendor_payment_breakdown(p_from date, p_to date) returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada';
  t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with mine as (
    select o.* from public.orders o join public.vendors v on v.id = o.vendor_id
     where public.vendor_perm(v.id, 'analytics') and o.created_at >= t0 and o.created_at < t1),
  m(method) as (values ('pay_on_pickup'), ('pay_card_online'), ('pay_on_delivery'), ('pay_with_wallet')),
  cps as (select cp.* from public.card_payments cp join mine on mine.id = cp.order_id)
  select jsonb_build_object(
    'methods', (select jsonb_agg(jsonb_build_object('method', m.method,
                  'orders', (select count(*) from mine x where x.payment_method = m.method and x.status <> 'cancelled' and x.payment_status <> 'refunded'),
                  'revenue_xcd', (select coalesce(sum(x.total_xcd - coalesce(x.card_refunded_xcd, 0)), 0) from mine x where x.payment_method = m.method and x.status <> 'cancelled' and x.payment_status <> 'refunded'))
                  order by m.method) from m),
    'refunds', jsonb_build_object(
       'orders', (select count(*) from mine where payment_status = 'refunded' or coalesce(card_refunded_xcd, 0) > 0),
       'amount_xcd', (select coalesce(sum(case when payment_status = 'refunded' then total_xcd else coalesce(card_refunded_xcd, 0) end), 0) from mine)),
    'card', jsonb_build_object(
       'payments', (select count(*) from cps where status in ('paid','partially_refunded','refunded')),
       'declined', (select count(*) from cps where status = 'failed'),
       'captured_xcd', (select coalesce(sum(amount_cents), 0) / 100.0 from cps where status in ('paid','partially_refunded','refunded')),
       'refunded_xcd', (select coalesce(sum(refunded_cents), 0) / 100.0 from cps),
       'net_xcd', (select coalesce(sum(amount_cents - refunded_cents), 0) / 100.0 from cps where status in ('paid','partially_refunded','refunded')),
       'awaiting_xcd', (select coalesce(sum(total_xcd), 0) from mine where payment_method = 'pay_card_online' and payment_status = 'unpaid' and status <> 'cancelled'),
       'test', exists (select 1 from cps where is_test)))
  into res;
  return res;
end $$;

-- ---------- 8. admin: transactions, switching the mode, wiping test data ----------
create or replace function public.admin_card_payments(p_test boolean default null, p_status text default null, p_limit int default 200) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Only the platform admin can see card transactions'; end if;
  return jsonb_build_object('mode', (public._flags()).payments_mode,
    'totals', (select jsonb_build_object('payments', count(*) filter (where status <> 'failed'), 'declined', count(*) filter (where status = 'failed'),
        'captured_cents', coalesce(sum(amount_cents) filter (where status in ('paid','partially_refunded','refunded')), 0),
        'refunded_cents', coalesce(sum(refunded_cents), 0), 'test', count(*) filter (where is_test))
      from public.card_payments where p_test is null or is_test = p_test),
    'rows', coalesce((select jsonb_agg(x order by x.created_at desc) from (
      select cp.id, cp.created_at, cp.status, cp.amount_cents, cp.refunded_cents, cp.brand, cp.last4, cp.is_test, cp.provider, cp.decline_code,
             o.order_number, v.name as vendor, coalesce(pr.full_name, '') as customer,
             (select count(*) from public.card_payment_events e where e.payment_id = cp.id) as events
        from public.card_payments cp join public.orders o on o.id = cp.order_id join public.vendors v on v.id = cp.vendor_id
        left join public.profiles pr on pr.id = cp.consumer_id
       where (p_test is null or cp.is_test = p_test) and (p_status is null or cp.status = p_status)
       order by cp.created_at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) x), '[]'::jsonb));
end $$;
revoke all on function public.admin_card_payments(boolean, text, int) from public, anon;
grant execute on function public.admin_card_payments(boolean, text, int) to authenticated;

create or replace function public.admin_set_payments_mode(p_mode text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Only the platform admin can change payments'; end if;
  if p_mode not in ('off','mock','live') then raise exception 'Payments mode is off, mock or live'; end if;
  if p_mode = 'mock' and exists (select 1 from public.card_payments where provider <> 'mock') then
    raise exception 'Real card payments exist, so the mock gateway can never be switched back on'; end if;
  update public.platform_flags set payments_mode = p_mode, card_payments_enabled = (p_mode <> 'off') where id = 1;
  perform public._audit(null, 'payments_mode_changed', null, jsonb_build_object('mode', p_mode));
  return jsonb_build_object('payments_mode', p_mode, 'card_payments_enabled', p_mode <> 'off');
end $$;
revoke all on function public.admin_set_payments_mode(text) from public, anon;
grant execute on function public.admin_set_payments_mode(text) to authenticated;

-- removes every TEST card payment and its effects; real payments are never touched
create or replace function public.admin_wipe_test_payments(p_confirm text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare ids uuid[]; np int; nr int; npt int;
begin
  if not public.is_admin() then raise exception 'Only the platform admin can wipe test payments'; end if;
  if p_confirm is distinct from 'WIPE TEST PAYMENTS' then raise exception 'Type WIPE TEST PAYMENTS to confirm'; end if;
  select coalesce(array_agg(distinct order_id), '{}') into ids from public.card_payments where is_test;
  -- the points ledger is append-only: cancel what test card orders still give with an 'adjust' row each
  insert into public.cc_points_ledger(user_id, delta, kind, order_id, note)
    select x.user_id, -least(x.net, greatest(public._points_bal(x.user_id), 0)), 'adjust', x.order_id, 'Test card payment wiped'
      from (select user_id, order_id, sum(delta)::int as net from public.cc_points_ledger where order_id = any(ids) group by user_id, order_id) x
     where x.net > 0 and public._points_bal(x.user_id) > 0;
  get diagnostics npt = row_count;
  delete from public.order_payments where order_id = any(ids) and method = 'card_online';
  perform set_config('cc.pay_internal', '1', true);
  update public.orders set payment_status = 'unpaid', paid_at = null, payment_is_test = false, card_refunded_xcd = 0
   where id = any(ids) and payment_method = 'pay_card_online';
  perform set_config('cc.pay_internal', '', true);
  get diagnostics nr = row_count;
  delete from public.card_payments where is_test;
  get diagnostics np = row_count;
  perform public._audit(null, 'test_payments_wiped', null, jsonb_build_object('payments', np, 'orders', nr, 'points_rows_cancelled', npt));
  return jsonb_build_object('payments_deleted', np, 'orders_reset', array_length(ids, 1), 'points_rows_cancelled', npt);
end $$;
revoke all on function public.admin_wipe_test_payments(text) from public, anon;
grant execute on function public.admin_wipe_test_payments(text) to authenticated;

-- flags RPC shows the mode to the browser (platform_flags_get returns the whole row in wallet_repurpose.sql)
notify pgrst, 'reload schema';
