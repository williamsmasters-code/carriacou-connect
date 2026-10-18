-- Carriacou Connect v1.4 : PLATFORM ADMIN CUSTOMER PROFILE MANAGEMENT (admin only). TEST MODE: no money is moved by anything here.
-- Run this whole file in Supabase SQL Editor AFTER: schema -> seed -> storage -> orders -> order_notes -> pay -> analytics -> staff -> photos
--   -> standard_analytics -> platform_analytics -> advanced_analytics.   Safe to re-run (idempotent).
-- It redefines NO function from an earlier file (suspension is enforced by new TRIGGERS), so re-running earlier files does not undo it
-- (but if you re-run an earlier file, re-run this one last anyway).
-- Supabase uses pg-safeupdate: every UPDATE / DELETE below has a WHERE.
--
-- WHAT IT ADDS
--   * profile_admin: one optional row per person (status active/suspended, reason, internal admin notes). RLS on, no policies, no grants:
--     clients cannot read or write it directly. No row = active.
--   * Suspension is enforced IN THE DATABASE by triggers (not just the screen):
--       - orders (BEFORE INSERT): a suspended customer cannot place an order (place_order, place_order_with_code and anything else that inserts one).
--       - transactions (BEFORE INSERT): a suspended person cannot move money. Blocked when the logged-in user is suspended, when the paying wallet
--         belongs to a suspended person, or when a top-up or transfer is going INTO a suspended person's wallet. Refunds and other money coming
--         back to a suspended customer are still allowed (they are owed that money).
--       - pay_requests (BEFORE INSERT): a suspended person cannot create a POS charge.
--     The error text starts with 'ACCOUNT_SUSPENDED:' (errcode 42501) so the site can show a clear message.
--   * my_account_status(): lets a logged-in person see their OWN status (for the banner on login/checkout). Nobody else's.
--   * Admin functions admin_cust_list / _get / _update / _set_status / _set_role. Each is SECURITY DEFINER, starts with _require_platform_admin(),
--     is REVOKEd from public and anon and granted to `authenticated` only so the admin's browser can call it.
--     A vendor, staff member or consumer who calls one gets "Platform admins only".
--   * Every change writes one row to audit_log (admin id = actor_id, target person = target_user_id, details = before / after / reason).
--
-- RULES
--   * Admin accounts are never listed or changed here (no suspend, no role change, no edit). So an admin cannot demote themselves or the last admin,
--     and the UI/DB cannot grant admin. Admin rights are still given only in the SQL editor.
--   * Role can only be switched between consumer and vendor. Vendor -> consumer is refused while the person owns a business.
--   * Emails come from auth and cannot be changed here. Nobody is deleted (no service_role key is used). 'Suspend' is the deactivate option.
--   * The admin sees email and phone on this screen (they are the operator); other screens stay masked.

-- =====================================================================================================
-- 1. Table
-- =====================================================================================================
create table if not exists public.profile_admin (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  status         text not null default 'active' check (status in ('active','suspended')),
  reason         text check (reason is null or char_length(reason) <= 300),
  suspended_at   timestamptz,
  suspended_by   uuid,
  admin_notes    text check (admin_notes is null or char_length(admin_notes) <= 1000),
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);
alter table public.profile_admin enable row level security;
revoke all on public.profile_admin from public, anon, authenticated;

-- =====================================================================================================
-- 2. Helpers (not callable by clients)
-- =====================================================================================================
create or replace function public._acct_suspended(p_user uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select status = 'suspended' from public.profile_admin where user_id = p_user), false) $$;
revoke all on function public._acct_suspended(uuid) from public, anon, authenticated;

create or replace function public._acct_block() returns void
language plpgsql as $$
begin
  raise exception 'ACCOUNT_SUSPENDED: This account is suspended, so it cannot place orders or use the wallet. Please contact Carriacou Connect support.'
    using errcode = '42501';
end $$;
revoke all on function public._acct_block() from public, anon, authenticated;

-- =====================================================================================================
-- 3. Enforcement triggers
-- =====================================================================================================
create or replace function public.trg_acct_orders_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public._acct_suspended(new.consumer_id) or public._acct_suspended(auth.uid()) then perform public._acct_block(); end if;
  return new;
end $$;
revoke all on function public.trg_acct_orders_guard() from public, anon, authenticated;
drop trigger if exists trg_acct_orders on public.orders;
create trigger trg_acct_orders before insert on public.orders
  for each row execute function public.trg_acct_orders_guard();

