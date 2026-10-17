-- Carriacou Connect v0.6 : CARRIACOU CONNECT PAY, *** TEST MODE ONLY ***  (fake play-money, no real funds)
-- Run this whole file once in Supabase Dashboard > SQL Editor (after schema.sql and orders.sql). Safe to re-run.
-- NOTE for Supabase: pg-safeupdate is on, so every UPDATE / DELETE here has a WHERE clause.
--
-- WHAT THIS IS NOT: there is no payment processor, no card or bank details, no real money movement.
-- Balances are integers in XCD cents of PLAY MONEY created out of thin air by test_topup().
-- Going live with real funds needs licensing / legal advice and Daniel's explicit approval (see Pay_Design_Notes.txt).
--
-- DESIGN
--   wallets       one per user (kind 'user'), one per vendor business (kind 'vendor') + one system "test mint" wallet.
--   transactions  APPEND-ONLY double-entry ledger: every row debits from_wallet and credits to_wallet by amount_cents.
--                 Test top-ups are mint -> wallet, so SUM(all balances) = 0 and SUM(user+vendor balances) = SUM(top-ups).
--   ALL money moves ONLY through SECURITY DEFINER functions (clients have no INSERT/UPDATE/DELETE on any pay table),
--   which lock the wallet rows (in id order, so no deadlocks), refuse overdrafts, and cap amounts.
--   Mutating functions accept an idempotency key: the same key replays the first result instead of moving money twice.

-- ---------- limits (single place; also shown in the UI) ----------
create or replace function public.pay_limits() returns jsonb language sql immutable as $$
  select jsonb_build_object('test_mode', true, 'currency', 'XCD',
    'topup_max_cents', 50000,          -- EC$500 per top-up
    'topup_daily_cents', 50000,        -- EC$500 per user per rolling 24h
    'transfer_max_cents', 200000,      -- EC$2,000 per transfer / charge
    'balance_max_cents', 10000000);    -- EC$100,000 per wallet
$$;
grant execute on function public.pay_limits() to anon, authenticated;

-- ---------- orders: payment status (does not touch place_order) ----------
alter table public.orders add column if not exists payment_status text not null default 'unpaid';
alter table public.orders add column if not exists paid_at timestamptz;
alter table public.orders drop constraint if exists orders_payment_status_check;
alter table public.orders add constraint orders_payment_status_check check (payment_status in ('unpaid','paid','refunded'));
alter table public.orders drop constraint if exists orders_payment_check;
alter table public.orders add constraint orders_payment_check check (payment_method in ('pay_on_pickup','pay_on_delivery','pay_with_wallet'));
alter table public.orders drop constraint if exists orders_payment_matches;
alter table public.orders add constraint orders_payment_matches check (
  payment_method = 'pay_with_wallet'
  or (fulfilment = 'pickup' and payment_method = 'pay_on_pickup') or (fulfilment = 'delivery' and payment_method = 'pay_on_delivery'));
-- a wallet-paid / refunded order must say so, and an unpaid one must not be marked with a payment time
alter table public.orders drop constraint if exists orders_payment_consistent;
alter table public.orders add constraint orders_payment_consistent check (
  (payment_status = 'unpaid' and paid_at is null) or (payment_status in ('paid','refunded') and paid_at is not null and payment_method = 'pay_with_wallet'));

-- order guard: same as orders.sql v0.6 (adds the cc.pay_internal bypass used ONLY by pay functions, and protects payment columns)
create or replace function public.orders_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare is_vendor boolean; is_cons boolean; ok boolean := false;
begin
  if auth.uid() is not null and not public.is_admin() and coalesce(current_setting('cc.pay_internal', true),'') <> '1' then
    if new.id is distinct from old.id or new.order_number is distinct from old.order_number
       or new.consumer_id is distinct from old.consumer_id or new.vendor_id is distinct from old.vendor_id
       or new.fulfilment is distinct from old.fulfilment or new.payment_method is distinct from old.payment_method
       or new.total_xcd is distinct from old.total_xcd or new.subtotal_xcd is distinct from old.subtotal_xcd
       or new.delivery_fee_xcd is distinct from old.delivery_fee_xcd
       or new.contact_name is distinct from old.contact_name or new.contact_phone is distinct from old.contact_phone
       or new.delivery_address is distinct from old.delivery_address or new.notes is distinct from old.notes
       or new.created_at is distinct from old.created_at
       or to_jsonb(new)->'payment_status' is distinct from to_jsonb(old)->'payment_status'
       or to_jsonb(new)->'paid_at' is distinct from to_jsonb(old)->'paid_at' then
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

