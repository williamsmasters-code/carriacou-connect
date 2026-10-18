-- Carriacou Connect v0.9 : subscription tiers (TEST MODE, no real billing) + staff accounts and permissions
-- Run this whole file once in Supabase Dashboard > SQL Editor, AFTER schema.sql, orders.sql, order_notes.sql,
-- pay.sql and analytics.sql (in that order). Safe to re-run. Do NOT re-run an older file after this one
-- (schema.sql / orders.sql / pay.sql / analytics.sql would put the owner-only rules back); if you do, just run staff.sql again.
--
-- Vocabulary (two different "admins" exist; do not mix them up):
--   * PLATFORM ADMIN = profiles.role = 'admin'. That is you, the operator. Sets tiers, approves upgrade requests.
--   * Business roles (per vendor):  admin = the business OWNER (vendors.owner_id)  >  subadmin  >  staff.
--
-- Business permission matrix (fixed in code, see role_perms()):
--   perm            staff  subadmin  admin(owner)
--   orders_view       x       x        x      see the business's orders
--   orders_update     x       x        x      accept / ready / complete / cancel orders (cancelling a WALLET-PAID order refunds it: needs 'refunds')
--   notes             x       x        x      write order notes to the customer
--   pos               x       x        x      create / cancel POS charges, see recent charges
--   products_view     x       x        x      see all products incl. hidden ones
--   products_edit             x        x      add / edit / delete products, stock, images
--   refunds                   x        x      refund wallet-paid orders
--   analytics                 x        x      analytics tab (tier-gated through tier_limits.features.analytics_basic)
--   team                               x      invite / change role / suspend / remove members, see audit log
--   plan                               x      request a plan upgrade
--   vendor_edit                        x      edit the business profile (existing vendors RLS, owner only)
--   (business wallet: move money, top up, send = OWNER ONLY, unchanged from v0.6)

-- =====================================================================================================
-- 1. Tiers
-- =====================================================================================================
create table if not exists public.tier_limits (
  tier          text primary key check (tier in ('lite','standard','plus','pro','enterprise')),
  rank          integer not null unique,
  label         text not null,
  max_staff     integer check (max_staff is null or max_staff >= 0),       -- null = unlimited
  max_subadmins integer check (max_subadmins is null or max_subadmins >= 0),
  max_products  integer check (max_products is null or max_products >= 0),
  features      jsonb not null default '{}'::jsonb
);
insert into public.tier_limits (tier, rank, label, max_staff, max_subadmins, max_products, features) values
  ('lite',       1, 'Lite',       0,    0,    10,   '{"analytics_basic":true,"analytics_business":false,"pos":"basic","multi_location":false,"dedicated_support":false,"campaigns":true}'),
  ('standard',   2, 'Standard',   2,    0,    25,   '{"analytics_basic":true,"analytics_business":false,"pos":"basic","multi_location":false,"dedicated_support":false,"campaigns":true}'),
  ('plus',       3, 'Plus+',      5,    0,    50,   '{"analytics_basic":true,"analytics_business":false,"pos":"enhanced","multi_location":false,"dedicated_support":false,"campaigns":true}'),
  ('pro',        4, 'Pro',        5,    2,    null, '{"analytics_basic":true,"analytics_business":true,"pos":"professional","multi_location":false,"dedicated_support":false,"campaigns":true}'),
  ('enterprise', 5, 'Enterprise', null, null, null, '{"analytics_basic":true,"analytics_business":true,"pos":"professional","multi_location":true,"dedicated_support":true,"campaigns":true}')
on conflict (tier) do update set rank = excluded.rank, label = excluded.label, max_staff = excluded.max_staff,
  max_subadmins = excluded.max_subadmins, max_products = excluded.max_products, features = excluded.features;

-- the product limit now comes from the table (same numbers as before). null = unlimited.
create or replace function public.tier_limit(t text) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select max_products from public.tier_limits where tier = t;
$$;
revoke all on function public.tier_limit(text) from public;
grant execute on function public.tier_limit(text) to anon, authenticated;

-- Platform-admin overrides for "variable" plans (Enterprise) or special deals. null = use the tier default.
create table if not exists public.vendor_plan_overrides (
  vendor_id     uuid primary key references public.vendors(id) on delete cascade,
  max_staff     integer check (max_staff is null or max_staff >= 0),
  max_subadmins integer check (max_subadmins is null or max_subadmins >= 0),
  updated_by    uuid,
  updated_at    timestamptz not null default now()
);

-- =====================================================================================================
-- 2. Members, invites, requests, audit log
-- =====================================================================================================
create table if not exists public.vendor_members (
  id         uuid primary key default gen_random_uuid(),
  vendor_id  uuid not null references public.vendors(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('staff','subadmin','admin')),
  status     text not null default 'active' check (status in ('active','suspended')),
  invited_by uuid,
  created_at timestamptz not null default now(),
  unique (vendor_id, user_id)
);
create unique index if not exists vendor_members_one_admin on public.vendor_members(vendor_id) where role = 'admin';
create index if not exists vendor_members_user_idx on public.vendor_members(user_id);

create table if not exists public.vendor_invites (
  id          uuid primary key default gen_random_uuid(),
  vendor_id   uuid not null references public.vendors(id) on delete cascade,
  email       text not null check (email = lower(email) and char_length(email) <= 254),
  role        text not null check (role in ('staff','subadmin')),
  code_hash   text not null unique,                -- sha256 of the invite code; the code itself is shown once and never stored
  created_by  uuid,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  accepted_by uuid,
  revoked_at  timestamptz
);
create index if not exists vendor_invites_vendor_idx on public.vendor_invites(vendor_id);
create unique index if not exists vendor_invites_one_pending on public.vendor_invites(vendor_id, email) where accepted_at is null and revoked_at is null;

create table if not exists public.invite_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  at timestamptz not null default now()
);
create index if not exists invite_attempts_idx on public.invite_attempts(user_id, at desc);

create table if not exists public.tier_requests (
  id            uuid primary key default gen_random_uuid(),
  vendor_id     uuid not null references public.vendors(id) on delete cascade,
  requested_by  uuid,
  from_tier     text not null,
  to_tier       text not null references public.tier_limits(tier),
  note          text check (note is null or char_length(note) <= 300),
  status        text not null default 'pending' check (status in ('pending','approved','declined','cancelled')),
  created_at    timestamptz not null default now(),
  decided_by    uuid,
  decided_at    timestamptz,
  decision_note text check (decision_note is null or char_length(decision_note) <= 300)
);
create unique index if not exists tier_requests_one_pending on public.tier_requests(vendor_id) where status = 'pending';
create index if not exists tier_requests_status_idx on public.tier_requests(status, created_at);

