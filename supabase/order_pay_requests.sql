-- =====================================================================================================
-- order_pay_requests.sql (v1.15) - vendor "Request payment" + customer "Pay balance" from the TEST wallet
-- for pay-on-pickup / pay-on-delivery orders.
-- RUN ORDER: LAST, after offline_payments.sql (needs order_payments, _offpay_refresh, pay.sql wallet helpers,
-- staff.sql vendor_perm, realtime.sql _rt_add/_rt_team). Idempotent. Every UPDATE/DELETE has a WHERE.
-- Rules:
--   * request: owner / sub-admin / staff with 'orders_update'; 0 < amount <= balance due; one pending request per order.
--   * cancel: same permission. remind: same permission, at most 3 reminders, at least 6 hours apart (and 6 h after the request).
--   * pay: the order's customer; amount = given amount, else the pending request amount, else the full balance;
--     0 < amount <= balance; test funds move customer -> vendor wallet via _pay_move ('order_payment');
--     an order_payments row (method 'wallet') is written and the order's offline_status / amount_paid refresh.
--     A pending request is marked paid once the amount paid since it covers it (or the balance reaches 0).
--   * wallet rows in order_payments cannot be voided (money really moved; refunds are a separate flow).
--   * POS charge codes are untouched.
-- =====================================================================================================

alter table public.order_payments add column if not exists transaction_id uuid;
alter table public.order_payments drop constraint if exists order_payments_method_check;
alter table public.order_payments add constraint order_payments_method_check check (method in ('cash','card','bank','other','wallet'));

create table if not exists public.order_pay_requests (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders(id) on delete cascade,
  vendor_id       uuid not null,
  consumer_id     uuid not null,
  amount_xcd      numeric(10,2) not null check (amount_xcd > 0),
  message         text check (message is null or char_length(message) <= 200),
  status          text not null default 'pending' check (status in ('pending','paid','cancelled')),
  created_by      uuid,
  created_at      timestamptz not null default now(),
  reminder_count  int not null default 0,
  reminded_at     timestamptz,
  paid_at         timestamptz,
  payment_id      uuid,
  cancelled_at    timestamptz,
  cancelled_by    uuid
);
create unique index if not exists order_pay_requests_one_pending on public.order_pay_requests(order_id) where status = 'pending';
create index if not exists order_pay_requests_consumer_idx on public.order_pay_requests(consumer_id, status);
create index if not exists order_pay_requests_vendor_idx on public.order_pay_requests(vendor_id, created_at);

alter table public.order_pay_requests enable row level security;
drop policy if exists order_pay_requests_read on public.order_pay_requests;
create policy order_pay_requests_read on public.order_pay_requests for select to authenticated
  using (consumer_id = auth.uid() or public.vendor_perm(vendor_id, 'orders_view') or public.is_admin());
revoke insert, update, delete on public.order_pay_requests from anon, authenticated;
grant select on public.order_pay_requests to authenticated;

-- wallet payments cannot be voided (wrap the v1.13 void; same rules otherwise)
create or replace function public.order_payments_no_wallet_void() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.voided and not old.voided and old.method = 'wallet' then
    raise exception 'Wallet payments cannot be voided: test money already moved to the business wallet';
  end if;
  return new;
end $$;
revoke all on function public.order_payments_no_wallet_void() from public, anon, authenticated;
drop trigger if exists trg_order_payments_no_wallet_void on public.order_payments;
create trigger trg_order_payments_no_wallet_void before update on public.order_payments for each row execute function public.order_payments_no_wallet_void();

-- shared checks for an order that can take a balance payment
create or replace function public._opr_balance(o public.orders) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if o.payment_method = 'pay_with_wallet' or o.payment_status <> 'unpaid' then raise exception 'This order is paid with the wallet at checkout'; end if;
  if o.status = 'cancelled' then raise exception 'This order was cancelled'; end if;
  return round(o.total_xcd - coalesce((select sum(amount_xcd) from public.order_payments where order_id = o.id and not voided), 0), 2);
end $$;
revoke all on function public._opr_balance(public.orders) from public, anon, authenticated;