-- ---------- wallets ----------
create table if not exists public.wallets (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in ('user','vendor','system')),
  owner_user_id uuid references auth.users(id) on delete restrict,
  vendor_id     uuid references public.vendors(id) on delete restrict,
  code          text not null,
  balance_cents bigint not null default 0,
  currency      text not null default 'XCD' check (currency = 'XCD'),
  created_at    timestamptz not null default now(),
  constraint wallets_owner_ck check (
    (kind = 'user'   and owner_user_id is not null and vendor_id is null) or
    (kind = 'vendor' and vendor_id is not null and owner_user_id is null) or
    (kind = 'system' and owner_user_id is null and vendor_id is null)),
  constraint wallets_balance_ck check ((kind = 'system' and balance_cents <= 0) or (kind <> 'system' and balance_cents between 0 and 10000000)),
  constraint wallets_code_ck check (code ~ '^CC-[A-Z2-9]{4}-[A-Z2-9]{4}$')
);
create unique index if not exists wallets_code_key on public.wallets(code);
create unique index if not exists wallets_user_key on public.wallets(owner_user_id) where kind = 'user';
create unique index if not exists wallets_vendor_key on public.wallets(vendor_id) where kind = 'vendor';
create unique index if not exists wallets_system_key on public.wallets(kind) where kind = 'system';

-- the one system "test mint" wallet: all play money starts here (its balance goes negative = total issued)
insert into public.wallets(id, kind, code) values ('00000000-0000-0000-0000-00000000c0de', 'system', 'CC-MINT-TEST')
  on conflict do nothing;

-- ---------- ledger (append-only) ----------
create table if not exists public.transactions (
  id              uuid primary key default gen_random_uuid(),
  type            text not null check (type in ('topup_test','transfer','order_payment','refund','adjustment')),
  from_wallet     uuid not null references public.wallets(id) on delete restrict,
  to_wallet       uuid not null references public.wallets(id) on delete restrict,
  amount_cents    bigint not null check (amount_cents > 0 and amount_cents <= 10000000),
  currency        text not null default 'XCD' check (currency = 'XCD'),
  note            text check (note is null or char_length(note) <= 200),
  order_id        uuid references public.orders(id) on delete restrict,
  charge_id       uuid,
  status          text not null default 'completed' check (status in ('completed')),
  test_mode       boolean not null default true check (test_mode),   -- play money; a live-money ledger needs a deliberate migration
  created_by      uuid,
  idempotency_key text check (idempotency_key is null or char_length(idempotency_key) between 8 and 100),
  created_at      timestamptz not null default now(),
  constraint transactions_distinct_ck check (from_wallet <> to_wallet)
);
create index if not exists transactions_from_idx on public.transactions(from_wallet, created_at desc);
create index if not exists transactions_to_idx on public.transactions(to_wallet, created_at desc);
create unique index if not exists transactions_idem_key on public.transactions(created_by, idempotency_key) where idempotency_key is not null;
create unique index if not exists transactions_one_payment_per_order on public.transactions(order_id) where type = 'order_payment';
create unique index if not exists transactions_one_refund_per_order on public.transactions(order_id) where type = 'refund';

-- append-only for EVERYONE (clients, admins, the SQL editor): no update, delete or truncate.
-- (To wipe test data, an operator must deliberately disable this trigger in the SQL editor; see Pay_Design_Notes.txt.)
create or replace function public.transactions_append_only() returns trigger language plpgsql as $$
begin raise exception 'The ledger is append-only: transactions cannot be changed or deleted'; end $$;
drop trigger if exists trg_transactions_append_only on public.transactions;
create trigger trg_transactions_append_only before update or delete on public.transactions
  for each row execute function public.transactions_append_only();
drop trigger if exists trg_transactions_no_truncate on public.transactions;
create trigger trg_transactions_no_truncate before truncate on public.transactions
  for each statement execute function public.transactions_append_only();

-- ---------- POS charge requests ----------
create table if not exists public.pay_requests (
  id             uuid primary key default gen_random_uuid(),
  code           text not null check (code ~ '^PAY-[A-Z2-9]{4}-[A-Z2-9]{4}$'),
  vendor_id      uuid not null references public.vendors(id) on delete restrict,
  wallet_id      uuid not null references public.wallets(id) on delete restrict,
  amount_cents   bigint not null check (amount_cents > 0 and amount_cents <= 200000),
  note           text check (note is null or char_length(note) <= 200),
  items          jsonb not null default '[]'::jsonb,
  status         text not null default 'open' check (status in ('open','paid','cancelled')),
  expires_at     timestamptz not null default (now() + interval '15 minutes'),
  paid_by        uuid,
  transaction_id uuid references public.transactions(id),
  created_at     timestamptz not null default now()
);
create unique index if not exists pay_requests_code_key on public.pay_requests(code);
create index if not exists pay_requests_vendor_idx on public.pay_requests(vendor_id, created_at desc);

-- lookups that found nothing (rate limiting; no personal data)
create table if not exists public.pay_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  kind text not null,
  at timestamptz not null default now()
);
create index if not exists pay_attempts_idx on public.pay_attempts(user_id, at desc);