-- append-only: no client can write, and even the table owner cannot update or delete (trigger below)
create table if not exists public.audit_log (
  id             bigint generated always as identity primary key,
  at             timestamptz not null default now(),
  actor_id       uuid,
  vendor_id      uuid,                -- deliberately NOT a foreign key: the log outlives a deleted business
  action         text not null,
  target_user_id uuid,
  details        jsonb not null default '{}'::jsonb
);
create index if not exists audit_log_vendor_idx on public.audit_log(vendor_id, at desc);
create or replace function public.audit_log_immutable() returns trigger language plpgsql as $$
begin raise exception 'The audit log is append-only'; end $$;
drop trigger if exists trg_audit_log_immutable on public.audit_log;
create trigger trg_audit_log_immutable before update or delete on public.audit_log
  for each row execute function public.audit_log_immutable();
drop trigger if exists trg_audit_log_no_truncate on public.audit_log;
create trigger trg_audit_log_no_truncate before truncate on public.audit_log
  for each statement execute function public.audit_log_immutable();

create or replace function public._audit(p_vendor uuid, p_action text, p_target uuid, p_details jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.audit_log(actor_id, vendor_id, action, target_user_id, details)
  values (auth.uid(), p_vendor, p_action, p_target, coalesce(p_details, '{}'::jsonb));
end $$;
revoke all on function public._audit(uuid,text,uuid,jsonb) from public, anon, authenticated;

-- =====================================================================================================
-- 3. Roles, permissions, plan helpers
-- =====================================================================================================
create or replace function public.role_perms(p_role text) returns text[]
language sql immutable set search_path = public, pg_temp as $$
  select case p_role
    when 'staff'    then array['orders_view','orders_update','notes','pos','products_view']
    when 'subadmin' then array['orders_view','orders_update','notes','pos','products_view','products_edit','refunds','analytics']
    when 'admin'    then array['orders_view','orders_update','notes','pos','products_view','products_edit','refunds','analytics','team','plan','vendor_edit']
    else array[]::text[] end;
$$;

-- some permissions also need a plan feature (tier_limits.features key)
create or replace function public.perm_feature(p_perm text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case p_perm when 'analytics' then 'analytics_basic' else null end;
$$;

-- my business role for a vendor: 'admin' (owner), 'subadmin', 'staff' or null. Suspended members have no role.
create or replace function public.vendor_role(p_vendor uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case when v.owner_id = auth.uid() then 'admin'
              else (select m.role from public.vendor_members m
                     where m.vendor_id = v.id and m.user_id = auth.uid() and m.status = 'active' and m.role <> 'admin' limit 1) end
    from public.vendors v where v.id = p_vendor and auth.uid() is not null;
$$;

create or replace function public.vendor_perm(p_vendor uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select p_perm = any(public.role_perms(r.role)) from (select public.vendor_role(p_vendor) as role) r where r.role is not null)
    and (public.perm_feature(p_perm) is null
         or coalesce((select (t.features ->> public.perm_feature(p_perm))::boolean
                        from public.vendors v join public.tier_limits t on t.tier = v.tier where v.id = p_vendor), false)),
    false);
$$;
revoke all on function public.role_perms(text), public.perm_feature(text), public.vendor_role(uuid), public.vendor_perm(uuid,text) from public;
grant execute on function public.role_perms(text), public.perm_feature(text), public.vendor_role(uuid), public.vendor_perm(uuid,text) to anon, authenticated;

-- effective seat limit for a role (null = unlimited): platform override first, then the tier
create or replace function public._seat_limit(p_vendor uuid, p_role text) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select case p_role
    when 'staff'    then coalesce(o.max_staff, t.max_staff)
    when 'subadmin' then coalesce(o.max_subadmins, t.max_subadmins) end
    from public.vendors v join public.tier_limits t on t.tier = v.tier
    left join public.vendor_plan_overrides o on o.vendor_id = v.id
   where v.id = p_vendor;
$$;
create or replace function public._seat_used(p_vendor uuid, p_role text, p_pending boolean default false) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select (select count(*) from public.vendor_members m where m.vendor_id = p_vendor and m.role = p_role)::integer
       + case when p_pending then (select count(*) from public.vendor_invites i where i.vendor_id = p_vendor and i.role = p_role
                                     and i.accepted_at is null and i.revoked_at is null and i.expires_at > now())::integer else 0 end;
$$;
revoke all on function public._seat_limit(uuid,text), public._seat_used(uuid,text,boolean) from public, anon, authenticated;

-- ---- keep the owner as the vendor's 'admin' member ----
create or replace function public.vendors_sync_owner_member() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from public.vendor_members where vendor_id = new.id and role = 'admin' and user_id is distinct from new.owner_id;
  if new.owner_id is not null then
    delete from public.vendor_members where vendor_id = new.id and user_id = new.owner_id and role <> 'admin';
    insert into public.vendor_members(vendor_id, user_id, role, status) values (new.id, new.owner_id, 'admin', 'active')
    on conflict (vendor_id, user_id) do nothing;
  end if;
  return null;
end $$;
revoke all on function public.vendors_sync_owner_member() from public, anon, authenticated;
drop trigger if exists trg_vendors_owner_member on public.vendors;
create trigger trg_vendors_owner_member after insert or update of owner_id on public.vendors
  for each row execute function public.vendors_sync_owner_member();
-- existing businesses (from v0.8) get their owner row
insert into public.vendor_members(vendor_id, user_id, role, status)
  select id, owner_id, 'admin', 'active' from public.vendors where owner_id is not null
on conflict (vendor_id, user_id) do nothing;

-- ---- seat limits are enforced HERE, so no client or function can get around them ----
create or replace function public.vendor_members_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare lim integer; used integer; tl text;
begin
  if new.role = 'admin' then
    if new.user_id is distinct from (select owner_id from public.vendors where id = new.vendor_id) then
      raise exception 'Only the business owner can hold the admin role';
    end if;
    return new;
  end if;
  if tg_op = 'UPDATE' and old.role = 'admin' then raise exception 'The owner cannot be changed or demoted'; end if;
  if tg_op = 'UPDATE' and new.vendor_id is distinct from old.vendor_id then raise exception 'A member cannot move to another business'; end if;
  if new.user_id = (select owner_id from public.vendors where id = new.vendor_id) then
    raise exception 'The business owner is already the admin';
  end if;
  perform pg_advisory_xact_lock(hashtext('seats:' || new.vendor_id::text));
  lim := public._seat_limit(new.vendor_id, new.role);
  if lim is not null then
    select count(*) into used from public.vendor_members m
      where m.vendor_id = new.vendor_id and m.role = new.role and (tg_op = 'INSERT' or m.id <> new.id);
    if used >= lim then
      select label into tl from public.tier_limits t join public.vendors v on v.tier = t.tier where v.id = new.vendor_id;
      raise exception 'Seat limit reached: the % plan allows % % account(s)', tl, lim, case new.role when 'subadmin' then 'sub-admin' else 'staff' end
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.vendor_members_guard() from public, anon, authenticated;
drop trigger if exists trg_vendor_members_guard on public.vendor_members;
create trigger trg_vendor_members_guard before insert or update of role, vendor_id, user_id on public.vendor_members
  for each row execute function public.vendor_members_guard();

-- ---- tier changes: downgrades are BLOCKED while the business is over the new plan's limits ----
create or replace function public._tier_violations(p_vendor uuid, p_tier text) returns text[]
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t record; o record; msgs text[] := array[]::text[]; n integer; ms integer; ma integer;
begin
  select * into t from public.tier_limits where tier = p_tier;
  if not found then raise exception 'Unknown plan "%"', p_tier; end if;
  select * into o from public.vendor_plan_overrides where vendor_id = p_vendor;
  ms := coalesce(o.max_staff, t.max_staff); ma := coalesce(o.max_subadmins, t.max_subadmins);
  select count(*) into n from public.products where vendor_id = p_vendor;
  if t.max_products is not null and n > t.max_products then
    msgs := msgs || format('%s products (the %s plan allows %s): delete %s', n, t.label, t.max_products, n - t.max_products); end if;
  n := public._seat_used(p_vendor, 'staff');
  if ms is not null and n > ms then msgs := msgs || format('%s staff accounts (the %s plan allows %s): remove %s', n, t.label, ms, n - ms); end if;
  n := public._seat_used(p_vendor, 'subadmin');
  if ma is not null and n > ma then msgs := msgs || format('%s sub-admin accounts (the %s plan allows %s): remove %s', n, t.label, ma, n - ma); end if;
  return msgs;
end $$;
revoke all on function public._tier_violations(uuid,text) from public, anon, authenticated;

create or replace function public.vendors_tier_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text[];
begin
  if new.tier is distinct from old.tier then
    v := public._tier_violations(new.id, new.tier);
    if cardinality(v) > 0 then
      raise exception 'Cannot move % to the % plan yet. First fix: %', new.name, new.tier, array_to_string(v, '; ')
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.vendors_tier_guard() from public, anon, authenticated;
drop trigger if exists trg_vendors_tier_guard on public.vendors;
create trigger trg_vendors_tier_guard before update of tier on public.vendors
  for each row execute function public.vendors_tier_guard();

create or replace function public.vendors_tier_audit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.tier is distinct from old.tier then
    perform public._audit(new.id, 'tier_changed', null, jsonb_build_object('from', old.tier, 'to', new.tier));
  end if;
  return null;
end $$;
revoke all on function public.vendors_tier_audit() from public, anon, authenticated;
drop trigger if exists trg_vendors_tier_audit on public.vendors;
create trigger trg_vendors_tier_audit after update of tier on public.vendors
  for each row execute function public.vendors_tier_audit();

-- =====================================================================================================
-- 4. Row Level Security + grants for the new tables (clients can only READ; every change goes through a function)
-- =====================================================================================================
alter table public.tier_limits            enable row level security;
alter table public.vendor_plan_overrides  enable row level security;
alter table public.vendor_members         enable row level security;
alter table public.vendor_invites         enable row level security;
alter table public.invite_attempts        enable row level security;
alter table public.tier_requests          enable row level security;
alter table public.audit_log              enable row level security;

drop policy if exists tier_limits_select on public.tier_limits;
create policy tier_limits_select on public.tier_limits for select using (true);
drop policy if exists vendor_members_select on public.vendor_members;
create policy vendor_members_select on public.vendor_members for select
  using (user_id = auth.uid() or public.vendor_perm(vendor_id, 'team') or public.is_admin());
drop policy if exists tier_requests_select on public.tier_requests;
create policy tier_requests_select on public.tier_requests for select
  using (public.vendor_perm(vendor_id, 'plan') or public.is_admin());
drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log for select
  using (public.vendor_perm(vendor_id, 'team') or public.is_admin());
-- vendor_plan_overrides, vendor_invites, invite_attempts: no policy = no client access (functions only)

revoke all on public.tier_limits, public.vendor_plan_overrides, public.vendor_members, public.vendor_invites,
  public.invite_attempts, public.tier_requests, public.audit_log from public, anon, authenticated;
grant select on public.tier_limits to anon, authenticated;
grant select on public.vendor_members, public.tier_requests, public.audit_log to authenticated;

-- =====================================================================================================
-- 5. Public API (all SECURITY DEFINER with their own permission checks; authenticated only)
-- =====================================================================================================
-- who am I in each business? [{vendor_id, vendor_name, tier, tier_label, role, is_owner, status, perms[]}]
create or replace function public.my_vendor_access() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please log in'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'is_owner') desc, x->>'vendor_name', x->>'vendor_id') from (
    select jsonb_build_object('vendor_id', v.id, 'vendor_name', v.name, 'tier', v.tier, 'tier_label', t.label,
        'role', case when v.owner_id = uid then 'admin' else m.role end,
        'is_owner', v.owner_id = uid,
        'status', case when v.owner_id = uid then 'active' else m.status end,
        'perms', case when v.owner_id = uid or m.status = 'active'
                 then (select coalesce(jsonb_agg(p), '[]'::jsonb) from unnest(public.role_perms(case when v.owner_id = uid then 'admin' else m.role end)) p
                        where public.perm_feature(p) is null or coalesce((t.features ->> public.perm_feature(p))::boolean, false))
                 else '[]'::jsonb end) as x
    from public.vendors v join public.tier_limits t on t.tier = v.tier
    left join public.vendor_members m on m.vendor_id = v.id and m.user_id = uid and m.role <> 'admin'
   where v.owner_id = uid or m.id is not null) s), '[]'::jsonb);