create or replace function public.trg_acct_tx_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare fo uuid; fv uuid; too uuid;
begin
  if public._acct_suspended(auth.uid()) then perform public._acct_block(); end if;
  select owner_user_id into fo from public.wallets where id = new.from_wallet and kind = 'user';
  if fo is not null and public._acct_suspended(fo) then perform public._acct_block(); end if;
  if new.type in ('transfer','topup_test') then
    select owner_user_id into too from public.wallets where id = new.to_wallet and kind = 'user';
    if too is not null and public._acct_suspended(too) then perform public._acct_block(); end if;
  end if;
  return new;
end $$;
revoke all on function public.trg_acct_tx_guard() from public, anon, authenticated;
drop trigger if exists trg_acct_tx on public.transactions;
create trigger trg_acct_tx before insert on public.transactions
  for each row execute function public.trg_acct_tx_guard();

create or replace function public.trg_acct_charge_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public._acct_suspended(auth.uid()) then perform public._acct_block(); end if;
  return new;
end $$;
revoke all on function public.trg_acct_charge_guard() from public, anon, authenticated;
drop trigger if exists trg_acct_charge on public.pay_requests;
create trigger trg_acct_charge before insert on public.pay_requests
  for each row execute function public.trg_acct_charge_guard();

-- =====================================================================================================
-- 4. A person's own status (for the login / checkout message). Returns only the caller's own row.
-- =====================================================================================================
create or replace function public.my_account_status() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s boolean;
begin
  if auth.uid() is null then return jsonb_build_object('suspended', false); end if;
  s := public._acct_suspended(auth.uid());
  return jsonb_build_object('suspended', s, 'message', case when s then
    'Your account is suspended. You can still look around, but you cannot place orders or use your wallet. Please contact Carriacou Connect support.' else null end);
end $$;
revoke all on function public.my_account_status() from public, anon;
grant execute on function public.my_account_status() to authenticated;