-- ---------- access helpers ----------
create or replace function public.can_access_wallet(p_wallet uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and exists (
    select 1 from public.wallets w
    where w.id = p_wallet and w.kind <> 'system'
      and (w.owner_user_id = auth.uid()
           or exists (select 1 from public.vendors v where v.id = w.vendor_id and v.owner_id = auth.uid())));
$$;
revoke all on function public.can_access_wallet(uuid) from public, anon;
grant execute on function public.can_access_wallet(uuid) to authenticated;

-- ---------- Row Level Security + grants (read-only for clients; NO insert/update/delete) ----------
alter table public.wallets enable row level security;
alter table public.transactions enable row level security;
alter table public.pay_requests enable row level security;
alter table public.pay_attempts enable row level security;

drop policy if exists wallets_select on public.wallets;
create policy wallets_select on public.wallets for select
  using (public.can_access_wallet(id) or public.is_admin());
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions for select
  using (public.can_access_wallet(from_wallet) or public.can_access_wallet(to_wallet) or public.is_admin());
drop policy if exists pay_requests_select on public.pay_requests;
create policy pay_requests_select on public.pay_requests for select
  using (exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()) or public.is_admin());
-- pay_attempts: no policy at all = nobody (except the owner role / functions) can read it

revoke all on public.wallets, public.transactions, public.pay_requests, public.pay_attempts from public, anon, authenticated;
grant select on public.wallets, public.transactions, public.pay_requests to authenticated;

-- ---------- internal helpers (NOT callable by clients) ----------
create or replace function public._pay_alphabet_code(p_prefix text) returns text language plpgsql volatile as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; r text := ''; i int;   -- no I, O, 0, 1 (easy to read aloud)
begin
  for i in 1..8 loop r := r || substr(a, 1 + floor(random() * 32)::int, 1); end loop;
  return p_prefix || '-' || substr(r,1,4) || '-' || substr(r,5,4);
end $$;