end $$;

-- plan + seat usage for one business. Any member (or the platform admin) may look.
create or replace function public.vendor_plan(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v record; t record; o record; nxt record; req record;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if public.vendor_role(p_vendor) is null and not public.is_admin() then raise exception 'Business not found'; end if;
  select * into v from public.vendors where id = p_vendor;
  if not found then raise exception 'Business not found'; end if;
  select * into t from public.tier_limits where tier = v.tier;
  select * into o from public.vendor_plan_overrides where vendor_id = p_vendor;
  select * into nxt from public.tier_limits where rank = t.rank + 1;
  select * into req from public.tier_requests where vendor_id = p_vendor and status = 'pending';
  return jsonb_build_object('vendor_id', v.id, 'tier', v.tier, 'label', t.label, 'billing', 'test_mode',
    'features', t.features,
    'limits', jsonb_build_object('max_staff', coalesce(o.max_staff, t.max_staff), 'max_subadmins', coalesce(o.max_subadmins, t.max_subadmins), 'max_products', t.max_products),
    'overridden', o.vendor_id is not null,
    'usage', jsonb_build_object('staff', public._seat_used(p_vendor, 'staff'), 'subadmins', public._seat_used(p_vendor, 'subadmin'),
        'pending_staff', public._seat_used(p_vendor, 'staff', true) - public._seat_used(p_vendor, 'staff'),
        'pending_subadmins', public._seat_used(p_vendor, 'subadmin', true) - public._seat_used(p_vendor, 'subadmin'),
        'products', (select count(*) from public.products where vendor_id = p_vendor)),
    'next_tier', nxt.tier,
    'pending_request', case when req.id is null then null else jsonb_build_object('id', req.id, 'to_tier', req.to_tier, 'created_at', req.created_at, 'note', req.note) end);
end $$;

-- team page data (owner, or platform admin): members + pending invites
create or replace function public.team_list(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not (public.vendor_perm(p_vendor, 'team') or public.is_admin()) then raise exception 'Only the business owner can see the team'; end if;
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'user_id', m.user_id, 'role', m.role, 'status', m.status,
         'is_owner', m.role = 'admin', 'name', coalesce(nullif(btrim(p.full_name), ''), split_part(u.email, '@', 1)),
         'email', u.email, 'joined_at', m.created_at) order by (m.role = 'admin') desc, m.role, m.created_at)
       from public.vendor_members m join auth.users u on u.id = m.user_id left join public.profiles p on p.id = m.user_id
       where m.vendor_id = p_vendor), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role, 'created_at', i.created_at,
         'expires_at', i.expires_at, 'expired', i.expires_at <= now()) order by i.created_at desc)
       from public.vendor_invites i where i.vendor_id = p_vendor and i.accepted_at is null and i.revoked_at is null), '[]'::jsonb));