-- =====================================================================================================
-- 5. Admin functions
-- =====================================================================================================
create or replace function public._cust_target(p_id uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare r text;
begin
  perform public._require_platform_admin();
  if p_id is null then raise exception 'Choose a customer'; end if;
  select role into r from public.profiles where id = p_id;
  if r is null then raise exception 'That person was not found'; end if;
  if r = 'admin' then raise exception 'Admin accounts are not managed here'; end if;
  return r;
end $$;
revoke all on function public._cust_target(uuid) from public, anon, authenticated;

create or replace function public._cust_reason(p_reason text) returns text
language plpgsql immutable as $$
declare t text := btrim(coalesce(p_reason, ''));
begin
  if char_length(t) < 3 then raise exception 'Please give a reason (at least 3 characters)'; end if;
  if char_length(t) > 300 then raise exception 'The reason is too long (max 300 characters)'; end if;
  return t;
end $$;
revoke all on function public._cust_reason(text) from public, anon, authenticated;

-- searchable, paginated list. p_status: all | active | suspended. p_role: consumer | vendor | all. Admins are never listed.
create or replace function public.admin_cust_list(p_q text default null, p_status text default 'all', p_role text default 'consumer',
  p_limit int default 25, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare lim int := least(100, greatest(1, coalesce(p_limit, 25))); off int := greatest(0, coalesce(p_offset, 0));
  q text := nullif(btrim(coalesce(p_q, '')), ''); pat text; total int; rows jsonb;
begin
  perform public._require_platform_admin();
  if coalesce(p_status, 'all') not in ('all','active','suspended') then raise exception 'Unknown status filter'; end if;
  if coalesce(p_role, 'consumer') not in ('consumer','vendor','all') then raise exception 'Unknown role filter'; end if;
  if q is not null and char_length(q) > 100 then raise exception 'Search text is too long'; end if;
  if q is not null then pat := '%' || replace(replace(replace(lower(q), '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with f as (
    select p.id, p.created_at,
      jsonb_build_object('id', p.id, 'name', p.full_name, 'email', u.email, 'phone', p.phone, 'role', p.role,
        'status', coalesce(a.status,'active'), 'joined', p.created_at,
        'orders', (select count(*) from public.orders o where o.consumer_id = p.id),
        'wallet_cents', (select w.balance_cents from public.wallets w where w.owner_user_id = p.id and w.kind = 'user')) x
    from public.profiles p join auth.users u on u.id = p.id left join public.profile_admin a on a.user_id = p.id
    where p.role <> 'admin'
      and (coalesce(p_role,'consumer') = 'all' or p.role = coalesce(p_role,'consumer'))
      and (coalesce(p_status,'all') = 'all' or coalesce(a.status,'active') = p_status)
      and (pat is null or lower(coalesce(p.full_name,'')) like pat escape '\' or lower(coalesce(u.email,'')) like pat escape '\'
           or lower(coalesce(p.phone,'')) like pat escape '\')),
  pg as (select * from f order by created_at desc, id limit lim offset off)
  select (select count(*) from f), coalesce((select jsonb_agg(x order by created_at desc, id) from pg), '[]'::jsonb) into total, rows;
  return jsonb_build_object('total', total, 'limit', lim, 'offset', off, 'rows', rows);
end $$;

create or replace function public.admin_cust_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare pr record; em text; a record; w record; ord jsonb; wal jsonb; hist jsonb; own jsonb;
begin
  perform public._cust_target(p_id);
  select * into pr from public.profiles where id = p_id;
  select email into em from auth.users where id = p_id;
  select * into a from public.profile_admin where user_id = p_id;
  select jsonb_build_object('count', count(*),
      'sales_xcd', coalesce(sum(o.total_xcd) filter (where o.status <> 'cancelled' and o.payment_status <> 'refunded'), 0),
      'cancelled', count(*) filter (where o.status = 'cancelled'),
      'last_order_at', max(o.created_at),
      'recent', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'order_number', r.order_number, 'created_at', r.created_at, 'status', r.status,
            'payment_status', r.payment_status, 'total_xcd', r.total_xcd, 'vendor', v.name) order by r.created_at desc)
          from (select * from public.orders where consumer_id = p_id order by created_at desc limit 10) r left join public.vendors v on v.id = r.vendor_id), '[]'::jsonb))
    into ord from public.orders o where o.consumer_id = p_id;
  select * into w from public.wallets where owner_user_id = p_id and kind = 'user';
  if w.id is null then wal := jsonb_build_object('exists', false);
  else
    select jsonb_build_object('exists', true, 'code', w.code, 'balance_cents', w.balance_cents, 'test_mode', true,
      'received_cents', coalesce(sum(t.amount_cents) filter (where t.to_wallet = w.id), 0),
      'sent_cents', coalesce(sum(t.amount_cents) filter (where t.from_wallet = w.id), 0),
      'transactions', count(*),
      'recent', coalesce((select jsonb_agg(jsonb_build_object('at', r.created_at, 'type', r.type, 'amount_cents', r.amount_cents,
            'direction', case when r.to_wallet = w.id then 'in' else 'out' end, 'note', r.note) order by r.created_at desc, r.id)
          from (select * from public.transactions where from_wallet = w.id or to_wallet = w.id order by created_at desc, id limit 10) r), '[]'::jsonb))
      into wal from public.transactions t where t.from_wallet = w.id or t.to_wallet = w.id;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'tier', v.tier) order by v.created_at), '[]'::jsonb) into own
    from public.vendors v where v.owner_id = p_id;
  select coalesce(jsonb_agg(jsonb_build_object('at', g.at, 'action', g.action, 'by', ua.email, 'details', g.details) order by g.at desc, g.id desc), '[]'::jsonb) into hist
    from (select * from public.audit_log where target_user_id = p_id and action like 'customer\_%' order by at desc, id desc limit 20) g left join auth.users ua on ua.id = g.actor_id;
  return jsonb_build_object('id', p_id, 'name', pr.full_name, 'email', em, 'phone', pr.phone, 'address', pr.address, 'role', pr.role,
    'joined', pr.created_at, 'updated_at', pr.updated_at,
    'status', coalesce(a.status, 'active'), 'reason', a.reason, 'suspended_at', a.suspended_at, 'admin_notes', a.admin_notes,
    'orders', ord, 'wallet', wal, 'businesses', own, 'history', hist);
end $$;