create or replace function public._pay_personal_wallet(p_user uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare w uuid; n int := 0;
begin
  loop
    select id into w from public.wallets where kind = 'user' and owner_user_id = p_user;
    if w is not null then return w; end if;
    n := n + 1; if n > 20 then raise exception 'Could not create wallet'; end if;
    insert into public.wallets(kind, owner_user_id, code) values ('user', p_user, public._pay_alphabet_code('CC')) on conflict do nothing;
  end loop;
end $$;

create or replace function public._pay_vendor_wallet(p_vendor uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare w uuid; n int := 0;
begin
  loop
    select id into w from public.wallets where kind = 'vendor' and vendor_id = p_vendor;
    if w is not null then return w; end if;
    n := n + 1; if n > 20 then raise exception 'Could not create wallet'; end if;
    insert into public.wallets(kind, vendor_id, code) values ('vendor', p_vendor, public._pay_alphabet_code('CC')) on conflict do nothing;
  end loop;
end $$;

create or replace function public._pay_label(p_wallet uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case w.kind
    when 'system' then 'Test top-up (play money)'
    when 'vendor' then coalesce((select v.name from public.vendors v where v.id = w.vendor_id), 'Vendor')
    else coalesce((select nullif(btrim(split_part(p.full_name,' ',1)),'') ||
                          case when position(' ' in btrim(p.full_name)) > 0 then ' ' || upper(left(btrim(substring(btrim(p.full_name) from '[^ ]+$')),1)) || '.' else '' end
                   from public.profiles p where p.id = w.owner_user_id), 'Wallet ' || w.code) end
  from public.wallets w where w.id = p_wallet;
$$;

-- THE ONLY place balances change. Locks both wallets in id order, refuses overdraft / over-cap, writes the ledger row.
create or replace function public._pay_move(p_type text, p_from uuid, p_to uuid, p_amount bigint, p_note text,
  p_order uuid, p_charge uuid, p_actor uuid, p_key text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare fk text; tk text; fb bigint; tb bigint; tid uuid; lim jsonb := public.pay_limits(); nt text := nullif(btrim(coalesce(p_note,'')),'');
begin
  if p_amount is null or p_amount < 1 then raise exception 'Amount must be at least EC$0.01'; end if;
  if p_amount > (lim->>'transfer_max_cents')::bigint and p_type = 'transfer' then
    raise exception 'Amount is over the test limit of EC$%', (lim->>'transfer_max_cents')::bigint / 100; end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'You cannot send money to the same wallet'; end if;
  if nt is not null and char_length(nt) > 200 then raise exception 'Note is too long (max 200 characters)'; end if;
  perform 1 from public.wallets where id in (p_from, p_to) order by id for update;   -- lock in id order = no deadlocks
  select kind, balance_cents into fk, fb from public.wallets where id = p_from;
  select kind, balance_cents into tk, tb from public.wallets where id = p_to;
  if fk is null or tk is null then raise exception 'Wallet not found'; end if;
  if tk = 'system' then raise exception 'You cannot send money to the test mint'; end if;
  if fk <> 'system' and fb < p_amount then raise exception 'Insufficient test balance'; end if;
  if tb + p_amount > (lim->>'balance_max_cents')::bigint then raise exception 'That would take the receiving wallet over the test balance limit'; end if;
  update public.wallets set balance_cents = balance_cents - p_amount where id = p_from;
  update public.wallets set balance_cents = balance_cents + p_amount where id = p_to;
  insert into public.transactions(type, from_wallet, to_wallet, amount_cents, note, order_id, charge_id, created_by, idempotency_key)
    values (p_type, p_from, p_to, p_amount, nt, p_order, p_charge, p_actor, p_key) returning id into tid;
  return tid;
end $$;

-- idempotency: returns the earlier result for (actor, key), or null if new. Same key + different request = error.
create or replace function public._pay_idem(p_actor uuid, p_key text, p_type text, p_from uuid, p_to uuid, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t record;
begin
  if p_key is null then return null; end if;
  if char_length(p_key) < 8 or char_length(p_key) > 100 then raise exception 'Idempotency key must be 8 to 100 characters'; end if;
  perform pg_advisory_xact_lock(hashtext('pay-idem:' || p_actor::text || ':' || p_key));
  select * into t from public.transactions where created_by = p_actor and idempotency_key = p_key;
  if not found then return null; end if;
  if t.type <> p_type or t.amount_cents <> p_amount or (p_from is not null and t.from_wallet <> p_from) or (p_to is not null and t.to_wallet <> p_to) then
    raise exception 'This idempotency key was already used for a different request'; end if;
  return jsonb_build_object('ok', true, 'replay', true, 'transaction_id', t.id, 'amount_cents', t.amount_cents, 'created_at', t.created_at);
end $$;

create or replace function public._pay_throttle(p_user uuid, p_kind text, p_max int, p_msg text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from public.pay_attempts where at < now() - interval '1 day';
  if (select count(*) from public.pay_attempts where user_id = p_user and kind = p_kind and at > now() - interval '10 minutes') >= p_max then
    raise exception '%', p_msg; end if;
end $$;

-- resolve "CC-ABCD-EFGH" (wallet code) or an email address to a payable wallet id. null = not found.
create or replace function public._pay_resolve(p_to text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s text := upper(regexp_replace(btrim(coalesce(p_to,'')), '\s+', '', 'g')); w uuid; uid uuid;
begin
  if s = '' or char_length(s) > 200 then return null; end if;
  if position('@' in s) > 0 then
    select id into uid from auth.users where lower(email) = lower(btrim(p_to)) limit 1;
    if uid is null then return null; end if;
    return public._pay_personal_wallet(uid);
  end if;
  if s ~ '^CC[A-Z2-9]{8}$' then s := 'CC-' || substr(s,3,4) || '-' || substr(s,7,4); end if;
  if s !~ '^CC-[A-Z2-9]{4}-[A-Z2-9]{4}$' then return null; end if;
  select id into w from public.wallets where code = s and kind <> 'system';
  return w;
end $$;

revoke all on function public._pay_alphabet_code(text), public._pay_personal_wallet(uuid), public._pay_vendor_wallet(uuid),
  public._pay_label(uuid), public._pay_move(text,uuid,uuid,bigint,text,uuid,uuid,uuid,text),
  public._pay_idem(uuid,text,text,uuid,uuid,bigint), public._pay_throttle(uuid,text,int,text), public._pay_resolve(text)
  from public, anon, authenticated;

-- ---------- public API (all SECURITY DEFINER, authenticated only) ----------
-- my wallets (creates them on first call): [{id, kind, code, label, balance_cents, vendor_id}]
create or replace function public.ensure_wallets() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please log in'; end if;
  perform public._pay_personal_wallet(uid);
  perform public._pay_vendor_wallet(v.id) from public.vendors v where v.owner_id = uid;
  return coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'kind', w.kind, 'code', w.code,
      'label', case when w.kind = 'vendor' then public._pay_label(w.id) else 'My wallet' end,
      'balance_cents', w.balance_cents, 'vendor_id', w.vendor_id) order by w.kind desc, w.created_at)
    from public.wallets w where public.can_access_wallet(w.id)), '[]'::jsonb);
end $$;

-- play-money top-up: EC$500 per top-up and per rolling 24h, per user
create or replace function public.test_topup(p_amount_cents bigint, p_idempotency_key text default null, p_wallet uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); w uuid; r jsonb; used bigint; tid uuid; lim jsonb := public.pay_limits(); mint constant uuid := '00000000-0000-0000-0000-00000000c0de';
begin
  if uid is null then raise exception 'Please log in'; end if;
  if p_amount_cents is null or p_amount_cents < 1 then raise exception 'Amount must be at least EC$0.01'; end if;
  if p_amount_cents > (lim->>'topup_max_cents')::bigint then raise exception 'Test top-ups are limited to EC$% each', (lim->>'topup_max_cents')::bigint / 100; end if;
  w := coalesce(p_wallet, public._pay_personal_wallet(uid));
  if not public.can_access_wallet(w) then raise exception 'That wallet is not yours'; end if;
  r := public._pay_idem(uid, p_idempotency_key, 'topup_test', mint, w, p_amount_cents);
  if r is not null then return r; end if;
  perform pg_advisory_xact_lock(hashtext('pay-topup:' || uid::text));              -- serialise the daily-cap check per user
  select coalesce(sum(amount_cents), 0) into used from public.transactions
    where type = 'topup_test' and created_by = uid and created_at > now() - interval '24 hours';
  if used + p_amount_cents > (lim->>'topup_daily_cents')::bigint then
    raise exception 'Daily test top-up limit reached (EC$% per 24 hours; EC$% left)', (lim->>'topup_daily_cents')::bigint / 100, greatest(0, (lim->>'topup_daily_cents')::bigint - used) / 100.0; end if;
  tid := public._pay_move('topup_test', mint, w, p_amount_cents, 'Test top-up (play money)', null, null, uid, p_idempotency_key);
  return jsonb_build_object('ok', true, 'replay', false, 'transaction_id', tid, 'amount_cents', p_amount_cents,
    'balance_cents', (select balance_cents from public.wallets where id = w));
end $$;

-- wallet-to-wallet transfer. p_to = wallet code (CC-XXXX-XXXX) or an email address.
-- Unknown recipient returns {ok:false, error:'recipient_not_found'} (same answer for every miss; misses are rate limited).
create or replace function public.transfer_wallet(p_to text, p_amount_cents bigint, p_note text default null,
  p_idempotency_key text default null, p_from_wallet uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); f uuid; t uuid; r jsonb; tid uuid;
begin
  if uid is null then raise exception 'Please log in'; end if;
  if p_amount_cents is null or p_amount_cents < 1 then raise exception 'Amount must be at least EC$0.01'; end if;
  f := coalesce(p_from_wallet, public._pay_personal_wallet(uid));
  if not public.can_access_wallet(f) then raise exception 'That wallet is not yours'; end if;
  perform public._pay_throttle(uid, 'lookup', 10, 'Too many unknown recipients. Please wait a few minutes.');
  t := public._pay_resolve(p_to);
  if t is null then
    insert into public.pay_attempts(user_id, kind) values (uid, 'lookup');
    return jsonb_build_object('ok', false, 'error', 'recipient_not_found');
  end if;
  if t = f then raise exception 'You cannot send money to your own wallet'; end if;
  r := public._pay_idem(uid, p_idempotency_key, 'transfer', f, t, p_amount_cents);
  if r is not null then return r; end if;
  if (select count(*) from public.transactions where created_by = uid and type = 'transfer' and created_at > now() - interval '10 minutes') >= 20 then
    raise exception 'You are sending too fast. Please wait a few minutes.'; end if;
  tid := public._pay_move('transfer', f, t, p_amount_cents, p_note, null, null, uid, p_idempotency_key);
  return jsonb_build_object('ok', true, 'replay', false, 'transaction_id', tid, 'amount_cents', p_amount_cents,
    'to_label', public._pay_label(t), 'balance_cents', (select balance_cents from public.wallets where id = f));
end $$;

-- who would I be paying? (masked label so you can confirm before sending). Code only, rate limited.
create or replace function public.wallet_preview(p_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); t uuid;
begin
  if uid is null then raise exception 'Please log in'; end if;
  perform public._pay_throttle(uid, 'lookup', 10, 'Too many unknown codes. Please wait a few minutes.');
  if position('@' in coalesce(p_code,'')) > 0 then return jsonb_build_object('ok', false, 'error', 'recipient_not_found'); end if;  -- no email probing
  t := public._pay_resolve(p_code);
  if t is null then insert into public.pay_attempts(user_id, kind) values (uid, 'lookup'); return jsonb_build_object('ok', false, 'error', 'recipient_not_found'); end if;
  return jsonb_build_object('ok', true, 'label', public._pay_label(t), 'is_vendor', (select kind = 'vendor' from public.wallets where id = t));
end $$;

-- my transaction history for one of my wallets, newest first. Counterparty is a masked label only.
create or replace function public.wallet_history(p_wallet uuid, p_limit int default 50, p_before timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.can_access_wallet(p_wallet) then raise exception 'That wallet is not yours'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
    select jsonb_build_object('id', t.id, 'type', t.type, 'direction', case when t.to_wallet = p_wallet then 'in' else 'out' end,
      'amount_cents', t.amount_cents, 'note', t.note, 'order_id', t.order_id, 'status', t.status, 'created_at', t.created_at,
      'counterparty', public._pay_label(case when t.to_wallet = p_wallet then t.from_wallet else t.to_wallet end)) x
    from public.transactions t where (t.from_wallet = p_wallet or t.to_wallet = p_wallet) and (p_before is null or t.created_at < p_before)
    order by t.created_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) s), '[]'::jsonb);
end $$;

-- ---------- order payments ----------
create or replace function public._pay_order_internal(p_order uuid, p_actor uuid, p_key text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o record; cents bigint; f uuid; t uuid; tid uuid;
begin
  select * into o from public.orders where id = p_order for update;           -- row lock: two taps cannot both pay
  if not found or o.consumer_id <> p_actor then raise exception 'Order not found'; end if;
  if o.payment_status = 'paid' then return jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'payment_status', 'paid', 'replay', true); end if;
  if o.payment_status = 'refunded' then raise exception 'This order was refunded and cannot be paid again'; end if;
  if o.status in ('cancelled','completed') then raise exception 'Order % is % and cannot be paid', o.order_number, o.status; end if;
  cents := round(o.total_xcd * 100)::bigint;
  if cents < 1 then raise exception 'This order has no amount to pay'; end if;
  f := public._pay_personal_wallet(p_actor);
  t := public._pay_vendor_wallet(o.vendor_id);
  tid := public._pay_move('order_payment', f, t, cents, 'Order ' || o.order_number, o.id, null, p_actor,
         case when p_key is null then null else left(p_key, 60) || ':' || o.id::text end);
  perform set_config('cc.pay_internal', '1', true);
  update public.orders set payment_status = 'paid', payment_method = 'pay_with_wallet', paid_at = now() where id = o.id;
  perform set_config('cc.pay_internal', '', true);
  return jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'payment_status', 'paid', 'replay', false,
    'transaction_id', tid, 'amount_cents', cents);