end $$;

create or replace function public.team_audit(p_vendor uuid, p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not (public.vendor_perm(p_vendor, 'team') or public.is_admin()) then raise exception 'Only the business owner can see the activity log'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'id')::bigint desc) from (
    select jsonb_build_object('id', a.id, 'at', a.at, 'action', a.action, 'details', a.details,
       'actor', coalesce(nullif(btrim(pa.full_name), ''), split_part(ua.email, '@', 1), 'System'),
       'target', coalesce(nullif(btrim(pt.full_name), ''), split_part(ut.email, '@', 1))) x
      from public.audit_log a left join auth.users ua on ua.id = a.actor_id left join public.profiles pa on pa.id = a.actor_id
      left join auth.users ut on ut.id = a.target_user_id left join public.profiles pt on pt.id = a.target_user_id
     where a.vendor_id = p_vendor order by a.id desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) s), '[]'::jsonb);
end $$;

-- ---- invites ----
-- The invite is bound to ONE email address, expires in 7 days and works once. The code is returned here only; the database keeps a hash.
create or replace function public.create_invite(p_vendor uuid, p_email text, p_role text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare em text := lower(btrim(coalesce(p_email, ''))); lim integer; used integer; raw text; code text; iid uuid; exp timestamptz; tl text;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not public.vendor_perm(p_vendor, 'team') then raise exception 'Only the business owner can invite people'; end if;
  if p_role not in ('staff','subadmin') then raise exception 'Choose a role: staff or sub-admin'; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(em) > 254 then raise exception 'Enter a valid email address'; end if;
  perform pg_advisory_xact_lock(hashtext('seats:' || p_vendor::text));
  if exists (select 1 from public.vendors v join auth.users u on u.id = v.owner_id where v.id = p_vendor and lower(u.email) = em) then
    raise exception 'That is your own email address'; end if;
  if exists (select 1 from public.vendor_members m join auth.users u on u.id = m.user_id where m.vendor_id = p_vendor and lower(u.email) = em) then
    raise exception 'That person is already on your team'; end if;
  if exists (select 1 from public.vendor_invites i where i.vendor_id = p_vendor and i.email = em and i.accepted_at is null and i.revoked_at is null) then
    raise exception 'There is already an open invite for that email. Revoke it first to send a new one.'; end if;
  if (select count(*) from public.vendor_invites i where i.vendor_id = p_vendor and i.accepted_at is null and i.revoked_at is null and i.expires_at > now()) >= 20 then
    raise exception 'Too many open invites (max 20). Revoke some first.'; end if;
  lim := public._seat_limit(p_vendor, p_role);
  used := public._seat_used(p_vendor, p_role, true);
  if lim is not null and used >= lim then
    select t.label into tl from public.tier_limits t join public.vendors v on v.tier = t.tier where v.id = p_vendor;
    raise exception 'Seat limit reached: the % plan allows % % account(s) (including open invites)', tl, lim, case p_role when 'subadmin' then 'sub-admin' else 'staff' end
      using errcode = 'check_violation';
  end if;
  raw := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12) || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));   -- 80 random bits
  code := 'CCI-' || substr(raw, 1, 5) || '-' || substr(raw, 6, 5) || '-' || substr(raw, 11, 5) || '-' || substr(raw, 16, 5);
  insert into public.vendor_invites(vendor_id, email, role, code_hash, created_by)
  values (p_vendor, em, p_role, encode(sha256(convert_to('CCI' || raw, 'utf8')), 'hex'), auth.uid())
  returning id, expires_at into iid, exp;
  perform public._audit(p_vendor, 'invite_created', null, jsonb_build_object('email', em, 'role', p_role));
  return jsonb_build_object('id', iid, 'code', code, 'email', em, 'role', p_role, 'expires_at', exp);
end $$;

