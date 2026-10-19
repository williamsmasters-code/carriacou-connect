-- Carriacou Connect v1.7 : LIVE UPDATES (in-app notifications + Supabase Realtime)
-- Run this whole file in Supabase Dashboard > SQL Editor LAST, after vendor_onboarding.sql. Safe to re-run (idempotent).
-- Full order: schema, seed, storage, orders, order_notes, pay, analytics, staff, photos, standard_analytics, platform_analytics,
--             advanced_analytics, admin_customers, tax_delivery, vendor_onboarding, realtime.
-- NOTE for Supabase: pg-safeupdate is on, so every UPDATE / DELETE here has a WHERE clause.
--
-- DESIGN
--   * notifications: one row per person per event. Written ONLY by SECURITY DEFINER trigger functions in this file.
--     Clients can SELECT their own rows (RLS user_id = auth.uid()) and mark them read through notif_mark_read / notif_mark_all_read.
--     No client INSERT / UPDATE / DELETE grants.
--   * Supabase Realtime: ONLY public.notifications is added to the supabase_realtime publication. Realtime checks RLS for every
--     postgres_changes event, so a person only ever receives their own rows. orders / order_notes / wallets are NOT published
--     (their rows hold phone numbers, addresses and balances); the browser re-reads the affected record through the normal,
--     RLS-protected queries when a notification arrives ("notification + targeted refetch").
--   * silent rows (silent = true) are not shown in the bell. They only tell an open page to refresh (e.g. another team member
--     moved an order, or your business wallet received an order payment that is already announced elsewhere).
--   * Additive only: new tables, new trigger functions, new triggers (all named *_rt_*). No earlier function is redefined.
--     Every trigger body catches its own errors (raise warning) so a notification problem can never block an order or payment.
--   * Retention: read notifications older than 90 days and silent rows older than 2 days are deleted by notifications_cleanup(),
--     called opportunistically (at most once an hour) from notif_list().
--   * Replica identity stays DEFAULT (primary key). That is enough for INSERT and UPDATE events; we do not use DELETE events.

-- =====================================================================================================
-- 1. Table
-- =====================================================================================================
create table if not exists public.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (char_length(kind) between 1 and 40),
  title      text not null check (char_length(title) between 1 and 160),
  body       text check (body is null or char_length(body) <= 300),
  link       text check (link is null or link ~ '^[a-z0-9-]+\.html([?#][A-Za-z0-9_=&.#%-]*)?$'),
  ref_type   text check (ref_type is null or ref_type in ('order','charge','wallet','vendor','tier_request','team','account')),
  ref_id     uuid,
  vendor_id  uuid,                 -- deliberately not a foreign key (a notification may outlive a deleted business)
  silent     boolean not null default false,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists notifications_user_idx on public.notifications(user_id, id desc);
create index if not exists notifications_unread_idx on public.notifications(user_id) where read_at is null and not silent;
create index if not exists notifications_read_at_idx on public.notifications(read_at) where read_at is not null;
create index if not exists notifications_silent_idx on public.notifications(created_at) where silent;
alter table public.notifications replica identity default;
alter table public.notifications enable row level security;
revoke all on public.notifications from public, anon, authenticated;
grant select on public.notifications to authenticated;
drop policy if exists notifications_own on public.notifications;
create policy notifications_own on public.notifications for select to authenticated using (user_id = auth.uid());

create table if not exists public.rt_maintenance (
  id       int primary key check (id = 1),
  last_run timestamptz not null default 'epoch'
);
insert into public.rt_maintenance(id) values (1) on conflict do nothing;
alter table public.rt_maintenance enable row level security;
revoke all on public.rt_maintenance from public, anon, authenticated;

-- =====================================================================================================
-- 2. Helpers (not callable by clients)
-- =====================================================================================================
create or replace function public._rt_money(p numeric) returns text
language sql immutable set search_path = public, pg_temp as $$ select 'EC$' || to_char(coalesce(p, 0), 'FM999,999,990.00') $$;

create or replace function public._rt_add(p_user uuid, p_kind text, p_title text, p_body text, p_link text,
  p_ref_type text, p_ref_id uuid, p_vendor uuid, p_silent boolean default false) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_user is null then return; end if;
  if auth.uid() is not null and p_user = auth.uid() then return; end if;   -- never notify people about their own actions
  insert into public.notifications(user_id, kind, title, body, link, ref_type, ref_id, vendor_id, silent)
  values (p_user, p_kind, left(coalesce(nullif(btrim(p_title), ''), 'Update'), 160), nullif(left(btrim(coalesce(p_body, '')), 300), ''),
          p_link, p_ref_type, p_ref_id, p_vendor, coalesce(p_silent, false));