create or replace function public.vendor_request_payment(p_order uuid, p_amount numeric default null, p_message text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); o public.orders; bal numeric; amt numeric; msg text := nullif(btrim(coalesce(p_message, '')), ''); rid uuid;
begin
  if uid is null then raise exception 'Please sign in'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found or not public.vendor_perm(o.vendor_id, 'orders_update') then raise exception 'Order not found'; end if;
  bal := public._opr_balance(o);
  if bal <= 0 then raise exception 'This order is already paid in full'; end if;
  if msg is not null and char_length(msg) > 200 then raise exception 'Message is too long (max 200 characters)'; end if;
  amt := round(coalesce(p_amount, bal), 2);
  if amt <= 0 then raise exception 'Enter an amount above EC$0.00'; end if;
  if amt > bal then raise exception 'The request cannot be more than the balance due (EC$%)', to_char(bal, 'FM999990.00'); end if;
  if exists (select 1 from public.order_pay_requests where order_id = o.id and status = 'pending') then
    raise exception 'There is already a pending payment request for this order. Cancel it or send a reminder.'; end if;
  insert into public.order_pay_requests(order_id, vendor_id, consumer_id, amount_xcd, message, created_by)
    values (o.id, o.vendor_id, o.consumer_id, amt, msg, uid) returning id into rid;
  perform public._rt_add(o.consumer_id, 'pay_request', 'Payment request: ' || public._rt_money(amt) || ' for ' || o.order_number,
    coalesce(msg || ' · ', '') || 'Tap to pay from your test wallet (play money).', 'dashboard-consumer.html?order=' || o.id::text, 'order', o.id, o.vendor_id, false);
  return jsonb_build_object('request_id', rid, 'order_id', o.id, 'amount_xcd', amt, 'balance_due_xcd', bal, 'status', 'pending');
end $$;