create or replace function public.revoke_invite(p_invite uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare i record;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select * into i from public.vendor_invites where id = p_invite for update;
  if not found or not public.vendor_perm(i.vendor_id, 'team') then raise exception 'Invite not found'; end if;
  if i.accepted_at is not null then raise exception 'That invite was already accepted'; end if;
  if i.revoked_at is null then
    update public.vendor_invites set revoked_at = now() where id = i.id;
    perform public._audit(i.vendor_id, 'invite_revoked', null, jsonb_build_object('email', i.email, 'role', i.role));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- normalise what a person typed or pasted: 'cci-abcde-...' -> 'CCI' + 20 chars
create or replace function public._invite_norm(p_code text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
$$;
revoke all on function public._invite_norm(text) from public, anon, authenticated;

-- what is this invite for? Only works for the account whose email the invite was sent to.
create or replace function public.invite_preview(p_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); i record; em text; n text := public._invite_norm(p_code);
begin
  if uid is null then raise exception 'Please log in'; end if;
  if (select count(*) from public.invite_attempts where user_id = uid and at > now() - interval '10 minutes') >= 10 then
    raise exception 'Too many wrong invite codes. Please wait a few minutes.'; end if;
  select lower(btrim(email)) into em from auth.users where id = uid;
  select i2.*, v.name as vname into i from public.vendor_invites i2 join public.vendors v on v.id = i2.vendor_id
   where i2.code_hash = encode(sha256(convert_to(n, 'utf8')), 'hex');
  if not found or i.accepted_at is not null or i.revoked_at is not null or i.expires_at <= now() or i.email is distinct from em then
    insert into public.invite_attempts(user_id) values (uid);
    return jsonb_build_object('ok', false, 'error', 'invalid_invite');
  end if;
  return jsonb_build_object('ok', true, 'vendor_name', i.vname, 'role', i.role, 'expires_at', i.expires_at);
end $$;

create or replace function public.accept_invite(p_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); i record; em text; n text := public._invite_norm(p_code); mid uuid;
begin
  if uid is null then raise exception 'Please log in'; end if;
  if (select count(*) from public.invite_attempts where user_id = uid and at > now() - interval '10 minutes') >= 10 then
    raise exception 'Too many wrong invite codes. Please wait a few minutes.'; end if;
  select lower(btrim(email)) into em from auth.users where id = uid;
  select * into i from public.vendor_invites where code_hash = encode(sha256(convert_to(n, 'utf8')), 'hex') for update;
  if not found or i.accepted_at is not null or i.revoked_at is not null or i.expires_at <= now() or i.email is distinct from em then
    insert into public.invite_attempts(user_id) values (uid);
    return jsonb_build_object('ok', false, 'error', 'invalid_invite');
  end if;
  if exists (select 1 from public.vendors where owner_id = uid) then
    raise exception 'You already own a business account. Staff invites need a separate account (use a different email).'; end if;
  if exists (select 1 from public.vendor_members where vendor_id = i.vendor_id and user_id = uid) then
    raise exception 'You are already on this team'; end if;
  insert into public.vendor_members(vendor_id, user_id, role, status, invited_by) values (i.vendor_id, uid, i.role, 'active', i.created_by)
  returning id into mid;
  update public.vendor_invites set accepted_at = now(), accepted_by = uid where id = i.id;
  perform public._audit(i.vendor_id, 'member_joined', uid, jsonb_build_object('role', i.role, 'email', i.email));
  return jsonb_build_object('ok', true, 'vendor_id', i.vendor_id, 'vendor_name', (select name from public.vendors where id = i.vendor_id), 'role', i.role);
end $$;

-- ---- member management (owner only; the owner row can never be touched) ----
create or replace function public._member_for_owner(p_member uuid) returns public.vendor_members
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.vendor_members;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select * into m from public.vendor_members where id = p_member for update;
  if not found or not public.vendor_perm(m.vendor_id, 'team') then raise exception 'Team member not found'; end if;
  if m.role = 'admin' then raise exception 'The business owner cannot be changed or removed'; end if;
  return m;
end $$;
revoke all on function public._member_for_owner(uuid) from public, anon, authenticated;

create or replace function public.change_member_role(p_member uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.vendor_members;
begin
  if p_role not in ('staff','subadmin') then raise exception 'Choose a role: staff or sub-admin'; end if;
  m := public._member_for_owner(p_member);
  if m.role = p_role then return jsonb_build_object('ok', true, 'role', p_role); end if;
  update public.vendor_members set role = p_role where id = m.id;
  perform public._audit(m.vendor_id, 'role_changed', m.user_id, jsonb_build_object('from', m.role, 'to', p_role));
  return jsonb_build_object('ok', true, 'role', p_role);
end $$;

create or replace function public.set_member_status(p_member uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.vendor_members;
begin
  if p_status not in ('active','suspended') then raise exception 'Status must be active or suspended'; end if;
  m := public._member_for_owner(p_member);
  if m.status <> p_status then
    update public.vendor_members set status = p_status where id = m.id;
    perform public._audit(m.vendor_id, case p_status when 'suspended' then 'member_suspended' else 'member_reactivated' end, m.user_id, '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;

create or replace function public.remove_member(p_member uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.vendor_members;
begin
  m := public._member_for_owner(p_member);
  delete from public.vendor_members where id = m.id;
  perform public._audit(m.vendor_id, 'member_removed', m.user_id, jsonb_build_object('role', m.role));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.leave_team(p_vendor uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.vendor_members;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select * into m from public.vendor_members where vendor_id = p_vendor and user_id = auth.uid() for update;
  if not found then raise exception 'You are not on that team'; end if;
  if m.role = 'admin' then raise exception 'The business owner cannot leave the business'; end if;
  delete from public.vendor_members where id = m.id;
  perform public._audit(p_vendor, 'member_left', m.user_id, jsonb_build_object('role', m.role));
  return jsonb_build_object('ok', true);
end $$;

-- ---- plan changes (TEST MODE: no billing exists) ----
-- Vendors can only ASK. The platform admin approves, which changes the tier.
create or replace function public.request_upgrade(p_vendor uuid, p_tier text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare cur record; want record; rid uuid; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not public.vendor_perm(p_vendor, 'plan') then raise exception 'Only the business owner can request a plan change'; end if;
  select t.* into cur from public.vendors v join public.tier_limits t on t.tier = v.tier where v.id = p_vendor;
  select * into want from public.tier_limits where tier = p_tier;
  if not found then raise exception 'Unknown plan'; end if;
  if want.rank <= cur.rank then raise exception 'Choose a plan above your current % plan', cur.label; end if;
  if nt is not null and char_length(nt) > 300 then raise exception 'Note is too long (max 300 characters)'; end if;
  perform pg_advisory_xact_lock(hashtext('tierreq:' || p_vendor::text));
  if exists (select 1 from public.tier_requests where vendor_id = p_vendor and status = 'pending') then
    raise exception 'You already have a plan request waiting for approval. Cancel it first to change it.'; end if;
  insert into public.tier_requests(vendor_id, requested_by, from_tier, to_tier, note) values (p_vendor, auth.uid(), cur.tier, p_tier, nt) returning id into rid;
  perform public._audit(p_vendor, 'upgrade_requested', null, jsonb_build_object('from', cur.tier, 'to', p_tier));
  return jsonb_build_object('ok', true, 'id', rid, 'to_tier', p_tier, 'billing', 'test_mode');
end $$;

create or replace function public.cancel_upgrade_request(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select * into r from public.tier_requests where id = p_request for update;
  if not found or not public.vendor_perm(r.vendor_id, 'plan') then raise exception 'Request not found'; end if;
  if r.status <> 'pending' then raise exception 'That request is already %', r.status; end if;
  update public.tier_requests set status = 'cancelled', decided_by = auth.uid(), decided_at = now() where id = r.id;
  perform public._audit(r.vendor_id, 'upgrade_request_cancelled', null, jsonb_build_object('to', r.to_tier));
  return jsonb_build_object('ok', true);
end $$;

-- ---- platform admin only ----
create or replace function public._require_platform_admin() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not public.is_admin() then raise exception 'Platform admins only'; end if;
end $$;
revoke all on function public._require_platform_admin() from public, anon, authenticated;

create or replace function public.admin_list_vendors() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'tier', v.tier, 'is_sample', v.is_sample,
      'owner_email', u.email, 'location', v.location, 'created_at', v.created_at,
      'staff', public._seat_used(v.id, 'staff'), 'subadmins', public._seat_used(v.id, 'subadmin'),
      'products', (select count(*) from public.products p where p.vendor_id = v.id),
      'overridden', exists (select 1 from public.vendor_plan_overrides o where o.vendor_id = v.id),
      'pending_to_tier', (select r.to_tier from public.tier_requests r where r.vendor_id = v.id and r.status = 'pending'))
      order by v.created_at desc)
    from (select * from public.vendors order by created_at desc limit 500) v left join auth.users u on u.id = v.owner_id), '[]'::jsonb);
end $$;

create or replace function public.admin_list_requests(p_status text default 'pending') returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'vendor_id', r.vendor_id, 'vendor_name', v.name, 'current_tier', v.tier,
      'from_tier', r.from_tier, 'to_tier', r.to_tier, 'note', r.note, 'status', r.status, 'created_at', r.created_at,
      'decided_at', r.decided_at, 'decision_note', r.decision_note, 'owner_email', u.email) order by r.created_at desc)
    from (select * from public.tier_requests where p_status is null or status = p_status order by created_at desc limit 200) r
    join public.vendors v on v.id = r.vendor_id left join auth.users u on u.id = v.owner_id), '[]'::jsonb);
end $$;

-- internal: move a vendor to a tier (overrides are reset because they belonged to the old plan). Triggers block over-limit downgrades.
create or replace function public._apply_tier(p_vendor uuid, p_tier text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from public.tier_limits where tier = p_tier) then raise exception 'Unknown plan'; end if;
  perform 1 from public.vendors where id = p_vendor for update;
  if not found then raise exception 'Business not found'; end if;
  delete from public.vendor_plan_overrides where vendor_id = p_vendor and exists (select 1 from public.vendors where id = p_vendor and tier <> p_tier);
  update public.vendors set tier = p_tier where id = p_vendor and tier <> p_tier;
end $$;
revoke all on function public._apply_tier(uuid,text) from public, anon, authenticated;

create or replace function public.admin_set_tier(p_vendor uuid, p_tier text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare old text;
begin
  perform public._require_platform_admin();
  select tier into old from public.vendors where id = p_vendor;
  if old is null then raise exception 'Business not found'; end if;
  perform public._apply_tier(p_vendor, p_tier);
  if p_reason is not null and btrim(p_reason) <> '' then
    perform public._audit(p_vendor, 'tier_change_reason', null, jsonb_build_object('reason', left(btrim(p_reason), 300)));
  end if;
  return jsonb_build_object('ok', true, 'from', old, 'to', p_tier, 'billing', 'test_mode');
end $$;

create or replace function public.admin_decide_request(p_request uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; cur record; want record; dn text := nullif(left(btrim(coalesce(p_note, '')), 300), '');
begin
  perform public._require_platform_admin();
  select * into r from public.tier_requests where id = p_request for update;
  if not found then raise exception 'Request not found'; end if;
  if r.status <> 'pending' then raise exception 'That request is already %', r.status; end if;
  if p_approve then
    select t.* into cur from public.vendors v join public.tier_limits t on t.tier = v.tier where v.id = r.vendor_id;
    select * into want from public.tier_limits where tier = r.to_tier;
    if want.rank <= cur.rank then raise exception 'The business is already on the % plan or higher. Decline this request instead.', cur.label; end if;
    perform public._apply_tier(r.vendor_id, r.to_tier);
  end if;
  update public.tier_requests set status = case when p_approve then 'approved' else 'declined' end,
    decided_by = auth.uid(), decided_at = now(), decision_note = dn where id = r.id;
  perform public._audit(r.vendor_id, case when p_approve then 'upgrade_approved' else 'upgrade_declined' end, null,
    jsonb_build_object('to', r.to_tier));
  return jsonb_build_object('ok', true, 'status', case when p_approve then 'approved' else 'declined' end);
end $$;

-- custom seat counts for "variable" plans. null = tier default. Cannot go below what the business already uses.
create or replace function public.admin_set_plan_override(p_vendor uuid, p_max_staff integer, p_max_subadmins integer) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare used_s integer; used_a integer;
begin
  perform public._require_platform_admin();
  if not exists (select 1 from public.vendors where id = p_vendor) then raise exception 'Business not found'; end if;
  if p_max_staff is not null and (p_max_staff < 0 or p_max_staff > 500) then raise exception 'Staff seats must be between 0 and 500'; end if;
  if p_max_subadmins is not null and (p_max_subadmins < 0 or p_max_subadmins > 100) then raise exception 'Sub-admin seats must be between 0 and 100'; end if;
  perform pg_advisory_xact_lock(hashtext('seats:' || p_vendor::text));
  used_s := public._seat_used(p_vendor, 'staff'); used_a := public._seat_used(p_vendor, 'subadmin');
  if p_max_staff is not null and used_s > p_max_staff then raise exception 'The business already has % staff accounts; remove some first', used_s; end if;
  if p_max_subadmins is not null and used_a > p_max_subadmins then raise exception 'The business already has % sub-admin accounts; remove some first', used_a; end if;
  if p_max_staff is null and p_max_subadmins is null then
    delete from public.vendor_plan_overrides where vendor_id = p_vendor;
  else
    insert into public.vendor_plan_overrides(vendor_id, max_staff, max_subadmins, updated_by) values (p_vendor, p_max_staff, p_max_subadmins, auth.uid())
    on conflict (vendor_id) do update set max_staff = excluded.max_staff, max_subadmins = excluded.max_subadmins, updated_by = excluded.updated_by, updated_at = now();
  end if;
  perform public._audit(p_vendor, 'plan_override_set', null, jsonb_build_object('max_staff', p_max_staff, 'max_subadmins', p_max_subadmins));
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.my_vendor_access(), public.vendor_plan(uuid), public.team_list(uuid), public.team_audit(uuid,integer),
  public.create_invite(uuid,text,text), public.revoke_invite(uuid), public.invite_preview(text), public.accept_invite(text),
  public.change_member_role(uuid,text), public.set_member_status(uuid,text), public.remove_member(uuid), public.leave_team(uuid),
  public.request_upgrade(uuid,text,text), public.cancel_upgrade_request(uuid),
  public.admin_list_vendors(), public.admin_list_requests(text), public.admin_set_tier(uuid,text,text),
  public.admin_decide_request(uuid,boolean,text), public.admin_set_plan_override(uuid,integer,integer) from public, anon;
grant execute on function public.my_vendor_access(), public.vendor_plan(uuid), public.team_list(uuid), public.team_audit(uuid,integer),
  public.create_invite(uuid,text,text), public.revoke_invite(uuid), public.invite_preview(text), public.accept_invite(text),
  public.change_member_role(uuid,text), public.set_member_status(uuid,text), public.remove_member(uuid), public.leave_team(uuid),
  public.request_upgrade(uuid,text,text), public.cancel_upgrade_request(uuid),
  public.admin_list_vendors(), public.admin_list_requests(text), public.admin_set_tier(uuid,text,text),
  public.admin_decide_request(uuid,boolean,text), public.admin_set_plan_override(uuid,integer,integer) to authenticated;

-- =====================================================================================================
-- 6. Members act for a business according to their role. Everything below REPLACES the owner-only rules
--    from schema.sql / orders.sql / order_notes.sql / pay.sql / analytics.sql. The owner keeps full access.
-- =====================================================================================================

-- ---- products ----
drop policy if exists products_select on public.products;
create policy products_select on public.products for select
  using (active or public.is_admin() or public.vendor_perm(vendor_id, 'products_view'));
drop policy if exists products_insert on public.products;
create policy products_insert on public.products for insert
  with check (public.is_admin() or public.vendor_perm(vendor_id, 'products_edit'));
drop policy if exists products_update on public.products;
create policy products_update on public.products for update
  using (public.is_admin() or public.vendor_perm(vendor_id, 'products_edit'))
  with check (public.is_admin() or public.vendor_perm(vendor_id, 'products_edit'));
drop policy if exists products_delete on public.products;
create policy products_delete on public.products for delete
  using (public.is_admin() or public.vendor_perm(vendor_id, 'products_edit'));

-- ---- orders (read for everyone on the team; status changes need orders_update) ----
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select
  using (consumer_id = auth.uid() or public.is_admin() or public.vendor_perm(vendor_id, 'orders_view'));
drop policy if exists orders_update on public.orders;
create policy orders_update on public.orders for update
  using (consumer_id = auth.uid() or public.is_admin() or public.vendor_perm(vendor_id, 'orders_update'))
  with check (consumer_id = auth.uid() or public.is_admin() or public.vendor_perm(vendor_id, 'orders_update'));
drop policy if exists order_items_select on public.order_items;
create policy order_items_select on public.order_items for select
  using (exists (select 1 from public.orders o where o.id = order_id
         and (o.consumer_id = auth.uid() or public.is_admin() or public.vendor_perm(o.vendor_id, 'orders_view'))));
drop policy if exists order_history_select on public.order_status_history;
create policy order_history_select on public.order_status_history for select
  using (exists (select 1 from public.orders o where o.id = order_id
         and (o.consumer_id = auth.uid() or public.is_admin() or public.vendor_perm(o.vendor_id, 'orders_view'))));

-- order guard: same as pay.sql, but "is the vendor" now means "may update this business's orders", and
-- cancelling a WALLET-PAID order (which refunds the customer) also needs the 'refunds' permission.
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
      is_vendor := public.vendor_perm(old.vendor_id, 'orders_update');
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
        if ok and not is_cons and new.status = 'cancelled' and old.payment_status = 'paid' and not public.vendor_perm(old.vendor_id, 'refunds') then
          raise exception 'Only the owner or a sub-admin can cancel an order that was paid from a wallet (it refunds the customer)';
        end if;
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

-- ---- order notes: the customer, or anyone on the business's team (vendor side) ----
create or replace function public.is_order_party(p_order uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.orders o
    where o.id = p_order
      and (o.consumer_id = auth.uid() or public.vendor_perm(o.vendor_id, 'notes')));
$$;
revoke all on function public.is_order_party(uuid) from public, anon;
grant execute on function public.is_order_party(uuid) to authenticated;
drop policy if exists order_notes_insert on public.order_notes;
create policy order_notes_insert on public.order_notes for insert
  with check (
    author_id = auth.uid()
    and exists (select 1 from public.orders o
      where o.id = order_id
        and ((author_role = 'consumer' and o.consumer_id = auth.uid())
          or (author_role = 'vendor' and public.vendor_perm(o.vendor_id, 'notes')))));


-- ---- business wallet: owner can use it (unchanged); sub-admins can only LOOK (balance + ledger, for analytics/refund checks) ----
create or replace function public.can_view_wallet(p_wallet uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and exists (
    select 1 from public.wallets w
    where w.id = p_wallet and w.kind <> 'system'
      and (public.can_access_wallet(w.id) or (w.vendor_id is not null and public.vendor_perm(w.vendor_id, 'analytics'))));
$$;
revoke all on function public.can_view_wallet(uuid) from public, anon;
grant execute on function public.can_view_wallet(uuid) to authenticated;
drop policy if exists wallets_select on public.wallets;
create policy wallets_select on public.wallets for select
  using (public.can_view_wallet(id) or public.is_admin());
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions for select
  using (public.can_view_wallet(from_wallet) or public.can_view_wallet(to_wallet) or public.is_admin());
-- ---- POS charges ----
drop policy if exists pay_requests_select on public.pay_requests;
create policy pay_requests_select on public.pay_requests for select
  using (public.vendor_perm(vendor_id, 'pos') or public.is_admin());
-- ---- refunds: owner or sub-admin ----
create or replace function public.refund_order(p_order_id uuid, p_idempotency_key text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please log in'; end if;
  if not exists (select 1 from public.orders o where o.id = p_order_id and public.vendor_perm(o.vendor_id, 'refunds')) then
    raise exception 'Order not found'; end if;
  return public._pay_refund_internal(p_order_id, uid);
end $$;
-- ---- POS: any team member ----
create or replace function public.create_charge(p_amount_cents bigint, p_note text default null, p_items jsonb default '[]'::jsonb, p_vendor_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); v uuid; w uuid; cid uuid; cd text; n int := 0; exp timestamptz; nt text := nullif(btrim(coalesce(p_note,'')),'');
  it jsonb := coalesce(p_items, '[]'::jsonb);
begin
  if uid is null then raise exception 'Please log in'; end if;
  select id into v from public.vendors where public.vendor_perm(id, 'pos') and (p_vendor_id is null or id = p_vendor_id) order by (owner_id = uid) desc, created_at limit 1;
  if v is null then raise exception 'Only a business you work for can create charges'; end if;
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
  select pr.* into c from public.pay_requests pr
    where pr.id = p_charge_id and public.vendor_perm(pr.vendor_id, 'pos') for update of pr;
  if not found then raise exception 'Charge not found'; end if;
  if c.status = 'paid' then raise exception 'This charge was already paid'; end if;
  update public.pay_requests set status = 'cancelled' where id = c.id;
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

-- ---- analytics: owner and sub-admins (plan feature analytics_basic is on for every tier) ----
create or replace function public.vendor_sales_summary(p_from date, p_to date) returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; res jsonb;
begin
  perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada';
  t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with mine as (
    select o.id, o.status, o.payment_status, o.total_xcd, (o.created_at at time zone 'America/Grenada')::date as d
      from public.orders o join public.vendors v on v.id = o.vendor_id
     where public.vendor_perm(v.id, 'analytics') and o.created_at >= t0 and o.created_at < t1),
  grp as (
    select m.*, case when m.payment_status = 'refunded' then 'refunded'
                     when m.status = 'cancelled' then 'cancelled' else 'sales' end as g from mine m),
  daily as (
    select gs::date as day, count(g.id) filter (where g.g = 'sales') as orders,
           coalesce(sum(g.total_xcd) filter (where g.g = 'sales'), 0) as rev
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') gs left join grp g on g.d = gs::date group by gs)
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', 'America/Grenada',
    'orders', (select count(*) from grp where g = 'sales'),
    'revenue_xcd', (select coalesce(sum(total_xcd), 0) from grp where g = 'sales'),
    'avg_order_xcd', (select coalesce(round(sum(total_xcd) / nullif(count(*), 0), 2), 0) from grp where g = 'sales'),
    'items_sold', (select coalesce(sum(oi.quantity), 0) from public.order_items oi join grp on grp.id = oi.order_id where grp.g = 'sales'),
    'open_orders', (select count(*) from grp where g = 'sales' and status <> 'completed'),
    'refunded_orders', (select count(*) from grp where g = 'refunded'),
    'refunded_xcd', (select coalesce(sum(total_xcd), 0) from grp where g = 'refunded'),
    'cancelled_orders', (select count(*) from grp where g = 'cancelled'),
    'cancelled_xcd', (select coalesce(sum(total_xcd), 0) from grp where g = 'cancelled'),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', day, 'orders', orders, 'revenue_xcd', rev) order by day), '[]'::jsonb) from daily))
  into res;
  return res;
end $$;

create or replace function public.vendor_top_products(p_from date, p_to date, p_limit integer default 5) returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; lim integer := least(greatest(coalesce(p_limit, 5), 1), 50); res jsonb;
begin
  perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada';
  t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with sold as (
    select oi.product_id, max(oi.product_name) as name, sum(oi.quantity)::integer as qty,
           sum(coalesce(oi.line_total_xcd, oi.unit_price_xcd * oi.quantity)) as rev
      from public.orders o join public.vendors v on v.id = o.vendor_id join public.order_items oi on oi.order_id = o.id
     where public.vendor_perm(v.id, 'analytics') and o.created_at >= t0 and o.created_at < t1
       and o.status <> 'cancelled' and o.payment_status <> 'refunded'
     group by coalesce(oi.product_id::text, 'n:' || oi.product_name), oi.product_id),
  best as (select * from sold order by qty desc, rev desc, name, product_id limit lim),
  worst as (
    select p.id as product_id, p.name, coalesce(s.qty, 0) as qty, coalesce(s.rev, 0) as rev
      from public.products p join public.vendors v on v.id = p.vendor_id left join sold s on s.product_id = p.id
     where public.vendor_perm(v.id, 'analytics') and p.active
     order by coalesce(s.qty, 0) asc, coalesce(s.rev, 0) asc, p.name, p.id limit lim)
  select jsonb_build_object(
    'best',  (select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'name', name, 'qty', qty, 'revenue_xcd', rev) order by qty desc, rev desc, name, product_id), '[]'::jsonb) from best),
    'worst', (select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'name', name, 'qty', qty, 'revenue_xcd', rev) order by qty asc, rev asc, name, product_id), '[]'::jsonb) from worst))
  into res;
  return res;