end $$;

-- the people who work on a business and hold a permission (owner + active staff / sub-admins). See role_perms() in staff.sql.
create or replace function public._rt_team(p_vendor uuid, p_perm text) returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select v.owner_id from public.vendors v where v.id = p_vendor and v.owner_id is not null
  union
  select m.user_id from public.vendor_members m
   where m.vendor_id = p_vendor and m.status = 'active' and p_perm = any(public.role_perms(m.role));
$$;

create or replace function public._rt_admins() returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$ select p.id from public.profiles p where p.role = 'admin' $$;

create or replace function public._rt_status_label(p_status text, p_fulfilment text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case p_status
    when 'placed' then 'Placed'
    when 'confirmed' then 'Confirmed by the vendor'
    when 'ready' then case when p_fulfilment = 'delivery' then 'Packed and ready for delivery' else 'Ready for pickup' end
    when 'out_for_delivery' then 'Out for delivery'
    when 'completed' then case when p_fulfilment = 'delivery' then 'Delivered' else 'Collected' end
    when 'cancelled' then 'Cancelled'
    else p_status end;
$$;

revoke all on function public._rt_money(numeric), public._rt_add(uuid,text,text,text,text,text,uuid,uuid,boolean),
  public._rt_team(uuid,text), public._rt_admins(), public._rt_status_label(text,text) from public, anon, authenticated;

-- =====================================================================================================
-- 3. Trigger functions (all SECURITY DEFINER, all errors caught)
-- =====================================================================================================

-- 3a. new order -> owner + team with orders_view. DEFERRED to commit, so items, delivery fee and tax are final.
create or replace function public.trg_rt_order_new() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare o record; n int; u uuid;
begin
  select id, order_number, vendor_id, total_xcd, fulfilment into o from public.orders where id = new.id;
  if not found then return null; end if;
  select coalesce(sum(quantity), 0) into n from public.order_items where order_id = o.id;
  for u in select * from public._rt_team(o.vendor_id, 'orders_view') loop
    perform public._rt_add(u, 'order_new', 'New order ' || o.order_number,
      n || ' item' || case when n = 1 then '' else 's' end || ' · ' || public._rt_money(o.total_xcd) || ' · ' ||
      case when o.fulfilment = 'delivery' then 'Delivery' else 'Pickup' end,
      'dashboard-vendor.html?v=' || o.vendor_id || '#orders', 'order', o.id, o.vendor_id);
  end loop;
  return null;
exception when others then
  raise warning 'notifications (new order) skipped: %', sqlerrm; return null;
end $$;

-- 3b. order status / payment changes
create or replace function public.trg_rt_order_change() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid; vname text; vlink text; clink text; actor uuid := auth.uid();
begin
  select name into vname from public.vendors where id = new.vendor_id;
  vlink := 'dashboard-vendor.html?v=' || new.vendor_id || '#orders';
  clink := 'dashboard-consumer.html?order=' || new.id;
  if new.status is distinct from old.status then
    if actor is not null and actor = new.consumer_id then
      for u in select * from public._rt_team(new.vendor_id, 'orders_view') loop
        perform public._rt_add(u, 'order_cancelled', 'Order ' || new.order_number || ' was ' || lower(public._rt_status_label(new.status, new.fulfilment)) || ' by the customer',
          public._rt_money(new.total_xcd), vlink, 'order', new.id, new.vendor_id);
      end loop;
    else
      perform public._rt_add(new.consumer_id, 'order_status', 'Order ' || new.order_number || ': ' || public._rt_status_label(new.status, new.fulfilment),
        coalesce(vname, 'Vendor') || case when new.status = 'cancelled' and new.payment_status = 'paid' then ' · a refund to your test wallet follows' else '' end,
        clink, 'order', new.id, new.vendor_id);
      for u in select * from public._rt_team(new.vendor_id, 'orders_view') loop     -- keeps other team members' screens in sync
        perform public._rt_add(u, 'order_sync', 'Order ' || new.order_number || ' updated', null, vlink, 'order', new.id, new.vendor_id, true);
      end loop;
    end if;
  end if;
  if new.payment_status is distinct from old.payment_status then
    if new.payment_status = 'paid' then
      for u in select * from public._rt_team(new.vendor_id, 'orders_view') loop
        perform public._rt_add(u, 'order_paid', 'Order ' || new.order_number || ' paid (test wallet)', public._rt_money(new.total_xcd) || ' · play money',
          vlink, 'order', new.id, new.vendor_id);
      end loop;
    else
      for u in select * from public._rt_team(new.vendor_id, 'orders_view') loop
        perform public._rt_add(u, 'order_sync', 'Order ' || new.order_number || ' updated', null, vlink, 'order', new.id, new.vendor_id, true);
      end loop;
      perform public._rt_add(new.consumer_id, 'order_sync', 'Order ' || new.order_number || ' updated', null, clink, 'order', new.id, new.vendor_id, true);
    end if;
  end if;
  return null;
exception when others then
  raise warning 'notifications (order change) skipped: %', sqlerrm; return null;
end $$;

-- 3c. new order note -> the other party (and silent refresh for the rest of the vendor team)
create or replace function public.trg_rt_note_new() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare o record; u uuid; vname text; snip text := left(regexp_replace(new.body, '\s+', ' ', 'g'), 120);
begin
  select id, order_number, vendor_id, consumer_id into o from public.orders where id = new.order_id;
  if not found then return null; end if;
  select name into vname from public.vendors where id = o.vendor_id;
  if new.author_role = 'consumer' then
    for u in select * from public._rt_team(o.vendor_id, 'notes') loop
      perform public._rt_add(u, 'note_new', 'New note from the customer on ' || o.order_number, snip,
        'dashboard-vendor.html?v=' || o.vendor_id || '#orders', 'order', o.id, o.vendor_id);
    end loop;
  else
    perform public._rt_add(o.consumer_id, 'note_new', 'New note from ' || coalesce(vname, 'the vendor') || ' on ' || o.order_number, snip,
      'dashboard-consumer.html?order=' || o.id, 'order', o.id, o.vendor_id);
    for u in select * from public._rt_team(o.vendor_id, 'notes') loop
      perform public._rt_add(u, 'note_sync', 'Note on ' || o.order_number, null, 'dashboard-vendor.html?v=' || o.vendor_id || '#orders', 'order', o.id, o.vendor_id, true);
    end loop;
  end if;
  return null;
exception when others then
  raise warning 'notifications (order note) skipped: %', sqlerrm; return null;
end $$;

-- 3d. money received (TEST MODE play money): transfers, POS charges, refunds, adjustments; silent refresh for order payments
create or replace function public.trg_rt_tx_new() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare tw record; owner uuid; u uuid; pr record; onum text; vname text; amt numeric := new.amount_cents / 100.0;
begin
  select * into tw from public.wallets where id = new.to_wallet;
  if not found or tw.kind = 'system' then return null; end if;
  owner := case when tw.kind = 'user' then tw.owner_user_id else (select v.owner_id from public.vendors v where v.id = tw.vendor_id) end;
  if new.type = 'topup_test' then
    perform public._rt_add(owner, 'wallet_sync', 'Wallet updated', null, 'wallet.html', 'wallet', tw.id, tw.vendor_id, true);
  elsif new.type = 'transfer' and new.charge_id is not null then
    select id, code, vendor_id, created_by into pr from public.pay_requests where id = new.charge_id;
    for u in select owner union select pr.created_by loop
      perform public._rt_add(u, 'pos_paid', 'POS charge ' || coalesce(pr.code, '') || ' paid',
        public._rt_money(amt) || ' from ' || coalesce(public._pay_label(new.from_wallet), 'a customer') || ' · test money',
        'pos.html?v=' || coalesce(pr.vendor_id, tw.vendor_id), 'charge', new.charge_id, coalesce(pr.vendor_id, tw.vendor_id));
    end loop;
  elsif new.type = 'transfer' then
    perform public._rt_add(owner, 'wallet_received', 'You received ' || public._rt_money(amt) || case when tw.kind = 'vendor' then ' (business wallet)' else '' end,
      'From ' || coalesce(public._pay_label(new.from_wallet), 'a wallet') || coalesce(' · ' || new.note, '') || ' · test money',
      'wallet.html', 'wallet', tw.id, tw.vendor_id);
  elsif new.type = 'refund' then
    select o.order_number, v.name into onum, vname from public.orders o left join public.vendors v on v.id = o.vendor_id where o.id = new.order_id;
    perform public._rt_add(owner, 'refund', 'Refund of ' || public._rt_money(amt) || coalesce(' for ' || onum, ''),
      coalesce('From ' || vname || ' · ', '') || 'returned to your test wallet (play money)',
      case when new.order_id is not null then 'dashboard-consumer.html?order=' || new.order_id else 'wallet.html' end,
      case when new.order_id is not null then 'order' else 'wallet' end, coalesce(new.order_id, tw.id), null);
  elsif new.type = 'order_payment' then
    perform public._rt_add(owner, 'wallet_sync', 'Business wallet updated', null, 'wallet.html', 'wallet', tw.id, tw.vendor_id, true);
  else
    perform public._rt_add(owner, 'wallet_received', 'Wallet adjustment ' || public._rt_money(amt), coalesce(new.note, 'Test money'), 'wallet.html', 'wallet', tw.id, tw.vendor_id);
  end if;
  return null;
exception when others then
  raise warning 'notifications (wallet) skipped: %', sqlerrm; return null;
end $$;

-- 3e. vendor onboarding events (vendor_onboarding.sql writes them to notification_queue through _notify)
create or replace function public.trg_rt_queue() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid; nm text := coalesce(new.payload->>'name', 'your business'); rs text := new.payload->>'reason';
  tl text := (select t.label from public.tier_limits t where t.tier = new.payload->>'tier');
begin
  case new.kind
  when 'application_received', 'application_resubmitted' then
    for u in select * from public._rt_admins() loop
      perform public._rt_add(u, 'admin_application',
        case when new.kind = 'application_received' then 'New vendor application: ' else 'Application resubmitted: ' end || nm,
        'Waiting for review', 'admin.html#applications', 'vendor', new.vendor_id, new.vendor_id);
    end loop;
  when 'application_approved' then
    perform public._rt_add(new.user_id, 'application_decision', 'Your application for ' || nm || ' was approved',
      coalesce('Plan: ' || tl || '. ', '') || 'Add at least one active product to go live.', 'dashboard-vendor.html?v=' || new.vendor_id, 'vendor', new.vendor_id, new.vendor_id);
  when 'application_rejected' then
    perform public._rt_add(new.user_id, 'application_decision', 'Your application for ' || nm || ' was not approved',
      coalesce('Reason: ' || rs, null), 'apply.html', 'vendor', new.vendor_id, new.vendor_id);
  when 'application_changes_requested' then
    perform public._rt_add(new.user_id, 'application_decision', 'Changes requested for ' || nm,
      coalesce('Reason: ' || rs, null), 'apply.html', 'vendor', new.vendor_id, new.vendor_id);
  when 'vendor_suspended' then
    perform public._rt_add(new.user_id, 'vendor_status', nm || ' has been suspended',
      coalesce('Reason: ' || rs || '. ', '') || 'Shoppers cannot see it until it is reinstated.', 'dashboard-vendor.html?v=' || new.vendor_id, 'vendor', new.vendor_id, new.vendor_id);
  when 'vendor_reinstated', 'vendor_approved' then   -- admin_vendor_set_status writes 'vendor_approved' on reinstate
    perform public._rt_add(new.user_id, 'vendor_status', nm || ' has been reinstated', 'Shoppers can see it again.', 'dashboard-vendor.html?v=' || new.vendor_id, 'vendor', new.vendor_id, new.vendor_id);
  when 'owner_assigned', 'owner_transferred' then
    perform public._rt_add(new.user_id, 'vendor_owner', 'You are now the owner of ' || nm, null, 'dashboard-vendor.html?v=' || new.vendor_id, 'vendor', new.vendor_id, new.vendor_id);
  else null;
  end case;
  return null;
exception when others then
  raise warning 'notifications (onboarding) skipped: %', sqlerrm; return null;
end $$;

-- 3f. upgrade requests: new -> admins; decided -> requester + owner; cancelled -> admins (silent queue refresh)
create or replace function public.trg_rt_tier_request() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid; vname text; owner uuid; tl text;
begin
  select name, owner_id into vname, owner from public.vendors where id = new.vendor_id;
  select label into tl from public.tier_limits where tier = new.to_tier;
  if tg_op = 'INSERT' then
    for u in select * from public._rt_admins() loop
      perform public._rt_add(u, 'admin_upgrade_request', 'Upgrade request: ' || coalesce(vname, 'a business') || ' → ' || coalesce(tl, new.to_tier),
        'Waiting for review (test mode, no billing)', 'admin.html', 'tier_request', new.id, new.vendor_id);
    end loop;
  elsif new.status is distinct from old.status then
    if new.status in ('approved', 'declined') then
      for u in select owner union select new.requested_by loop
        perform public._rt_add(u, 'upgrade_decision', 'Your upgrade to ' || coalesce(tl, new.to_tier) || ' was ' || new.status,
          coalesce(vname, '') || ' · test mode, no billing', 'dashboard-vendor.html?v=' || new.vendor_id || '#team', 'tier_request', new.id, new.vendor_id);
      end loop;
    end if;
    for u in select * from public._rt_admins() loop
      perform public._rt_add(u, 'admin_queue_sync', 'Upgrade request updated', null, 'admin.html', 'tier_request', new.id, new.vendor_id, true);
    end loop;
  end if;
  return null;
exception when others then
  raise warning 'notifications (upgrade request) skipped: %', sqlerrm; return null;
end $$;

-- 3g. staff invite accepted -> whoever sent the invite + the owner
create or replace function public.trg_rt_invite_accepted() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid; vname text; owner uuid; who text;
begin
  if old.accepted_at is not null or new.accepted_at is null then return null; end if;
  select name, owner_id into vname, owner from public.vendors where id = new.vendor_id;
  select nullif(btrim(full_name), '') into who from public.profiles where id = new.accepted_by;
  for u in select owner union select new.created_by loop
    perform public._rt_add(u, 'staff_joined', coalesce(who, new.email) || ' joined ' || coalesce(vname, 'your business'),
      'Role: ' || case new.role when 'subadmin' then 'Sub-admin' else 'Staff' end, 'dashboard-vendor.html?v=' || new.vendor_id || '#team', 'team', new.vendor_id, new.vendor_id);
  end loop;
  return null;
exception when others then
  raise warning 'notifications (invite) skipped: %', sqlerrm; return null;
end $$;

-- 3h. platform admin actions on a person (admin_customers.sql audit rows). The reason stays admin-only.
create or replace function public.trg_rt_admin_action() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.target_user_id is null then return null; end if;
  case new.action
  when 'customer_suspended' then
    perform public._rt_add(new.target_user_id, 'account_suspended', 'Your account has been suspended',
      'You can still browse and see your orders. Please contact Carriacou Connect support.', 'account.html', 'account', new.target_user_id, null);
  when 'customer_reactivated' then
    perform public._rt_add(new.target_user_id, 'account_reactivated', 'Your account is active again', 'You can place orders and use your wallet.', 'account.html', 'account', new.target_user_id, null);
  when 'customer_edited' then
    perform public._rt_add(new.target_user_id, 'account_updated', 'Carriacou Connect updated your profile', 'Open your account to see the details.', 'account.html', 'account', new.target_user_id, null);
  when 'customer_role_changed' then
    perform public._rt_add(new.target_user_id, 'account_updated', 'Your account type is now ' || coalesce(new.details #>> '{after,role}', 'changed'), null, 'account.html', 'account', new.target_user_id, null);
  else null;
  end case;
  return null;
exception when others then
  raise warning 'notifications (admin action) skipped: %', sqlerrm; return null;
end $$;

revoke all on function public.trg_rt_order_new(), public.trg_rt_order_change(), public.trg_rt_note_new(), public.trg_rt_tx_new(),
  public.trg_rt_queue(), public.trg_rt_tier_request(), public.trg_rt_invite_accepted(), public.trg_rt_admin_action() from public, anon, authenticated;

-- =====================================================================================================
-- 4. Triggers (AFTER, additive; names start with trg_rt_ so they never replace earlier triggers)
-- =====================================================================================================
drop trigger if exists trg_rt_order_new on public.orders;
create constraint trigger trg_rt_order_new after insert on public.orders deferrable initially deferred
  for each row execute function public.trg_rt_order_new();
drop trigger if exists trg_rt_order_change on public.orders;
create trigger trg_rt_order_change after update of status, payment_status on public.orders
  for each row when (new.status is distinct from old.status or new.payment_status is distinct from old.payment_status)
  execute function public.trg_rt_order_change();
drop trigger if exists trg_rt_note_new on public.order_notes;
create trigger trg_rt_note_new after insert on public.order_notes for each row execute function public.trg_rt_note_new();
drop trigger if exists trg_rt_tx_new on public.transactions;
create trigger trg_rt_tx_new after insert on public.transactions for each row execute function public.trg_rt_tx_new();
drop trigger if exists trg_rt_queue on public.notification_queue;
create trigger trg_rt_queue after insert on public.notification_queue for each row execute function public.trg_rt_queue();
drop trigger if exists trg_rt_tier_request on public.tier_requests;
create trigger trg_rt_tier_request after insert or update of status on public.tier_requests for each row execute function public.trg_rt_tier_request();
drop trigger if exists trg_rt_invite_accepted on public.vendor_invites;
create trigger trg_rt_invite_accepted after update of accepted_at on public.vendor_invites for each row execute function public.trg_rt_invite_accepted();
drop trigger if exists trg_rt_admin_action on public.audit_log;
create trigger trg_rt_admin_action after insert on public.audit_log for each row
  when (new.action in ('customer_suspended','customer_reactivated','customer_edited','customer_role_changed'))
  execute function public.trg_rt_admin_action();

-- =====================================================================================================
-- 5. Client functions (own rows only)
-- =====================================================================================================
create or replace function public.notifications_cleanup() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare n1 int; n2 int;
begin
  delete from public.notifications where read_at is not null and created_at < now() - interval '90 days';
  get diagnostics n1 = row_count;
  delete from public.notifications where silent and created_at < now() - interval '2 days';
  get diagnostics n2 = row_count;
  update public.rt_maintenance set last_run = now() where id = 1;
  return n1 + n2;
end $$;

create or replace function public._rt_unread(p_user uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int from public.notifications where user_id = p_user and read_at is null and not silent $$;

create or replace function public._rt_json(n public.notifications) returns jsonb
language sql immutable set search_path = public, pg_temp as $$
  select jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'link', n.link, 'ref_type', n.ref_type,
    'ref_id', n.ref_id, 'vendor_id', n.vendor_id, 'silent', n.silent, 'created_at', n.created_at, 'read_at', n.read_at) $$;

-- latest visible notifications (newest first) + unread count. Also runs the cleanup at most once an hour.
create or replace function public.notif_list(p_limit int default 20, p_before bigint default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); lim int := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  if uid is null then raise exception 'Please log in'; end if;
  if (select last_run from public.rt_maintenance where id = 1) < now() - interval '1 hour' then
    begin perform public.notifications_cleanup(); exception when others then null; end;
  end if;
  return jsonb_build_object('unread', public._rt_unread(uid),
    'last_id', (select coalesce(max(id), 0) from public.notifications where user_id = uid),
    'items', coalesce((select jsonb_agg(public._rt_json(x) order by x.id desc) from (
       select * from public.notifications where user_id = uid and not silent and (p_before is null or id < p_before)
        order by id desc limit lim) x), '[]'::jsonb));
end $$;

-- everything newer than p_after (silent rows included): used to catch up after a reconnect and as the polling fallback
create or replace function public.notif_since(p_after bigint) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please log in'; end if;
  return jsonb_build_object('unread', public._rt_unread(uid),
    'items', coalesce((select jsonb_agg(public._rt_json(x) order by x.id) from (
       select * from public.notifications where user_id = uid and id > coalesce(p_after, 0) order by id limit 100) x), '[]'::jsonb));
end $$;

create or replace function public.notif_mark_read(p_ids bigint[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please log in'; end if;
  if coalesce(array_length(p_ids, 1), 0) > 200 then raise exception 'Too many notifications at once'; end if;
  update public.notifications set read_at = now() where user_id = uid and id = any(coalesce(p_ids, '{}')) and read_at is null;
  return jsonb_build_object('ok', true, 'unread', public._rt_unread(uid));
end $$;

create or replace function public.notif_mark_all_read() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please log in'; end if;
  update public.notifications set read_at = now() where user_id = uid and read_at is null;
  return jsonb_build_object('ok', true, 'unread', 0);
end $$;

revoke all on function public.notifications_cleanup(), public._rt_unread(uuid), public._rt_json(public.notifications) from public, anon, authenticated;
revoke all on function public.notif_list(int,bigint), public.notif_since(bigint), public.notif_mark_read(bigint[]), public.notif_mark_all_read() from public, anon;
grant execute on function public.notif_list(int,bigint), public.notif_since(bigint), public.notif_mark_read(bigint[]), public.notif_mark_all_read() to authenticated;

-- =====================================================================================================
-- 6. Supabase Realtime publication (idempotent). Only the notifications table is published.
-- =====================================================================================================
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime' and puballtables)
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

notify pgrst, 'reload schema';