end $$;
revoke all on function public._pay_order_internal(uuid,uuid,text) from public, anon, authenticated;

-- pay several orders from the wallet in ONE transaction (all or nothing). Idempotent per order.
create or replace function public.pay_orders(p_order_ids uuid[], p_idempotency_key text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); id uuid; res jsonb := '[]'::jsonb;
begin
  if uid is null then raise exception 'Please log in'; end if;
  if p_order_ids is null or cardinality(p_order_ids) = 0 then raise exception 'No orders to pay'; end if;
  if cardinality(p_order_ids) > 10 then raise exception 'Too many orders at once (max 10)'; end if;
  if p_idempotency_key is not null and (char_length(p_idempotency_key) < 8 or char_length(p_idempotency_key) > 60) then raise exception 'Idempotency key must be 8 to 60 characters'; end if;
  for id in select distinct x from unnest(p_order_ids) x order by x loop      -- fixed order = no deadlocks
    res := res || jsonb_build_array(public._pay_order_internal(id, uid, p_idempotency_key));
  end loop;
  return res;
end $$;

create or replace function public.pay_order(p_order_id uuid, p_idempotency_key text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  return (public.pay_orders(array[p_order_id], p_idempotency_key))->0;
end $$;

-- refund: returns the order's money from the vendor wallet to the customer's wallet (vendor only; idempotent)
create or replace function public._pay_refund_internal(p_order uuid, p_actor uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o record; cents bigint; tid uuid;
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Order not found'; end if;
  if o.payment_status = 'refunded' then return jsonb_build_object('order_id', o.id, 'payment_status', 'refunded', 'replay', true); end if;
  if o.payment_status <> 'paid' then raise exception 'Order % has not been paid from a wallet, so there is nothing to refund', o.order_number; end if;
  cents := round(o.total_xcd * 100)::bigint;
  begin
    tid := public._pay_move('refund', public._pay_vendor_wallet(o.vendor_id), public._pay_personal_wallet(o.consumer_id), cents,
           'Refund for order ' || o.order_number, o.id, null, p_actor, null);
  exception when others then
    if sqlerrm like 'Insufficient%' then raise exception 'The vendor wallet does not have enough test balance to refund this order'; end if;
    raise;
  end;
  perform set_config('cc.pay_internal', '1', true);
  update public.orders set payment_status = 'refunded' where id = o.id;
  perform set_config('cc.pay_internal', '', true);
  return jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'payment_status', 'refunded', 'replay', false, 'transaction_id', tid, 'amount_cents', cents);
end $$;
revoke all on function public._pay_refund_internal(uuid,uuid) from public, anon, authenticated;

create or replace function public.refund_order(p_order_id uuid, p_idempotency_key text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please log in'; end if;
  if not exists (select 1 from public.orders o join public.vendors v on v.id = o.vendor_id where o.id = p_order_id and v.owner_id = uid) then
    raise exception 'Order not found'; end if;
  return public._pay_refund_internal(p_order_id, uid);
end $$;

-- cancelling a PAID order (by the customer or the vendor) automatically refunds it, in the same transaction
create or replace function public.orders_pay_on_cancel() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare cents bigint; tid uuid;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' and old.payment_status = 'paid' then
    cents := round(old.total_xcd * 100)::bigint;
    begin
      tid := public._pay_move('refund', public._pay_vendor_wallet(old.vendor_id), public._pay_personal_wallet(old.consumer_id), cents,
             'Refund: order ' || old.order_number || ' cancelled', old.id, null, auth.uid(), null);
    exception when others then
      if sqlerrm like 'Insufficient%' then raise exception 'Cannot cancel yet: the vendor wallet does not have enough test balance to refund this paid order'; end if;
      raise;
    end;
    new.payment_status := 'refunded';
  end if;
  return new;
end $$;
revoke all on function public.orders_pay_on_cancel() from public, anon, authenticated;
drop trigger if exists trg_orders_pay_cancel on public.orders;
create trigger trg_orders_pay_cancel before update on public.orders
  for each row execute function public.orders_pay_on_cancel();

-- ---------- POS: vendor creates a charge request, a customer pays it with a code ----------
create or replace function public.create_charge(p_amount_cents bigint, p_note text default null, p_items jsonb default '[]'::jsonb, p_vendor_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); v uuid; w uuid; cid uuid; cd text; n int := 0; exp timestamptz; nt text := nullif(btrim(coalesce(p_note,'')),'');
  it jsonb := coalesce(p_items, '[]'::jsonb);
begin
  if uid is null then raise exception 'Please log in'; end if;
  select id into v from public.vendors where owner_id = uid and (p_vendor_id is null or id = p_vendor_id) order by created_at limit 1;
  if v is null then raise exception 'Only a vendor business can create charges'; end if;
  if p_amount_cents is null or p_amount_cents < 1 then raise exception 'Amount must be at least EC$0.01'; end if;
  if p_amount_cents > (public.pay_limits()->>'transfer_max_cents')::bigint then raise exception 'Amount is over the test limit of EC$%', (public.pay_limits()->>'transfer_max_cents')::bigint / 100; end if;
  if nt is not null and char_length(nt) > 200 then raise exception 'Note is too long (max 200 characters)'; end if;
  if jsonb_typeof(it) <> 'array' or jsonb_array_length(it) > 50 or octet_length(it::text) > 6000 then raise exception 'Invalid item list'; end if;
  perform pg_advisory_xact_lock(hashtext('pay-charge:' || v::text));
  if (select count(*) from public.pay_requests where vendor_id = v and status = 'open' and expires_at > now()) >= 20 then
    raise exception 'Too many open charges. Cancel some first.'; end if;
  w := public._pay_vendor_wallet(v);
  loop
    n := n + 1; if n > 20 then raise exception 'Could not create charge'; end if;
    cd := public._pay_alphabet_code('PAY');
    insert into public.pay_requests(code, vendor_id, wallet_id, amount_cents, note, items) values (cd, v, w, p_amount_cents, nt, it)
      on conflict do nothing returning id, expires_at into cid, exp;
    exit when cid is not null;
  end loop;
  return jsonb_build_object('id', cid, 'code', cd, 'amount_cents', p_amount_cents, 'expires_at', exp);
end $$;

create or replace function public.cancel_charge(p_charge_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c record;
begin
  select pr.* into c from public.pay_requests pr join public.vendors v on v.id = pr.vendor_id
    where pr.id = p_charge_id and v.owner_id = auth.uid() for update of pr;
  if not found then raise exception 'Charge not found'; end if;
  if c.status = 'paid' then raise exception 'This charge was already paid'; end if;
  update public.pay_requests set status = 'cancelled' where id = c.id;
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

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
    'status', case when c.status = 'open' and c.expires_at <= now() then 'expired' else c.status end, 'expires_at', c.expires_at);
end $$;

create or replace function public.pay_charge(p_code text, p_idempotency_key text default null, p_from_wallet uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); c record; f uuid; tid uuid; s text := upper(regexp_replace(btrim(coalesce(p_code,'')), '\s+', '', 'g'));
begin
  if uid is null then raise exception 'Please log in'; end if;
  if p_idempotency_key is not null and (char_length(p_idempotency_key) < 8 or char_length(p_idempotency_key) > 100) then raise exception 'Idempotency key must be 8 to 100 characters'; end if;
  perform public._pay_throttle(uid, 'lookup', 10, 'Too many unknown codes. Please wait a few minutes.');
  if s ~ '^PAY[A-Z2-9]{8}$' then s := 'PAY-' || substr(s,4,4) || '-' || substr(s,8,4); end if;
  select * into c from public.pay_requests where code = s for update;
  if not found then insert into public.pay_attempts(user_id, kind) values (uid, 'lookup'); return jsonb_build_object('ok', false, 'error', 'charge_not_found'); end if;
  if c.status = 'paid' then
    if c.paid_by = uid then return jsonb_build_object('ok', true, 'replay', true, 'transaction_id', c.transaction_id, 'amount_cents', c.amount_cents); end if;
    raise exception 'This charge has already been paid';
  end if;
  if c.status = 'cancelled' then raise exception 'This charge was cancelled by the vendor'; end if;
  if c.expires_at <= now() then raise exception 'This charge has expired. Ask the vendor for a new one.'; end if;
  f := coalesce(p_from_wallet, public._pay_personal_wallet(uid));
  if not public.can_access_wallet(f) then raise exception 'That wallet is not yours'; end if;
  if f = c.wallet_id then raise exception 'You cannot pay your own charge from the same wallet'; end if;
  tid := public._pay_move('transfer', f, c.wallet_id, c.amount_cents, 'POS charge ' || c.code || coalesce(': ' || c.note, ''), null, c.id, uid, p_idempotency_key);
  update public.pay_requests set status = 'paid', paid_by = uid, transaction_id = tid where id = c.id;
  return jsonb_build_object('ok', true, 'replay', false, 'transaction_id', tid, 'amount_cents', c.amount_cents,
    'balance_cents', (select balance_cents from public.wallets where id = f));
end $$;

-- ---------- reconciliation ----------
-- Checks, from the ledger alone: every wallet balance = credits - debits; no negative wallets;
-- SUM(user+vendor balances) = total issued by the mint = test top-ups + adjustments.
create or replace function public.pay_reconcile() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare su bigint; sysb bigint; topups bigint; adj bigint; issued bigint; mism int; neg int;
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'Admins only'; end if;
  select coalesce(sum(balance_cents) filter (where kind <> 'system'), 0), coalesce(sum(balance_cents) filter (where kind = 'system'), 0)
    into su, sysb from public.wallets;
  select coalesce(sum(amount_cents) filter (where type = 'topup_test'), 0) into topups from public.transactions;
  select coalesce(sum(case when from_wallet = m.id then amount_cents else -amount_cents end), 0) into issued
    from public.transactions t join public.wallets m on m.kind = 'system' and m.id in (t.from_wallet, t.to_wallet);
  adj := issued - topups;
  select count(*) into mism from (
    select w.id from public.wallets w
    left join public.transactions t on w.id in (t.from_wallet, t.to_wallet) and t.status = 'completed'
    group by w.id, w.balance_cents
    having w.balance_cents <> coalesce(sum(case when t.to_wallet = w.id then t.amount_cents else 0 end), 0) - coalesce(sum(case when t.from_wallet = w.id then t.amount_cents else 0 end), 0)) x;
  select count(*) into neg from public.wallets where kind <> 'system' and balance_cents < 0;
  return jsonb_build_object('ok', (su = topups + adj and su = -sysb and mism = 0 and neg = 0),
    'sum_user_and_vendor_balances_cents', su, 'system_mint_balance_cents', sysb, 'total_test_topups_cents', topups,
    'net_adjustments_cents', adj, 'wallets_not_matching_ledger', mism, 'negative_wallets', neg);
end $$;
revoke all on function public.pay_reconcile() from public, anon;
grant execute on function public.pay_reconcile() to authenticated;   -- admins only (checked inside)

drop view if exists public.pay_reconciliation;
create view public.pay_reconciliation as select public.pay_reconcile() as result;
revoke all on public.pay_reconciliation from public, anon, authenticated;

-- ---------- execute rights: logged-in users only ----------
revoke all on function public.ensure_wallets(), public.test_topup(bigint,text,uuid), public.transfer_wallet(text,bigint,text,text,uuid),
  public.wallet_preview(text), public.wallet_history(uuid,int,timestamptz), public.pay_orders(uuid[],text), public.pay_order(uuid,text),
  public.refund_order(uuid,text), public.create_charge(bigint,text,jsonb,uuid), public.cancel_charge(uuid), public.charge_preview(text),
  public.pay_charge(text,text,uuid) from public, anon;
grant execute on function public.ensure_wallets(), public.test_topup(bigint,text,uuid), public.transfer_wallet(text,bigint,text,text,uuid),
  public.wallet_preview(text), public.wallet_history(uuid,int,timestamptz), public.pay_orders(uuid[],text), public.pay_order(uuid,text),
  public.refund_order(uuid,text), public.create_charge(bigint,text,jsonb,uuid), public.cancel_charge(uuid), public.charge_preview(text),
  public.pay_charge(text,text,uuid) to authenticated;

-- make the API pick up the new tables/columns/functions right away
notify pgrst, 'reload schema';