end $$;

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
  m(method) as (values ('pay_on_pickup'), ('pay_on_delivery'), ('pay_with_wallet'))
  select jsonb_build_object(
    'methods', (select jsonb_agg(jsonb_build_object('method', m.method,
                  'orders', (select count(*) from mine x where x.payment_method = m.method and x.status <> 'cancelled' and x.payment_status <> 'refunded'),
                  'revenue_xcd', (select coalesce(sum(x.total_xcd), 0) from mine x where x.payment_method = m.method and x.status <> 'cancelled' and x.payment_status <> 'refunded'))
                  order by m.method) from m),
    'refunds', jsonb_build_object(
       'orders', (select count(*) from mine where payment_status = 'refunded'),
       'amount_xcd', (select coalesce(sum(total_xcd), 0) from mine where payment_status = 'refunded')))
  into res;
  return res;
end $$;

create or replace function public.vendor_low_stock() returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'stock_qty', p.stock_qty,
            'low_stock_threshold', coalesce(p.low_stock_threshold, 5)) order by p.stock_qty, p.name, p.id)
     from public.products p join public.vendors v on v.id = p.vendor_id
    where public.vendor_perm(v.id, 'analytics') and p.active and p.stock_qty is not null
      and p.stock_qty <= coalesce(p.low_stock_threshold, 5)), '[]'::jsonb);