create or replace function public.vendor_cancel_pay_request(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r record;
begin
  if uid is null then raise exception 'Please sign in'; end if;
  select * into r from public.order_pay_requests where id = p_request for update;
  if not found or not public.vendor_perm(r.vendor_id, 'orders_update') then raise exception 'Request not found'; end if;
  if r.status <> 'pending' then raise exception 'This request is already %', r.status; end if;
  update public.order_pay_requests set status = 'cancelled', cancelled_at = now(), cancelled_by = uid where id = r.id;
  perform public._rt_add(r.consumer_id, 'pay_request_cancelled', 'Payment request withdrawn',
    'The vendor withdrew the ' || public._rt_money(r.amount_xcd) || ' request. Any balance can still be paid on ' ||
    (select case when fulfilment = 'delivery' then 'delivery' else 'pickup' end from public.orders where id = r.order_id) || '.',
    'dashboard-consumer.html?order=' || r.order_id::text, 'order', r.order_id, r.vendor_id, false);
  return jsonb_build_object('request_id', r.id, 'status', 'cancelled');
end $$;

create or replace function public.vendor_remind_pay_request(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r record; nxt timestamptz; onum text;
begin
  if uid is null then raise exception 'Please sign in'; end if;
  select * into r from public.order_pay_requests where id = p_request for update;
  if not found or not public.vendor_perm(r.vendor_id, 'orders_update') then raise exception 'Request not found'; end if;
  if r.status <> 'pending' then raise exception 'This request is already %', r.status; end if;
  if r.reminder_count >= 3 then raise exception 'You have already sent 3 reminders for this request'; end if;
  nxt := coalesce(r.reminded_at, r.created_at) + interval '6 hours';
  if now() < nxt then raise exception 'You can send the next reminder after % (Grenada time)', to_char(nxt at time zone 'America/Grenada', 'DD Mon HH24:MI'); end if;
  update public.order_pay_requests set reminder_count = reminder_count + 1, reminded_at = now() where id = r.id;
  select order_number into onum from public.orders where id = r.order_id;
  perform public._rt_add(r.consumer_id, 'pay_request', 'Reminder: ' || public._rt_money(r.amount_xcd) || ' due for ' || onum,
    coalesce(r.message || ' · ', '') || 'Tap to pay from your test wallet (play money).', 'dashboard-consumer.html?order=' || r.order_id::text, 'order', r.order_id, r.vendor_id, false);
  return jsonb_build_object('request_id', r.id, 'reminder_count', r.reminder_count + 1);
end $$;

create or replace function public.customer_pay_balance(p_order uuid, p_amount numeric default null, p_idempotency_key text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); o public.orders; bal numeric; amt numeric; req record; f uuid; t uuid; tid uuid; pid uuid; res jsonb; key text; u uuid; prev jsonb;
begin
  if uid is null then raise exception 'Please sign in'; end if;
  select * into o from public.orders where id = p_order for update;              -- row lock: two taps cannot both pay
  if not found or o.consumer_id <> uid then raise exception 'Order not found'; end if;
  key := case when p_idempotency_key is null then null else left(p_idempotency_key, 60) || ':bal:' || o.id::text end;
  if key is not null then
    select jsonb_build_object('replay', true, 'payment_id', p.id, 'amount_xcd', p.amount_xcd) into prev
      from public.transactions x join public.order_payments p on p.transaction_id = x.id where x.created_by = uid and x.idempotency_key = key;
    if prev is not null then return prev || public._offpay_refresh(o.id); end if;
  end if;
  bal := public._opr_balance(o);
  if bal <= 0 then raise exception 'This order is already paid in full'; end if;
  select * into req from public.order_pay_requests where order_id = o.id and status = 'pending' for update;
  amt := round(coalesce(p_amount, req.amount_xcd, bal), 2);
  if amt <= 0 then raise exception 'Enter an amount above EC$0.00'; end if;
  if amt > bal then raise exception 'That is more than the balance due (EC$%)', to_char(bal, 'FM999990.00'); end if;
  f := public._pay_personal_wallet(uid);
  t := public._pay_vendor_wallet(o.vendor_id);
  tid := public._pay_move('order_payment', f, t, round(amt * 100)::bigint, 'Order ' || o.order_number || case when amt < bal then ' (part payment)' else ' (balance)' end,
         null, null, uid, key);   -- order_id left null on purpose: pay.sql allows one order_payment transaction per order (checkout);
                                  -- the link is order_payments.transaction_id. Still type 'order_payment', so wallet analytics count it.
  insert into public.order_payments(order_id, vendor_id, amount_xcd, kind, method, note, recorded_by, transaction_id)
    values (o.id, o.vendor_id, amt, case when amt >= bal then 'full' else 'partial' end, 'wallet', 'Paid from test wallet', uid, tid) returning id into pid;
  res := public._offpay_refresh(o.id);
  if req.id is not null and (amt >= req.amount_xcd or (res->>'balance_due_xcd')::numeric <= 0) then
    update public.order_pay_requests set status = 'paid', paid_at = now(), payment_id = pid where id = req.id;
  end if;
  for u in select * from public._rt_team(o.vendor_id, 'orders_view') loop
    perform public._rt_add(u, 'order_paid_wallet', o.order_number || ': customer paid ' || public._rt_money(amt),
      case when (res->>'balance_due_xcd')::numeric <= 0 then 'Paid in full' else 'Balance due ' || public._rt_money((res->>'balance_due_xcd')::numeric) end || ' · test wallet (play money)',
      'dashboard-vendor.html#orders', 'order', o.id, o.vendor_id, false);
  end loop;
  return res || jsonb_build_object('replay', false, 'payment_id', pid, 'transaction_id', tid, 'amount_xcd', amt,
    'request_paid', req.id is not null and (amt >= req.amount_xcd or (res->>'balance_due_xcd')::numeric <= 0));
end $$;

revoke all on function public.vendor_request_payment(uuid, numeric, text), public.vendor_cancel_pay_request(uuid),
  public.vendor_remind_pay_request(uuid), public.customer_pay_balance(uuid, numeric, text) from public, anon;
grant execute on function public.vendor_request_payment(uuid, numeric, text), public.vendor_cancel_pay_request(uuid),
  public.vendor_remind_pay_request(uuid), public.customer_pay_balance(uuid, numeric, text) to authenticated;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_pay_requests') then
    execute 'alter publication supabase_realtime add table public.order_pay_requests';
  end if;
end $$;

notify pgrst, 'reload schema';
