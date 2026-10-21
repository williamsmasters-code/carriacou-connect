-- =====================================================================================================
-- offline_payments.sql (v1.13) - vendor records cash/card/bank payments for pay-on-pickup / pay-on-delivery orders.
-- RUN ORDER: LAST (after realtime.sql, pos_tax.sql, admin_vat.sql). Needs orders (pay.sql), vendor_perm (staff.sql), _rt_add (realtime.sql).
-- Re-running pay.sql or orders.sql is safe (this file adds its own guard trigger and columns; it does not touch payment_status).
-- Idempotent. Every UPDATE has a WHERE. No DELETE.
-- Design:
--   * order_payments = append-only ledger (rows are never deleted; mistakes are VOIDED with a reason).
--   * orders.offline_status ('unpaid','partial','paid') and orders.amount_paid_xcd are DERIVED from non-void ledger rows,
--     refreshed by the RPCs only (a guard trigger blocks direct client changes). Balance due = total_xcd - amount_paid_xcd.
--   * orders.payment_status (wallet: unpaid/paid/refunded) is left alone; wallet-paid orders cannot get offline payments.
--   * Permissions: record = 'orders_update' (owner, sub-admin, staff). Void = 'refunds' (owner, sub-admin).
--   * The customer gets a notification (realtime bell) on every recorded or voided payment.
-- =====================================================================================================

alter table public.orders add column if not exists offline_status text not null default 'unpaid';
alter table public.orders add column if not exists amount_paid_xcd numeric(10,2) not null default 0;
alter table public.orders add column if not exists offline_paid_at timestamptz;
alter table public.orders drop constraint if exists orders_offline_status_check;
alter table public.orders add constraint orders_offline_status_check check (offline_status in ('unpaid','partial','paid') and amount_paid_xcd >= 0);

create table if not exists public.order_payments (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders(id) on delete cascade,
  vendor_id    uuid not null,
  amount_xcd   numeric(10,2) not null check (amount_xcd > 0),
  kind         text not null check (kind in ('full','partial')),
  method       text not null check (method in ('cash','card','bank','other')),
  note         text check (note is null or char_length(note) <= 200),
  recorded_by  uuid,
  created_at   timestamptz not null default now(),
  voided       boolean not null default false,
  void_reason  text check (void_reason is null or char_length(void_reason) <= 200),
  voided_by    uuid,
  voided_at    timestamptz,
  constraint order_payments_void_ok check ((voided and void_reason is not null and voided_at is not null) or (not voided and void_reason is null and voided_at is null))
);
create index if not exists order_payments_order_idx on public.order_payments(order_id, created_at);
create index if not exists order_payments_vendor_idx on public.order_payments(vendor_id, created_at);

alter table public.order_payments enable row level security;
drop policy if exists order_payments_read on public.order_payments;
create policy order_payments_read on public.order_payments for select to authenticated
  using (public.vendor_perm(vendor_id, 'orders_view') or public.is_admin()
         or exists (select 1 from public.orders o where o.id = order_id and o.consumer_id = auth.uid()));
revoke insert, update, delete on public.order_payments from anon, authenticated;
grant select on public.order_payments to authenticated;

-- guard: clients cannot change the derived columns directly (only the RPCs below, which set cc.offpay = '1')
create or replace function public.orders_offpay_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if coalesce(current_setting('cc.offpay', true), '') <> '1'
     and (new.offline_status is distinct from old.offline_status or new.amount_paid_xcd is distinct from old.amount_paid_xcd
          or new.offline_paid_at is distinct from old.offline_paid_at) then
    raise exception 'Payments are recorded with Paid in full / Paid partially';
  end if;
  -- a customer cannot also pay the full total by wallet once the vendor has recorded part of it in cash/card/bank
  if new.payment_status is distinct from old.payment_status and new.payment_status = 'paid' and old.amount_paid_xcd > 0 then
    raise exception 'Part of this order is already paid to the vendor. Please pay the balance to the vendor directly.';
  end if;
  return new;
end $$;
revoke all on function public.orders_offpay_guard() from public, anon, authenticated;
drop trigger if exists trg_orders_offpay_guard on public.orders;
create trigger trg_orders_offpay_guard before update on public.orders for each row execute function public.orders_offpay_guard();