end $$;

create or replace function public.vendor_wallet_overview() returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare w record;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select min(w2.code) as code, sum(w2.balance_cents)::bigint as bal, count(*) as n into w
    from public.wallets w2 join public.vendors v on v.id = w2.vendor_id
   where w2.kind = 'vendor' and public.vendor_perm(v.id, 'analytics');
  return jsonb_build_object('test_mode', true,
    'has_wallet', w.n > 0, 'wallet_code', w.code, 'balance_cents', w.bal,
    -- customer will pay the vendor directly (cash) and the order is not finished yet
    'awaiting_cash_xcd', (select coalesce(sum(o.total_xcd), 0) from public.orders o join public.vendors v on v.id = o.vendor_id
        where public.vendor_perm(v.id, 'analytics') and o.status not in ('completed','cancelled') and o.payment_status = 'unpaid'),
    -- already paid from a test wallet, order still open (could still be cancelled and refunded)
    'open_wallet_paid_xcd', (select coalesce(sum(o.total_xcd), 0) from public.orders o join public.vendors v on v.id = o.vendor_id
        where public.vendor_perm(v.id, 'analytics') and o.status not in ('completed','cancelled') and o.payment_status = 'paid'));
end $$;

create or replace function public.vendor_transactions(p_from date, p_to date, p_limit integer default 1000) returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare t0 timestamptz; t1 timestamptz; lim integer := least(greatest(coalesce(p_limit, 1000), 1), 5000); rows jsonb; n integer;
begin
  perform public._an_check(p_from, p_to);
  t0 := p_from::timestamp at time zone 'America/Grenada';
  t1 := (p_to + 1)::timestamp at time zone 'America/Grenada';
  with u as (
    select o.created_at as at, 'order'::text as kind, o.order_number as ref, o.payment_method as method, o.status as status,
           o.payment_status as payment_status, o.total_xcd as amount_xcd, coalesce(o.contact_name, '') as note
      from public.orders o join public.vendors v on v.id = o.vendor_id
     where public.vendor_perm(v.id, 'analytics') and o.created_at >= t0 and o.created_at < t1
    union all
    select t.created_at, 'wallet', coalesce(o.order_number, ''), t.type,
           case when t.to_wallet = w.id then 'in' else 'out' end, 'completed',
           case when t.to_wallet = w.id then 1 else -1 end * t.amount_cents / 100.0, coalesce(t.note, '')
      from public.wallets w join public.vendors v on v.id = w.vendor_id
      join public.transactions t on t.to_wallet = w.id or t.from_wallet = w.id
      left join public.orders o on o.id = t.order_id
     where w.kind = 'vendor' and public.vendor_perm(v.id, 'analytics') and t.created_at >= t0 and t.created_at < t1),
  lim_rows as (select * from u order by at desc, kind, ref limit lim + 1)
  select (select count(*) from lim_rows)::integer, coalesce(jsonb_agg(jsonb_build_object('at', at, 'kind', kind, 'ref', ref, 'method', method, 'status', status,
         'payment_status', payment_status, 'amount_xcd', amount_xcd, 'note', note,
         'day', (at at time zone 'America/Grenada')::date) order by at desc, kind, ref), '[]'::jsonb)
    into n, rows from (select * from lim_rows order by at desc, kind, ref limit lim) x;
  return jsonb_build_object('rows', rows, 'truncated', n > lim, 'limit', lim);
end $$;

revoke all on function public.vendor_sales_summary(date,date), public.vendor_top_products(date,date,integer),
  public.vendor_payment_breakdown(date,date), public.vendor_low_stock(), public.vendor_wallet_overview(),
  public.vendor_transactions(date,date,integer), public.refund_order(uuid,text), public.create_charge(bigint,text,jsonb,uuid),
  public.cancel_charge(uuid) from public, anon;
grant execute on function public.vendor_sales_summary(date,date), public.vendor_top_products(date,date,integer),
  public.vendor_payment_breakdown(date,date), public.vendor_low_stock(), public.vendor_wallet_overview(),
  public.vendor_transactions(date,date,integer), public.refund_order(uuid,text), public.create_charge(bigint,text,jsonb,uuid),
  public.cancel_charge(uuid) to authenticated;

notify pgrst, 'reload schema';