-- edit name / phone / address (profiles) and internal notes (profile_admin). Pass the full new values. Needs a reason. Email is auth-managed.
create or replace function public.admin_cust_update(p_id uuid, p_name text, p_phone text, p_address text, p_notes text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare rsn text; pr record; a record;
  nn text := nullif(btrim(coalesce(p_name,'')), ''); np text := nullif(btrim(coalesce(p_phone,'')), '');
  na text := nullif(btrim(coalesce(p_address,'')), ''); nt text := nullif(btrim(coalesce(p_notes,'')), '');
  before jsonb := '{}'::jsonb; after jsonb := '{}'::jsonb;
begin
  perform public._cust_target(p_id);
  rsn := public._cust_reason(p_reason);
  if char_length(coalesce(nn,'')) > 80 then raise exception 'Name is too long (max 80 characters)'; end if;
  if np is not null and (char_length(np) < 7 or char_length(np) > 30) then raise exception 'Phone must be 7 to 30 characters, or blank'; end if;
  if char_length(coalesce(na,'')) > 300 then raise exception 'Address is too long (max 300 characters)'; end if;
  if char_length(coalesce(nt,'')) > 1000 then raise exception 'Notes are too long (max 1000 characters)'; end if;
  select * into pr from public.profiles where id = p_id for update;
  select * into a from public.profile_admin where user_id = p_id;
  if nn is distinct from pr.full_name then before := before || jsonb_build_object('name', pr.full_name); after := after || jsonb_build_object('name', nn); end if;
  if np is distinct from pr.phone then before := before || jsonb_build_object('phone', pr.phone); after := after || jsonb_build_object('phone', np); end if;
  if na is distinct from pr.address then before := before || jsonb_build_object('address', pr.address); after := after || jsonb_build_object('address', na); end if;
  if nt is distinct from a.admin_notes then before := before || jsonb_build_object('notes', a.admin_notes); after := after || jsonb_build_object('notes', nt); end if;
  if after = '{}'::jsonb then raise exception 'Nothing to change'; end if;
  update public.profiles set full_name = nn, phone = np, address = na where id = p_id;
  insert into public.profile_admin(user_id, admin_notes, updated_by) values (p_id, nt, auth.uid())
    on conflict (user_id) do update set admin_notes = excluded.admin_notes, updated_at = now(), updated_by = auth.uid();
  perform public._audit(null, 'customer_edited', p_id, jsonb_build_object('reason', rsn, 'before', before, 'after', after));
  return jsonb_build_object('ok', true, 'changed', (select jsonb_agg(k) from jsonb_object_keys(after) k));
end $$;

create or replace function public.admin_cust_set_status(p_id uuid, p_suspend boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare rsn text; cur text;
begin
  perform public._cust_target(p_id);
  if p_suspend is null then raise exception 'Choose suspend or reactivate'; end if;
  if p_id = auth.uid() then raise exception 'You cannot change your own account here'; end if;
  rsn := public._cust_reason(p_reason);
  select status into cur from public.profile_admin where user_id = p_id for update;
  cur := coalesce(cur, 'active');
  if p_suspend and cur = 'suspended' then raise exception 'This account is already suspended'; end if;
  if not p_suspend and cur = 'active' then raise exception 'This account is not suspended'; end if;
  if p_suspend then
    insert into public.profile_admin(user_id, status, reason, suspended_at, suspended_by, updated_by) values (p_id, 'suspended', rsn, now(), auth.uid(), auth.uid())
      on conflict (user_id) do update set status = 'suspended', reason = excluded.reason, suspended_at = now(), suspended_by = auth.uid(), updated_at = now(), updated_by = auth.uid();
  else
    update public.profile_admin set status = 'active', reason = null, suspended_at = null, suspended_by = null, updated_at = now(), updated_by = auth.uid() where user_id = p_id;
  end if;
  perform public._audit(null, case when p_suspend then 'customer_suspended' else 'customer_reactivated' end, p_id,
    jsonb_build_object('reason', rsn, 'before', jsonb_build_object('status', cur), 'after', jsonb_build_object('status', case when p_suspend then 'suspended' else 'active' end)));
  return jsonb_build_object('ok', true, 'status', case when p_suspend then 'suspended' else 'active' end);
end $$;

create or replace function public.admin_cust_set_role(p_id uuid, p_role text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare rsn text; cur text;
begin
  if p_role is distinct from 'consumer' and p_role is distinct from 'vendor' then
    perform public._require_platform_admin();
    raise exception 'Role can only be set to consumer or vendor. Admin rights are never granted from the website.';
  end if;
  cur := public._cust_target(p_id);
  if p_id = auth.uid() then raise exception 'You cannot change your own role'; end if;
  rsn := public._cust_reason(p_reason);
  if cur = p_role then raise exception 'This person is already a %', p_role; end if;
  if p_role = 'consumer' and exists (select 1 from public.vendors where owner_id = p_id) then
    raise exception 'This person owns a business. Remove or hand over the business before changing them to a customer.';
  end if;
  update public.profiles set role = p_role where id = p_id;
  perform public._audit(null, 'customer_role_changed', p_id,
    jsonb_build_object('reason', rsn, 'before', jsonb_build_object('role', cur), 'after', jsonb_build_object('role', p_role)));
  return jsonb_build_object('ok', true, 'role', p_role);
end $$;

revoke all on function public.admin_cust_list(text,text,text,int,int), public.admin_cust_get(uuid),
  public.admin_cust_update(uuid,text,text,text,text,text), public.admin_cust_set_status(uuid,boolean,text),
  public.admin_cust_set_role(uuid,text,text) from public, anon;
grant execute on function public.admin_cust_list(text,text,text,int,int), public.admin_cust_get(uuid),
  public.admin_cust_update(uuid,text,text,text,text,text), public.admin_cust_set_status(uuid,boolean,text),
  public.admin_cust_set_role(uuid,text,text) to authenticated;

notify pgrst, 'reload schema';