create or replace function public._offpay_refresh(p_order uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare paid numeric; tot numeric; st text;
begin
  select coalesce(sum(amount_xcd), 0) into paid from public.order_payments where order_id = p_order and not voided;
  select total_xcd into tot from public.orders where id = p_order;
  st := case when paid <= 0 then 'unpaid' when paid >= tot then 'paid' else 'partial' end;
  perform set_config('cc.offpay', '1', true);
  update public.orders set amount_paid_xcd = paid, offline_status = st,
         offline_paid_at = case when st = 'paid' then coalesce(offline_paid_at, now()) else null end
   where id = p_order;
  perform set_config('cc.offpay', '', true);
  return jsonb_build_object('order_id', p_order, 'offline_status', st, 'amount_paid_xcd', paid, 'balance_due_xcd', greatest(tot - paid, 0), 'total_xcd', tot);
end $$;
revoke all on function public._offpay_refresh(uuid) from public, anon, authenticated;

create or replace function public.vendor_record_payment(p_order uuid, p_kind text, p_amount numeric default null, p_method text default 'cash', p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); o record; bal numeric; amt numeric; nt text := nullif(btrim(coalesce(p_note, '')), ''); res jsonb; pid uuid;
begin
  if uid is null then raise exception 'Please sign in'; end if;
  if p_kind not in ('full','partial') then raise exception 'Choose Paid in full or Paid partially'; end if;
  if coalesce(p_method, '') not in ('cash','card','bank','other') then raise exception 'Choose how the customer paid (cash, card, bank or other)'; end if;
  if nt is not null and char_length(nt) > 200 then raise exception 'Note is too long (max 200 characters)'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found or not public.vendor_perm(o.vendor_id, 'orders_update') then raise exception 'Order not found'; end if;
  if o.payment_method = 'pay_with_wallet' or o.payment_status <> 'unpaid' then raise exception 'This order is paid with the wallet; offline payments are not needed'; end if;
  if o.status = 'cancelled' then raise exception 'This order was cancelled'; end if;
  bal := round(o.total_xcd - coalesce((select sum(amount_xcd) from public.order_payments where order_id = o.id and not voided), 0), 2);
  if bal <= 0 then raise exception 'This order is already paid in full'; end if;
  if p_kind = 'full' then amt := bal;
  else
    amt := round(coalesce(p_amount, 0), 2);
    if amt <= 0 then raise exception 'Enter the amount the customer paid'; end if;
    if amt >= bal then raise exception 'A part payment must be less than the balance due (EC$%). Use Paid in full instead.', to_char(bal, 'FM999990.00'); end if;
  end if;
  insert into public.order_payments(order_id, vendor_id, amount_xcd, kind, method, note, recorded_by)
    values (o.id, o.vendor_id, amt, p_kind, p_method, nt, uid) returning id into pid;
  res := public._offpay_refresh(o.id);
  begin
    perform public._rt_add(o.consumer_id, 'payment_recorded',
      'Order ' || o.order_number || ': ' || case when res->>'offline_status' = 'paid' then 'paid in full' else 'part payment received' end,
      public._rt_money(amt) || ' received (' || p_method || '). Balance due ' || public._rt_money((res->>'balance_due_xcd')::numeric) || '.',
      'dashboard-consumer.html?order=' || o.id::text, 'order', o.id, o.vendor_id, false);
  exception when undefined_function then null; end;
  return res || jsonb_build_object('payment_id', pid, 'amount_xcd', amt);
end $$;

create or replace function public.vendor_void_payment(p_payment uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); p record; o record; rs text := nullif(btrim(coalesce(p_reason, '')), ''); res jsonb;
begin
  if uid is null then raise exception 'Please sign in'; end if;
  if rs is null then raise exception 'Give a reason for voiding this payment'; end if;
  if char_length(rs) > 200 then raise exception 'Reason is too long (max 200 characters)'; end if;
  select * into p from public.order_payments where id = p_payment for update;
  if not found or not public.vendor_perm(p.vendor_id, 'refunds') then raise exception 'Payment not found (voiding needs the owner or a sub-admin)'; end if;
  if p.voided then raise exception 'This payment was already voided'; end if;
  select * into o from public.orders where id = p.order_id for update;
  update public.order_payments set voided = true, void_reason = rs, voided_by = uid, voided_at = now() where id = p.id;
  res := public._offpay_refresh(p.order_id);
  begin
    perform public._rt_add(o.consumer_id, 'payment_voided', 'Order ' || o.order_number || ': payment record corrected',
      public._rt_money(p.amount_xcd) || ' payment was voided. Balance due ' || public._rt_money((res->>'balance_due_xcd')::numeric) || '.',
      'dashboard-consumer.html?order=' || o.id::text, 'order', o.id, o.vendor_id, false);
  exception when undefined_function then null; end;
  return res || jsonb_build_object('payment_id', p.id, 'voided', true);
end $$;

revoke all on function public.vendor_record_payment(uuid, text, numeric, text, text), public.vendor_void_payment(uuid, text) from public, anon;
grant execute on function public.vendor_record_payment(uuid, text, numeric, text, text), public.vendor_void_payment(uuid, text) to authenticated;

-- realtime: the order row change is already published; publish the ledger too (ignore if publication missing / already added)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_payments') then
    execute 'alter publication supabase_realtime add table public.order_payments';
  end if;
end $$;

notify pgrst, 'reload schema';
