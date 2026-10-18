-- Carriacou Connect v1.6 : REAL VENDOR ONBOARDING (applications, approval lifecycle, ownership). TEST MODE: no money is moved by anything here.
-- Run this whole file in Supabase SQL Editor AFTER: schema -> seed -> storage -> orders -> order_notes -> pay -> analytics -> staff -> photos
--   -> standard_analytics -> platform_analytics -> advanced_analytics -> admin_customers -> tax_delivery.   Safe to re-run (idempotent).
-- It redefines ONE earlier function (public_featured_campaigns, so a hidden business cannot show a featured campaign). Everything else is additive:
--   new tables, new columns, new functions, new TRIGGERS (orders / pay_requests / vendors) and RESTRICTIVE row-level-security policies
--   (they are AND-ed with the existing policies, so re-running schema.sql / staff.sql does not undo them).
--   If you ever re-run standard_analytics.sql, re-run this file last (it puts public_featured_campaigns back).
-- Supabase uses pg-safeupdate: every UPDATE / DELETE below has a WHERE.
--
-- WHAT IT ADDS
--   * vendors.status: pending | changes_requested | approved | suspended | rejected (+ status_reason, status_changed_at/by, logo_url).
--     EVERY business that exists when you first run this file becomes 'approved' (grandfathered: real vendors AND the SAMPLE vendors).
--     After that, any business created from the website starts as 'pending' (forced by a trigger, whatever the browser sends).
--     Businesses created from the SQL editor (no logged-in user) keep the column default 'approved'.
--   * vendor_applications: the application form answers (contact phone, WhatsApp, VAT number, registration number...). RLS on, NO grants:
--     only the functions below read it. The public never sees it; the applicant sees their own; platform admins see everything.
--   * vendor_private: payment information a business writes for the platform (RLS on, no grants).
--   * notification_queue: "notification-ready hook". Rows are written when something happens (applied, approved...). NOTHING sends them (no SMTP yet).
--   * platform_settings.hide_samples: admin switch to hide the SAMPLE vendors (default false = visible).
--   * Visibility is enforced in the DATABASE: RESTRICTIVE select policies on vendors and products. The public sees a business only when it is
--     approved, has at least one ACTIVE product (the "go live" rule) and is not a hidden SAMPLE. Owners, team members, platform admins and
--     customers who already ordered from a business still see it (so order history keeps its names).
--   * Orders: a BEFORE INSERT trigger refuses new orders for a business that is not approved (or is a hidden SAMPLE): error 'VENDOR_UNAVAILABLE'.
--     Same for new POS charges and for paying an open charge. A suspended business can still see, update and refund its EXISTING orders.
--   * Applicant functions: submit_vendor_application, update_vendor_application, my_applications.
--   * Admin functions (platform admin only, REVOKEd from public and anon): admin_app_list, admin_app_get, admin_app_decide, admin_vendor_set_status,
--     admin_assign_owner, admin_set_hide_samples, admin_onboarding_overview.
--   * Business functions: vendor_onboarding_status (checklist), set_vendor_payment_info, get_vendor_payment_info, transfer_vendor_ownership.
--   * Every action writes audit_log (actions start with 'onb_').
--
-- RULES
--   * Admin accounts cannot apply. A suspended person cannot apply (ACCOUNT_SUSPENDED). A person may own at most 5 businesses and have 1 open application.
--   * A business always has an owner once it has one: owner_id can never be set to NULL on a real business (trigger).
--   * Applicants edit name / description / area while pending, changes_requested or rejected; saving moves it back to 'pending'.
--   * Ownership transfer: the owner picks an ACTIVE staff / sub-admin member and types the business name. The old owner becomes a sub-admin when the plan
--     has a free sub-admin seat, otherwise they lose access (shown in the answer). Admins can reassign with a reason.

-- =====================================================================================================
-- 1. Columns, tables
-- =====================================================================================================
alter table public.vendors add column if not exists status text not null default 'approved';      -- existing rows become 'approved' (grandfathered)
alter table public.vendors add column if not exists status_reason text;
alter table public.vendors add column if not exists status_changed_at timestamptz;
alter table public.vendors add column if not exists status_changed_by uuid;
alter table public.vendors add column if not exists logo_url text;
alter table public.vendors drop constraint if exists vendors_status_chk;
alter table public.vendors add constraint vendors_status_chk check (status in ('pending','changes_requested','approved','suspended','rejected'));
alter table public.vendors drop constraint if exists vendors_reason_len;
alter table public.vendors add constraint vendors_reason_len check (status_reason is null or char_length(status_reason) <= 300);
alter table public.vendors drop constraint if exists vendors_logo_len;
alter table public.vendors add constraint vendors_logo_len check (logo_url is null or char_length(logo_url) <= 500);
create index if not exists vendors_status_idx on public.vendors(status);

alter table public.platform_settings add column if not exists hide_samples boolean not null default false;

create table if not exists public.vendor_applications (
  vendor_id           uuid primary key references public.vendors(id) on delete cascade,
  applicant_id        uuid references auth.users(id) on delete set null,
  business_type       text not null check (business_type in ('sole_trader','company','cooperative','nonprofit','other')),
  island              text not null check (island in ('Carriacou','Petite Martinique','Grenada')),
  area                text not null check (char_length(area) between 2 and 60),
  category            text not null check (category in ('food','crafts','fashion','beauty','sea','home')),
  contact_phone       text not null check (char_length(contact_phone) between 7 and 30),
  whatsapp            text check (whatsapp is null or char_length(whatsapp) between 7 and 30),
  vat_registered      boolean not null default false,
  vat_number          text check (vat_number is null or char_length(vat_number) <= 40),
  registration_number text check (registration_number is null or char_length(registration_number) <= 60),
  offers_pickup       boolean not null default true,
  offers_delivery     boolean not null default false,
  requested_tier      text not null default 'lite' references public.tier_limits(tier),
  terms_version       text not null,
  terms_accepted_at   timestamptz not null default now(),
  submitted_at        timestamptz not null default now(),
  resubmitted_at      timestamptz,
  review_note         text check (review_note is null or char_length(review_note) <= 300),
  reviewed_by         uuid,
  reviewed_at         timestamptz,
  updated_at          timestamptz not null default now(),
  check (offers_pickup or offers_delivery)
);
create index if not exists vendor_applications_applicant_idx on public.vendor_applications(applicant_id);
alter table public.vendor_applications enable row level security;
revoke all on public.vendor_applications from public, anon, authenticated;

create table if not exists public.vendor_private (
  vendor_id    uuid primary key references public.vendors(id) on delete cascade,
  payment_info text check (payment_info is null or char_length(payment_info) <= 500),
  updated_by   uuid,
  updated_at   timestamptz not null default now()
);
alter table public.vendor_private enable row level security;
revoke all on public.vendor_private from public, anon, authenticated;

create table if not exists public.notification_queue (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind       text not null,
  user_id    uuid,
  vendor_id  uuid,
  payload    jsonb not null default '{}'::jsonb,
  sent_at    timestamptz            -- stays NULL: nothing sends these yet (no SMTP). A future mailer reads rows where sent_at is null.
);
create index if not exists notification_queue_unsent_idx on public.notification_queue(created_at) where sent_at is null;
alter table public.notification_queue enable row level security;
revoke all on public.notification_queue from public, anon, authenticated;

-- =====================================================================================================
-- 2. Helpers
-- =====================================================================================================
create or replace function public._notify(p_kind text, p_user uuid, p_vendor uuid, p_payload jsonb) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.notification_queue(kind, user_id, vendor_id, payload) values (p_kind, p_user, p_vendor, coalesce(p_payload, '{}'::jsonb)) $$;
revoke all on function public._notify(text,uuid,uuid,jsonb) from public, anon, authenticated;

create or replace function public._ob_hide_samples() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select hide_samples from public.platform_settings where id), false) $$;

-- may shoppers buy from / see this business? approved, and not a SAMPLE that the admin has hidden
create or replace function public._ob_orderable(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select v.status = 'approved' and not (v.is_sample and public._ob_hide_samples()) from public.vendors v where v.id = p_vendor), false) $$;

create or replace function public._ob_has_product(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.products p where p.vendor_id = p_vendor and p.active) $$;

create or replace function public._ob_member(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and exists (select 1 from public.vendor_members m where m.vendor_id = p_vendor and m.user_id = auth.uid()) $$;

create or replace function public._ob_customer_seen(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and exists (select 1 from public.orders o where o.vendor_id = p_vendor and o.consumer_id = auth.uid()) $$;
revoke all on function public._ob_hide_samples(), public._ob_orderable(uuid), public._ob_has_product(uuid), public._ob_member(uuid), public._ob_customer_seen(uuid) from public;
grant execute on function public._ob_hide_samples(), public._ob_orderable(uuid), public._ob_has_product(uuid), public._ob_member(uuid), public._ob_customer_seen(uuid) to anon, authenticated;

-- =====================================================================================================
-- 3. Visibility: RESTRICTIVE policies (AND-ed with the existing permissive ones)
-- =====================================================================================================
drop policy if exists vendors_onb_visible on public.vendors;
create policy vendors_onb_visible on public.vendors as restrictive for select
  using (owner_id = auth.uid() or public.is_admin() or public._ob_member(id) or public._ob_customer_seen(id)
         or (status = 'approved' and not (is_sample and public._ob_hide_samples()) and public._ob_has_product(id)));
drop policy if exists products_onb_visible on public.products;
create policy products_onb_visible on public.products as restrictive for select
  using (public._ob_orderable(vendor_id) or public.is_admin() or public._ob_member(vendor_id));

-- =====================================================================================================
-- 4. Triggers
-- =====================================================================================================
-- vendors: a browser can never choose its own status, and nobody can leave a real business without an owner.
-- Our own SECURITY DEFINER functions set the transaction-local flag cc.vendor_op = 'on' (and cc.new_owner) to make approved changes.
create or replace function public.trg_vendors_onboard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare op boolean := coalesce(current_setting('cc.vendor_op', true), '') = 'on'; own text := nullif(current_setting('cc.new_owner', true), '');
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null and not public.is_admin() and not op then
      new.status := 'pending'; new.status_reason := null; new.status_changed_at := now(); new.status_changed_by := null;
    end if;
    return new;
  end if;
  if auth.uid() is not null and not public.is_admin() and not op then
    new.status := old.status; new.status_reason := old.status_reason; new.status_changed_at := old.status_changed_at; new.status_changed_by := old.status_changed_by;
  end if;
  if op and own is not null then new.owner_id := own::uuid; end if;
  if old.owner_id is not null and new.owner_id is null and not old.is_sample then
    raise exception 'A business must always have an owner';
  end if;
  return new;
end $$;
revoke all on function public.trg_vendors_onboard() from public, anon, authenticated;
drop trigger if exists trg_vendors_zz_onboard on public.vendors;
create trigger trg_vendors_zz_onboard before insert or update on public.vendors
  for each row execute function public.trg_vendors_onboard();

create or replace function public.trg_ob_orders_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public._ob_orderable(new.vendor_id) then
    raise exception 'VENDOR_UNAVAILABLE: This business is not open for orders right now.' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.trg_ob_orders_guard() from public, anon, authenticated;
drop trigger if exists trg_ob_orders on public.orders;
create trigger trg_ob_orders before insert on public.orders for each row execute function public.trg_ob_orders_guard();

create or replace function public.trg_ob_charge_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'UPDATE' and not (old.status = 'open' and new.status = 'paid') then return new; end if;
  if not public._ob_orderable(new.vendor_id) then
    raise exception 'VENDOR_UNAVAILABLE: This business is not taking payments right now.' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.trg_ob_charge_guard() from public, anon, authenticated;
drop trigger if exists trg_ob_charge_ins on public.pay_requests;
create trigger trg_ob_charge_ins before insert on public.pay_requests for each row execute function public.trg_ob_charge_guard();
drop trigger if exists trg_ob_charge_upd on public.pay_requests;
create trigger trg_ob_charge_upd before update of status on public.pay_requests for each row execute function public.trg_ob_charge_guard();

-- featured campaigns on the home page: only businesses the public can see (the one earlier function this file redefines)
create or replace function public.public_featured_campaigns() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'vendor_id', c.vendor_id, 'vendor_name', v.name, 'name', c.name,
           'headline', c.headline, 'ends_on', c.ends_on, 'has_discount', c.discount_pct is not null) order by c.ends_on, c.created_at), '[]'::jsonb)
    from (select k.* from public.campaigns k join public.vendors vv on vv.id = k.vendor_id
           where k.featured and k.active and (now() at time zone 'America/Grenada')::date between k.starts_on and k.ends_on
             and public._ob_orderable(k.vendor_id)
           order by k.ends_on, k.created_at limit 6) c
    join public.vendors v on v.id = c.vendor_id;
$$;
revoke all on function public.public_featured_campaigns() from public;
grant execute on function public.public_featured_campaigns() to anon, authenticated;

-- =====================================================================================================
-- 5. Applicant functions
-- =====================================================================================================
create or replace function public._ob_op(p_on boolean, p_owner uuid default null) returns void
language plpgsql as $$
begin
  perform set_config('cc.vendor_op', case when p_on then 'on' else '' end, true);
  perform set_config('cc.new_owner', case when p_on and p_owner is not null then p_owner::text else '' end, true);
end $$;
revoke all on function public._ob_op(boolean, uuid) from public, anon, authenticated;

create or replace function public._ob_reason(p_reason text, p_required boolean) returns text
language plpgsql immutable as $$
declare t text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if t is null and not p_required then return null; end if;
  if t is null or char_length(t) < 3 then raise exception 'Please give a reason (at least 3 characters)'; end if;
  if char_length(t) > 300 then raise exception 'The reason is too long (max 300 characters)'; end if;
  return t;
end $$;
revoke all on function public._ob_reason(text, boolean) from public, anon, authenticated;

-- validate + normalise the application form. Returns a clean jsonb or raises a plain-English error.
create or replace function public._ob_clean(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare nm text; ds text; isl text; ar text; cat text; ph text; wa text; bt text; vr boolean; vn text; rg text; pu boolean; dl boolean; tr text; agree boolean;
  ok_phone text := '^[0-9+() .-]{7,30}$';
begin
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'The application is empty'; end if;
  nm := btrim(coalesce(p->>'name', '')); ds := btrim(coalesce(p->>'description', '')); isl := coalesce(p->>'island', ''); ar := btrim(coalesce(p->>'area', ''));
  cat := coalesce(p->>'category', ''); ph := btrim(coalesce(p->>'phone', '')); wa := nullif(btrim(coalesce(p->>'whatsapp', '')), '');
  bt := coalesce(p->>'business_type', ''); vn := nullif(btrim(coalesce(p->>'vat_number', '')), ''); rg := nullif(btrim(coalesce(p->>'registration_number', '')), '');
  tr := coalesce(nullif(p->>'tier', ''), 'lite');
  begin
    vr := coalesce((p->>'vat_registered')::boolean, false); pu := coalesce((p->>'offers_pickup')::boolean, false); dl := coalesce((p->>'offers_delivery')::boolean, false);
    agree := coalesce((p->>'agree_terms')::boolean, false);
  exception when others then raise exception 'Invalid application (a yes/no answer is not valid)'; end;
  if char_length(nm) < 2 or char_length(nm) > 80 or nm ~ '[[:cntrl:]]' then raise exception 'Business name must be 2 to 80 characters'; end if;
  if char_length(ds) < 10 then raise exception 'Please describe your business (at least 10 characters)'; end if;
  if char_length(ds) > 500 then raise exception 'The description is too long (max 500 characters)'; end if;
  if isl not in ('Carriacou','Petite Martinique','Grenada') then raise exception 'Choose Carriacou, Petite Martinique or Grenada'; end if;
  if char_length(ar) < 2 or char_length(ar) > 60 or ar ~ '[[:cntrl:]]' then raise exception 'Enter your parish or area (2 to 60 characters)'; end if;
  if cat not in ('food','crafts','fashion','beauty','sea','home') then raise exception 'Choose a main category'; end if;
  if ph !~ ok_phone then raise exception 'Enter a contact phone number (digits, +, spaces, brackets or dashes; 7 to 30 characters)'; end if;
  if wa is not null and wa !~ ok_phone then raise exception 'The WhatsApp number is not valid'; end if;
  if bt not in ('sole_trader','company','cooperative','nonprofit','other') then raise exception 'Choose a business type'; end if;
  if vr and vn is null then raise exception 'Enter your VAT number, or say you are not VAT registered'; end if;
  if not vr then vn := null; end if;
  if vn is not null and (char_length(vn) > 40 or vn ~ '[[:cntrl:]]') then raise exception 'The VAT number is too long or has invalid characters (max 40)'; end if;
  if rg is not null and (char_length(rg) > 60 or rg ~ '[[:cntrl:]]') then raise exception 'The registration number is too long or has invalid characters (max 60)'; end if;
  if not pu and not dl then raise exception 'Choose pickup, delivery or both'; end if;
  if not exists (select 1 from public.tier_limits where tier = tr) then raise exception 'Choose a plan'; end if;
  if not agree then raise exception 'Please accept the Vendor Terms to apply'; end if;
  return jsonb_build_object('name', nm, 'description', ds, 'island', isl, 'area', ar, 'category', cat, 'phone', ph, 'whatsapp', wa, 'business_type', bt,
    'vat_registered', vr, 'vat_number', vn, 'registration_number', rg, 'offers_pickup', pu, 'offers_delivery', dl, 'tier', tr);
end $$;
revoke all on function public._ob_clean(jsonb) from public, anon, authenticated;

create or replace function public._ob_location(p_island text, p_area text) returns text
language sql immutable as $$ select case when p_island = 'Carriacou' then p_area else p_area || ', ' || p_island end $$;
revoke all on function public._ob_location(text, text) from public, anon, authenticated;

create or replace function public.submit_vendor_application(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); c jsonb; vid uuid; r text;
begin
  if uid is null then raise exception 'Please log in'; end if;
  select role into r from public.profiles where id = uid;
  if r is null then raise exception 'Account not found'; end if;
  if r = 'admin' then raise exception 'Platform admin accounts cannot apply to sell'; end if;
  if public._acct_suspended(uid) then perform public._acct_block(); end if;
  c := public._ob_clean(p);
  perform pg_advisory_xact_lock(hashtext('apply:' || uid::text));
  if exists (select 1 from public.vendors v where v.owner_id = uid and v.status in ('pending','changes_requested')) then
    raise exception 'You already have an application waiting. Open "Application status" to edit it.'; end if;
  if (select count(*) from public.vendors v where v.owner_id = uid) >= 5 then raise exception 'You can own at most 5 businesses'; end if;
  if r = 'consumer' then update public.profiles set role = 'vendor' where id = uid; end if;
  insert into public.vendors(owner_id, name, description, location)
    values (uid, c->>'name', c->>'description', public._ob_location(c->>'island', c->>'area')) returning id into vid;
  insert into public.vendor_applications(vendor_id, applicant_id, business_type, island, area, category, contact_phone, whatsapp, vat_registered, vat_number,
      registration_number, offers_pickup, offers_delivery, requested_tier, terms_version)
    values (vid, uid, c->>'business_type', c->>'island', c->>'area', c->>'category', c->>'phone', c->>'whatsapp', (c->>'vat_registered')::boolean, c->>'vat_number',
      c->>'registration_number', (c->>'offers_pickup')::boolean, (c->>'offers_delivery')::boolean, c->>'tier', 'draft-1');
  perform public._audit(vid, 'onb_applied', uid, jsonb_build_object('name', c->>'name', 'requested_tier', c->>'tier'));
  perform public._notify('application_received', uid, vid, jsonb_build_object('name', c->>'name'));
  return jsonb_build_object('ok', true, 'vendor_id', vid, 'status', 'pending');
end $$;

create or replace function public.update_vendor_application(p_vendor uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); c jsonb; v record; was text;
begin
  if uid is null then raise exception 'Please log in'; end if;
  select * into v from public.vendors where id = p_vendor and owner_id = uid for update;
  if not found then raise exception 'Application not found'; end if;
  if v.status not in ('pending','changes_requested','rejected') then raise exception 'This business is already approved. Change its details from the business dashboard.'; end if;
  if public._acct_suspended(uid) then perform public._acct_block(); end if;
  c := public._ob_clean(p);
  was := v.status;
  perform public._ob_op(true);
  update public.vendors set name = c->>'name', description = c->>'description', location = public._ob_location(c->>'island', c->>'area'),
      status = 'pending', status_reason = null, status_changed_at = now(), status_changed_by = uid where id = p_vendor;
  perform public._ob_op(false);
  insert into public.vendor_applications(vendor_id, applicant_id, business_type, island, area, category, contact_phone, whatsapp, vat_registered, vat_number,
      registration_number, offers_pickup, offers_delivery, requested_tier, terms_version)
    values (p_vendor, uid, c->>'business_type', c->>'island', c->>'area', c->>'category', c->>'phone', c->>'whatsapp', (c->>'vat_registered')::boolean, c->>'vat_number',
      c->>'registration_number', (c->>'offers_pickup')::boolean, (c->>'offers_delivery')::boolean, c->>'tier', 'draft-1')
  on conflict (vendor_id) do update set business_type = excluded.business_type, island = excluded.island, area = excluded.area, category = excluded.category,
      contact_phone = excluded.contact_phone, whatsapp = excluded.whatsapp, vat_registered = excluded.vat_registered, vat_number = excluded.vat_number,
      registration_number = excluded.registration_number, offers_pickup = excluded.offers_pickup, offers_delivery = excluded.offers_delivery,
      requested_tier = excluded.requested_tier, terms_version = excluded.terms_version, terms_accepted_at = now(), resubmitted_at = now(), updated_at = now();
  perform public._audit(p_vendor, 'onb_updated', uid, jsonb_build_object('from_status', was, 'name', c->>'name', 'requested_tier', c->>'tier'));
  perform public._notify('application_resubmitted', uid, p_vendor, jsonb_build_object('name', c->>'name', 'from_status', was));
  return jsonb_build_object('ok', true, 'vendor_id', p_vendor, 'status', 'pending');
end $$;

-- the logged-in person's own businesses and applications (never anybody else's)
create or replace function public.my_applications() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please log in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('vendor_id', v.id, 'name', v.name, 'description', v.description, 'status', v.status,
      'status_reason', v.status_reason, 'status_changed_at', v.status_changed_at, 'tier', v.tier, 'created_at', v.created_at, 'is_sample', v.is_sample,
      'can_edit', v.status in ('pending','changes_requested','rejected'),
      'application', case when a.vendor_id is null then null else jsonb_build_object('business_type', a.business_type, 'island', a.island, 'area', a.area,
        'category', a.category, 'phone', a.contact_phone, 'whatsapp', a.whatsapp, 'vat_registered', a.vat_registered, 'vat_number', a.vat_number,
        'registration_number', a.registration_number, 'offers_pickup', a.offers_pickup, 'offers_delivery', a.offers_delivery, 'tier', a.requested_tier,
        'submitted_at', a.submitted_at, 'resubmitted_at', a.resubmitted_at, 'terms_version', a.terms_version) end) order by v.created_at desc)
    from public.vendors v left join public.vendor_applications a on a.vendor_id = v.id where v.owner_id = uid), '[]'::jsonb);
end $$;

-- =====================================================================================================
-- 6. Onboarding checklist, payment info
-- =====================================================================================================
create or replace function public._ob_can_see(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and (public.is_admin() or exists (select 1 from public.vendors v where v.id = p_vendor and v.owner_id = auth.uid())
    or exists (select 1 from public.vendor_members m where m.vendor_id = p_vendor and m.user_id = auth.uid() and m.status = 'active')) $$;
revoke all on function public._ob_can_see(uuid) from public, anon, authenticated;

create or replace function public.vendor_onboarding_status(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v record; cs record; items jsonb := '[]'::jsonb; done int := 0; total int := 0; has_prod boolean; has_photo boolean; pay text; team boolean;
  add_item text; d boolean;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not public._ob_can_see(p_vendor) then raise exception 'Business not found'; end if;
  select * into v from public.vendors where id = p_vendor;
  if not found then raise exception 'Business not found'; end if;
  has_prod := public._ob_has_product(p_vendor);
  has_photo := exists (select 1 from public.products p where p.vendor_id = p_vendor and p.active and nullif(btrim(coalesce(p.image_url, '')), '') is not null);
  select * into cs from public.vendor_checkout_settings where vendor_id = p_vendor;
  select payment_info into pay from public.vendor_private where vendor_id = p_vendor;
  team := exists (select 1 from public.vendor_members m where m.vendor_id = p_vendor and m.role <> 'admin')
       or exists (select 1 from public.vendor_invites i where i.vendor_id = p_vendor and i.revoked_at is null);
  -- key, label, done, optional, tab to open
  for add_item, d in select t.k, t.dd from (values ('profile', char_length(btrim(v.description)) >= 20 and char_length(btrim(v.location)) >= 2 and nullif(btrim(coalesce(v.logo_url, '')), '') is not null),
                            ('product', has_prod and has_photo),
                            ('delivery', cs.vendor_id is not null and cs.updated_by is not null),
                            ('tax', cs.vendor_id is not null and cs.updated_by is not null and (not cs.vat_registered or nullif(btrim(coalesce(cs.vat_number, '')), '') is not null)),
                            ('payment', nullif(btrim(coalesce(pay, '')), '') is not null),
                            ('staff', team) ) t(k, dd)
  loop
    total := total + 1; if d then done := done + 1; end if;
    items := items || jsonb_build_array(jsonb_build_object('key', add_item, 'done', d, 'optional', add_item = 'staff'));
  end loop;
  return jsonb_build_object('vendor_id', p_vendor, 'status', v.status, 'items', items, 'done', done, 'total', total, 'pct', round(100.0 * done / total),
    'live_rule', 'approved and at least one active product', 'has_active_product', has_prod,
    'live', v.status = 'approved' and has_prod and public._ob_orderable(p_vendor),
    'can_go_live', v.status = 'approved' and has_prod);
end $$;

create or replace function public.set_vendor_payment_info(p_vendor uuid, p_text text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t text := nullif(btrim(coalesce(p_text, '')), '');
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not public.vendor_perm(p_vendor, 'vendor_edit') then raise exception 'Only the business owner can change payment information'; end if;
  if t is not null and (char_length(t) > 500 or t ~ '[[:cntrl:]]') then raise exception 'Payment information is too long or has invalid characters (max 500)'; end if;
  insert into public.vendor_private(vendor_id, payment_info, updated_by, updated_at) values (p_vendor, t, auth.uid(), now())
  on conflict (vendor_id) do update set payment_info = excluded.payment_info, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  perform public._audit(p_vendor, 'onb_payment_info', null, jsonb_build_object('set', t is not null));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.get_vendor_payment_info(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not (public.vendor_perm(p_vendor, 'vendor_edit') or public.is_admin()) then raise exception 'Only the business owner can see payment information'; end if;
  return jsonb_build_object('payment_info', (select payment_info from public.vendor_private where vendor_id = p_vendor));
end $$;

-- =====================================================================================================
-- 7. Admin functions (platform admin only)
-- =====================================================================================================
create or replace function public._ob_target(p_vendor uuid) returns public.vendors
language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.vendors;
begin
  perform public._require_platform_admin();
  select * into v from public.vendors where id = p_vendor for update;
  if not found then raise exception 'Business not found'; end if;
  return v;
end $$;
revoke all on function public._ob_target(uuid) from public, anon, authenticated;

-- p_status: all | pending | changes_requested | approved | suspended | rejected | sample ; searchable and paginated
create or replace function public.admin_app_list(p_q text default null, p_status text default 'all', p_limit int default 25, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare lim int := least(100, greatest(1, coalesce(p_limit, 25))); off int := greatest(0, coalesce(p_offset, 0));
  q text := nullif(btrim(coalesce(p_q, '')), ''); pat text; total int; rows jsonb; counts jsonb;
begin
  perform public._require_platform_admin();
  if coalesce(p_status, 'all') not in ('all','pending','changes_requested','approved','suspended','rejected','sample') then raise exception 'Unknown status filter'; end if;
  if q is not null and char_length(q) > 100 then raise exception 'Search text is too long'; end if;
  if q is not null then pat := '%' || replace(replace(replace(lower(q), '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  select jsonb_build_object('all', count(*), 'pending', count(*) filter (where status = 'pending'), 'changes_requested', count(*) filter (where status = 'changes_requested'),
      'approved', count(*) filter (where status = 'approved'), 'suspended', count(*) filter (where status = 'suspended'),
      'rejected', count(*) filter (where status = 'rejected'), 'sample', count(*) filter (where is_sample)) into counts from public.vendors;
  with f as (
    select v.id, v.created_at, coalesce(a.submitted_at, v.created_at) sub,
      jsonb_build_object('id', v.id, 'name', v.name, 'status', v.status, 'tier', v.tier, 'is_sample', v.is_sample, 'created_at', v.created_at,
        'owner_email', u.email, 'owner_name', p.full_name, 'island', a.island, 'area', a.area, 'category', a.category, 'requested_tier', a.requested_tier,
        'has_application', a.vendor_id is not null, 'submitted_at', a.submitted_at, 'resubmitted_at', a.resubmitted_at,
        'products', (select count(*) from public.products x where x.vendor_id = v.id)) x
    from public.vendors v left join public.vendor_applications a on a.vendor_id = v.id left join auth.users u on u.id = v.owner_id left join public.profiles p on p.id = v.owner_id
    where (coalesce(p_status,'all') = 'all' or (p_status = 'sample' and v.is_sample) or v.status = p_status)
      and (pat is null or lower(v.name) like pat escape '\' or lower(coalesce(u.email,'')) like pat escape '\' or lower(coalesce(p.full_name,'')) like pat escape '\'
           or lower(coalesce(a.contact_phone,'')) like pat escape '\' or lower(coalesce(a.area,'')) like pat escape '\')),
  pg as (select * from f order by (case when (x->>'status') in ('pending','changes_requested') then 0 else 1 end), sub desc, id limit lim offset off)
  select (select count(*) from f), coalesce((select jsonb_agg(x order by (case when (x->>'status') in ('pending','changes_requested') then 0 else 1 end), sub desc, id) from pg), '[]'::jsonb)
    into total, rows;
  return jsonb_build_object('total', total, 'limit', lim, 'offset', off, 'rows', rows, 'counts', counts, 'hide_samples', public._ob_hide_samples());
end $$;

create or replace function public.admin_app_get(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v record; a record; u record; pr record; hist jsonb; ck jsonb; pay text; ord int;
begin
  perform public._require_platform_admin();
  select * into v from public.vendors where id = p_vendor;
  if not found then raise exception 'Business not found'; end if;
  select * into a from public.vendor_applications where vendor_id = p_vendor;
  select email into u from auth.users where id = v.owner_id;
  select full_name, phone into pr from public.profiles where id = v.owner_id;
  select payment_info into pay from public.vendor_private where vendor_id = p_vendor;
  select count(*) into ord from public.orders where vendor_id = p_vendor;
  select coalesce(jsonb_agg(jsonb_build_object('at', g.at, 'action', g.action, 'by', ua.email, 'details', g.details) order by g.at desc, g.id desc), '[]'::jsonb) into hist
    from (select * from public.audit_log where vendor_id = p_vendor and action like 'onb\_%' order by at desc, id desc limit 50) g left join auth.users ua on ua.id = g.actor_id;
  return jsonb_build_object('id', v.id, 'name', v.name, 'description', v.description, 'location', v.location, 'status', v.status, 'status_reason', v.status_reason,
    'status_changed_at', v.status_changed_at, 'tier', v.tier, 'is_sample', v.is_sample, 'created_at', v.created_at, 'owner_id', v.owner_id,
    'owner_email', u.email, 'owner_name', pr.full_name, 'owner_phone', pr.phone, 'orders', ord,
    'products', (select count(*) from public.products x where x.vendor_id = p_vendor), 'active_products', (select count(*) from public.products x where x.vendor_id = p_vendor and x.active),
    'payment_info', pay,
    'application', case when a.vendor_id is null then null else jsonb_build_object('business_type', a.business_type, 'island', a.island, 'area', a.area, 'category', a.category,
      'phone', a.contact_phone, 'whatsapp', a.whatsapp, 'vat_registered', a.vat_registered, 'vat_number', a.vat_number, 'registration_number', a.registration_number,
      'offers_pickup', a.offers_pickup, 'offers_delivery', a.offers_delivery, 'requested_tier', a.requested_tier, 'terms_version', a.terms_version,
      'terms_accepted_at', a.terms_accepted_at, 'submitted_at', a.submitted_at, 'resubmitted_at', a.resubmitted_at, 'review_note', a.review_note, 'reviewed_at', a.reviewed_at) end,
    'history', hist);
end $$;

-- decision: approve | reject | request_changes
create or replace function public.admin_app_decide(p_vendor uuid, p_decision text, p_reason text default null, p_tier text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.vendors; a public.vendor_applications; rs text; tr text; ns text; act text; owner uuid;
begin
  v := public._ob_target(p_vendor);
  select * into a from public.vendor_applications where vendor_id = p_vendor;
  owner := v.owner_id;
  if p_decision = 'approve' then
    if v.status not in ('pending','changes_requested','rejected') then raise exception 'Only a waiting or rejected application can be approved (this business is %)', v.status; end if;
    rs := public._ob_reason(p_reason, false); ns := 'approved'; act := 'onb_approved';
    tr := coalesce(nullif(p_tier, ''), a.requested_tier, v.tier);
    if not exists (select 1 from public.tier_limits where tier = tr) then raise exception 'Unknown plan'; end if;
  elsif p_decision = 'reject' then
    if v.status not in ('pending','changes_requested') then raise exception 'Only a waiting application can be rejected (this business is %)', v.status; end if;
    rs := public._ob_reason(p_reason, true); ns := 'rejected'; act := 'onb_rejected';
  elsif p_decision = 'request_changes' then
    if v.status not in ('pending') then raise exception 'Changes can only be requested on a waiting application (this business is %)', v.status; end if;
    rs := public._ob_reason(p_reason, true); ns := 'changes_requested'; act := 'onb_changes_requested';
  else raise exception 'Unknown decision'; end if;
  if owner is null then raise exception 'This business has no owner'; end if;
  perform public._ob_op(true);
  update public.vendors set status = ns, status_reason = case when ns = 'approved' then null else rs end, status_changed_at = now(), status_changed_by = auth.uid() where id = p_vendor;
  perform public._ob_op(false);
  if ns = 'approved' then
    perform public._apply_tier(p_vendor, tr);
    if a.vendor_id is not null then
      insert into public.vendor_checkout_settings(vendor_id, pickup_enabled, delivery_enabled, vat_registered, vat_number, updated_by)
        values (p_vendor, a.offers_pickup, a.offers_delivery, a.vat_registered, a.vat_number, null) on conflict (vendor_id) do nothing;
    end if;
  end if;
  if a.vendor_id is not null then
    update public.vendor_applications set review_note = rs, reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now() where vendor_id = p_vendor;
  end if;
  perform public._audit(p_vendor, act, owner, jsonb_build_object('reason', rs, 'from', v.status, 'to', ns, 'tier', case when ns = 'approved' then tr end, 'requested_tier', a.requested_tier));
  perform public._notify('application_' || ns, owner, p_vendor, jsonb_build_object('name', v.name, 'reason', rs, 'tier', case when ns = 'approved' then tr end));
  return jsonb_build_object('ok', true, 'status', ns, 'tier', case when ns = 'approved' then tr else v.tier end);
end $$;

-- suspend | reinstate
create or replace function public.admin_vendor_set_status(p_vendor uuid, p_action text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.vendors; rs text; ns text;
begin
  v := public._ob_target(p_vendor);
  rs := public._ob_reason(p_reason, true);
  if p_action = 'suspend' then
    if v.status <> 'approved' then raise exception 'Only an approved business can be suspended (this one is %)', v.status; end if;
    ns := 'suspended';
  elsif p_action = 'reinstate' then
    if v.status <> 'suspended' then raise exception 'Only a suspended business can be reinstated (this one is %)', v.status; end if;
    ns := 'approved';
  else raise exception 'Unknown action'; end if;
  perform public._ob_op(true);
  update public.vendors set status = ns, status_reason = case when ns = 'suspended' then rs else null end, status_changed_at = now(), status_changed_by = auth.uid() where id = p_vendor;
  perform public._ob_op(false);
  perform public._audit(p_vendor, case when ns = 'suspended' then 'onb_suspended' else 'onb_reinstated' end, v.owner_id, jsonb_build_object('reason', rs, 'from', v.status, 'to', ns));
  perform public._notify('vendor_' || ns, v.owner_id, p_vendor, jsonb_build_object('name', v.name, 'reason', rs));
  return jsonb_build_object('ok', true, 'status', ns);
end $$;

-- give a business (a SAMPLE one, or any) to a customer found by email. A SAMPLE business becomes a real one. Optional new name.
create or replace function public.admin_assign_owner(p_vendor uuid, p_email text, p_reason text, p_new_name text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.vendors; rs text; em text := lower(btrim(coalesce(p_email, ''))); t uuid; tr text; nm text := nullif(btrim(coalesce(p_new_name, '')), ''); old_email text;
  old_owner uuid; kept text := null; act text;
begin
  v := public._ob_target(p_vendor);
  rs := public._ob_reason(p_reason, true);
  if em = '' then raise exception 'Enter the new owner''s email address'; end if;
  select u.id, p.role into t, tr from auth.users u join public.profiles p on p.id = u.id where lower(u.email) = em;
  if t is null then raise exception 'No account has that email address. Ask them to sign up first.'; end if;
  if tr = 'admin' then raise exception 'A platform admin account cannot own a business'; end if;
  if public._acct_suspended(t) then raise exception 'That account is suspended'; end if;
  if t is not distinct from v.owner_id then raise exception 'That person already owns this business'; end if;
  if (select count(*) from public.vendors x where x.owner_id = t) >= 5 then raise exception 'That person already owns 5 businesses'; end if;
  if nm is not null and (char_length(nm) < 2 or char_length(nm) > 80 or nm ~ '[[:cntrl:]]') then raise exception 'Business name must be 2 to 80 characters'; end if;
  old_owner := v.owner_id;
  select email into old_email from auth.users where id = old_owner;
  if tr = 'consumer' then update public.profiles set role = 'vendor' where id = t; end if;
  perform public._ob_op(true, t);
  update public.vendors set owner_id = t, is_sample = false, name = coalesce(nm, name), status_changed_at = now(), status_changed_by = auth.uid() where id = p_vendor;
  perform public._ob_op(false);
  act := case when old_owner is null then 'onb_owner_assigned' else 'onb_owner_reassigned' end;
  if old_owner is not null then
    begin
      insert into public.vendor_members(vendor_id, user_id, role, status, invited_by) values (p_vendor, old_owner, 'subadmin', 'active', auth.uid());
      kept := 'subadmin';
    exception when others then kept := null; end;
  end if;
  perform public._audit(p_vendor, act, t, jsonb_build_object('reason', rs, 'new_owner', em, 'old_owner', old_email, 'was_sample', v.is_sample, 'old_owner_role', kept, 'renamed_to', nm));
  perform public._notify('owner_assigned', t, p_vendor, jsonb_build_object('name', coalesce(nm, v.name)));
  return jsonb_build_object('ok', true, 'owner', em, 'was_sample', v.is_sample, 'old_owner_role', kept);
end $$;

create or replace function public.admin_set_hide_samples(p_hide boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare old boolean;
begin
  perform public._require_platform_admin();
  if p_hide is null then raise exception 'Choose hide or show'; end if;
  select hide_samples into old from public.platform_settings where id;
  update public.platform_settings set hide_samples = p_hide, updated_by = auth.uid(), updated_at = now() where id;
  perform public._audit(null, case when p_hide then 'onb_samples_hidden' else 'onb_samples_shown' end, null, jsonb_build_object('before', old, 'after', p_hide, 'reason', public._ob_reason(p_reason, false)));
  return jsonb_build_object('ok', true, 'hide_samples', p_hide);
end $$;

-- =====================================================================================================
-- 8. Ownership transfer by the owner
-- =====================================================================================================
create or replace function public.transfer_vendor_ownership(p_vendor uuid, p_new_owner uuid, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); v public.vendors; m record; kept text := null; ne text; nr text;
begin
  if uid is null then raise exception 'Please log in'; end if;
  select * into v from public.vendors where id = p_vendor and owner_id = uid for update;
  if not found then raise exception 'Only the business owner can transfer ownership'; end if;
  if public._acct_suspended(uid) then perform public._acct_block(); end if;
  if v.status not in ('approved','pending','changes_requested') then raise exception 'This business is % and cannot be transferred. Contact Carriacou Connect support.', v.status; end if;
  if p_new_owner is null or p_new_owner = uid then raise exception 'Choose a team member to receive the business'; end if;
  if lower(btrim(coalesce(p_confirm, ''))) <> lower(btrim(v.name)) then raise exception 'To confirm, type the exact business name'; end if;
  select * into m from public.vendor_members where vendor_id = p_vendor and user_id = p_new_owner and role in ('staff','subadmin') for update;
  if not found then raise exception 'You can only transfer to someone on your team (staff or sub-admin)'; end if;
  if m.status <> 'active' then raise exception 'That team member is paused. Switch their access on first.'; end if;
  select email into ne from auth.users where id = p_new_owner;
  select role into nr from public.profiles where id = p_new_owner;
  if nr = 'admin' then raise exception 'A platform admin account cannot own a business'; end if;
  if public._acct_suspended(p_new_owner) then raise exception 'That account is suspended'; end if;
  if (select count(*) from public.vendors x where x.owner_id = p_new_owner) >= 5 then raise exception 'That person already owns 5 businesses'; end if;
  if nr = 'consumer' then update public.profiles set role = 'vendor' where id = p_new_owner; end if;
  perform public._ob_op(true, p_new_owner);
  update public.vendors set owner_id = p_new_owner where id = p_vendor;
  perform public._ob_op(false);
  begin
    insert into public.vendor_members(vendor_id, user_id, role, status, invited_by) values (p_vendor, uid, 'subadmin', 'active', uid);
    kept := 'subadmin';
  exception when others then kept := null; end;
  perform public._audit(p_vendor, 'onb_owner_transferred', p_new_owner, jsonb_build_object('new_owner', ne, 'old_owner_role', kept));
  perform public._notify('owner_transferred', p_new_owner, p_vendor, jsonb_build_object('name', v.name));
  return jsonb_build_object('ok', true, 'new_owner', ne, 'old_owner_role', kept);
end $$;

-- =====================================================================================================
-- 8b. Admin > Vendors tab (admin_vend_*, same patterns as admin_customers.sql)
--     Extra admin-only profile data for businesses with no application row (category, phone, notes).
--     Every function starts with _require_platform_admin(), is revoked from public/anon, and writes audit_log (before/after/reason).
-- =====================================================================================================
create table if not exists public.vendor_admin_profile (
  vendor_id     uuid primary key references public.vendors(id) on delete cascade,
  category      text check (category is null or category in ('food','crafts','fashion','beauty','sea','home')),
  contact_phone text check (contact_phone is null or char_length(contact_phone) between 7 and 30),
  whatsapp      text check (whatsapp is null or char_length(whatsapp) between 7 and 30),
  admin_notes   text check (admin_notes is null or char_length(admin_notes) <= 1000),
  updated_by    uuid,
  updated_at    timestamptz not null default now()
);
alter table public.vendor_admin_profile enable row level security;
revoke all on public.vendor_admin_profile from public, anon, authenticated;

-- p_status: all | pending | changes_requested | approved | suspended | rejected | sample ; p_tier: all | a plan name
create or replace function public.admin_vend_list(p_q text default null, p_status text default 'all', p_tier text default 'all', p_limit int default 25, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare lim int := least(100, greatest(1, coalesce(p_limit, 25))); off int := greatest(0, coalesce(p_offset, 0));
  q text := nullif(btrim(coalesce(p_q, '')), ''); pat text; total int; rows jsonb; counts jsonb; tr text := coalesce(nullif(p_tier, ''), 'all');
begin
  perform public._require_platform_admin();
  if coalesce(p_status, 'all') not in ('all','pending','changes_requested','approved','suspended','rejected','sample') then raise exception 'Unknown status filter'; end if;
  if tr <> 'all' and not exists (select 1 from public.tier_limits where tier = tr) then raise exception 'Unknown plan filter'; end if;
  if q is not null and char_length(q) > 100 then raise exception 'Search text is too long'; end if;
  if q is not null then pat := '%' || replace(replace(replace(lower(q), '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  select jsonb_build_object('all', count(*), 'pending', count(*) filter (where status = 'pending'), 'changes_requested', count(*) filter (where status = 'changes_requested'),
      'approved', count(*) filter (where status = 'approved'), 'suspended', count(*) filter (where status = 'suspended'),
      'rejected', count(*) filter (where status = 'rejected'), 'sample', count(*) filter (where is_sample)) into counts from public.vendors;
  with f as (
    select v.id, v.created_at,
      jsonb_build_object('id', v.id, 'name', v.name, 'status', v.status, 'tier', v.tier, 'is_sample', v.is_sample, 'created_at', v.created_at, 'location', v.location,
        'owner_id', v.owner_id, 'owner_email', u.email, 'owner_name', p.full_name, 'category', coalesce(a.category, ap.category),
        'products', (select count(*) from public.products x where x.vendor_id = v.id),
        'orders', (select count(*) from public.orders o where o.vendor_id = v.id),
        'revenue_xcd', (select coalesce(sum(o.total_xcd), 0) from public.orders o where o.vendor_id = v.id and o.status <> 'cancelled')) x
    from public.vendors v left join public.vendor_applications a on a.vendor_id = v.id left join public.vendor_admin_profile ap on ap.vendor_id = v.id
      left join auth.users u on u.id = v.owner_id left join public.profiles p on p.id = v.owner_id
    where (coalesce(p_status,'all') = 'all' or (p_status = 'sample' and v.is_sample) or v.status = p_status)
      and (tr = 'all' or v.tier = tr)
      and (pat is null or lower(v.name) like pat escape '\' or lower(coalesce(u.email,'')) like pat escape '\' or lower(coalesce(p.full_name,'')) like pat escape '\'
           or lower(v.location) like pat escape '\' or lower(coalesce(a.category, ap.category, '')) like pat escape '\')),
  pg as (select * from f order by created_at desc, id limit lim offset off)
  select (select count(*) from f), coalesce((select jsonb_agg(x order by created_at desc, id) from pg), '[]'::jsonb) into total, rows;
  return jsonb_build_object('total', total, 'limit', lim, 'offset', off, 'rows', rows, 'counts', counts, 'hide_samples', public._ob_hide_samples());
end $$;

create or replace function public.admin_vend_get(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare base jsonb; v record; ap record; ck record; staff jsonb; prods jsonb; ords jsonb; hist jsonb;
begin
  perform public._require_platform_admin();
  select * into v from public.vendors where id = p_vendor;
  if not found then raise exception 'Business not found'; end if;
  base := public.admin_app_get(p_vendor);
  select * into ap from public.vendor_admin_profile where vendor_id = p_vendor;
  select * into ck from public.vendor_checkout_settings where vendor_id = p_vendor;
  select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'email', u.email, 'name', p.full_name, 'role', m.role, 'status', m.status, 'since', m.created_at) order by m.created_at), '[]'::jsonb) into staff
    from public.vendor_members m left join auth.users u on u.id = m.user_id left join public.profiles p on p.id = m.user_id where m.vendor_id = p_vendor;
  select jsonb_build_object('total', count(*), 'active', count(*) filter (where active),
      'recent', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'price_xcd', r.price_xcd, 'active', r.active) order by r.created_at desc)
                          from (select * from public.products where vendor_id = p_vendor order by created_at desc limit 5) r), '[]'::jsonb)) into prods
    from public.products where vendor_id = p_vendor;
  select jsonb_build_object('count', count(*), 'revenue_xcd', coalesce(sum(total_xcd) filter (where status <> 'cancelled'), 0), 'last_order_at', max(created_at),
      'by_status', coalesce((select jsonb_object_agg(s.status, s.n) from (select status, count(*) n from public.orders where vendor_id = p_vendor group by status) s), '{}'::jsonb)) into ords
    from public.orders where vendor_id = p_vendor;
  select coalesce(jsonb_agg(jsonb_build_object('at', g.at, 'action', g.action, 'by', ua.email, 'details', g.details) order by g.at desc, g.id desc), '[]'::jsonb) into hist
    from (select * from public.audit_log where vendor_id = p_vendor and (action like 'onb\_%' or action like 'vend\_%' or action = 'tier_change_reason') order by at desc, id desc limit 60) g
    left join auth.users ua on ua.id = g.actor_id;
  return base || jsonb_build_object('category', coalesce(base->'application'->>'category', ap.category), 'admin_phone', coalesce(base->'application'->>'phone', ap.contact_phone),
    'admin_whatsapp', coalesce(base->'application'->>'whatsapp', ap.whatsapp), 'admin_notes', ap.admin_notes,
    'staff', staff, 'product_summary', prods, 'order_summary', ords, 'history', hist,
    'checkout', case when ck.vendor_id is null then null else jsonb_build_object('pickup_enabled', ck.pickup_enabled, 'delivery_enabled', ck.delivery_enabled, 'delivery_model', ck.delivery_model,
       'delivery_flat_fee', ck.delivery_flat_fee, 'free_over_xcd', ck.free_over_xcd, 'delivery_zones', ck.delivery_zones, 'vat_registered', ck.vat_registered,
       'vat_rate_pct', ck.vat_rate_pct, 'prices_include_tax', ck.prices_include_tax, 'vat_number', ck.vat_number, 'updated_at', ck.updated_at) end);
end $$;

-- edit business profile. p keys (all optional, only given keys change): name, description, category, island+area (together), phone, whatsapp,
-- vat_registered, vat_number, admin_notes. A reason of 3-300 characters is required. Audited with before/after.
create or replace function public.admin_vend_update(p_vendor uuid, p jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.vendors; rs text; a public.vendor_applications; ap public.vendor_admin_profile; ck public.vendor_checkout_settings;
  b jsonb := '{}'::jsonb; n jsonb := '{}'::jsonb; nm text; ds text; cat text; isl text; ar text; ph text; wa text; vr boolean; vn text; nt text;
  ok_phone text := '^[0-9+() .-]{7,30}$'; loc text; has_a boolean; k text;
begin
  v := public._ob_target(p_vendor);
  rs := public._ob_reason(p_reason, true);
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Nothing to change'; end if;
  for k in select jsonb_object_keys(p) loop
    if k not in ('name','description','category','island','area','phone','whatsapp','vat_registered','vat_number','admin_notes') then raise exception 'Unknown field: %', k; end if;
  end loop;
  select * into a from public.vendor_applications where vendor_id = p_vendor; has_a := found;
  select * into ap from public.vendor_admin_profile where vendor_id = p_vendor;
  select * into ck from public.vendor_checkout_settings where vendor_id = p_vendor;
  if p ? 'name' then
    nm := btrim(coalesce(p->>'name', ''));
    if char_length(nm) < 2 or char_length(nm) > 80 or nm ~ '[[:cntrl:]]' then raise exception 'Business name must be 2 to 80 characters'; end if;
    if nm is distinct from v.name then b := b || jsonb_build_object('name', v.name); n := n || jsonb_build_object('name', nm); end if;
  end if;
  if p ? 'description' then
    ds := btrim(coalesce(p->>'description', ''));
    if char_length(ds) < 10 or char_length(ds) > 500 then raise exception 'Description must be 10 to 500 characters'; end if;
    if ds is distinct from v.description then b := b || jsonb_build_object('description', v.description); n := n || jsonb_build_object('description', ds); end if;
  end if;
  if (p ? 'island') <> (p ? 'area') then raise exception 'Give the island and the area together'; end if;
  if p ? 'island' then
    isl := coalesce(p->>'island', ''); ar := btrim(coalesce(p->>'area', ''));
    if isl not in ('Carriacou','Petite Martinique','Grenada') then raise exception 'Choose Carriacou, Petite Martinique or Grenada'; end if;
    if char_length(ar) < 2 or char_length(ar) > 60 or ar ~ '[[:cntrl:]]' then raise exception 'Area must be 2 to 60 characters'; end if;
    loc := public._ob_location(isl, ar);
    if loc is distinct from v.location then b := b || jsonb_build_object('location', v.location); n := n || jsonb_build_object('location', loc); end if;
  end if;
  if p ? 'category' then
    cat := coalesce(p->>'category', '');
    if cat not in ('food','crafts','fashion','beauty','sea','home') then raise exception 'Choose a main category'; end if;
    if cat is distinct from coalesce(a.category, ap.category) then b := b || jsonb_build_object('category', coalesce(a.category, ap.category)); n := n || jsonb_build_object('category', cat); end if;
  end if;
  if p ? 'phone' then
    ph := btrim(coalesce(p->>'phone', ''));
    if ph !~ ok_phone then raise exception 'Enter a valid contact phone number'; end if;
    if ph is distinct from coalesce(a.contact_phone, ap.contact_phone) then b := b || jsonb_build_object('phone', coalesce(a.contact_phone, ap.contact_phone)); n := n || jsonb_build_object('phone', ph); end if;
  end if;
  if p ? 'whatsapp' then
    wa := nullif(btrim(coalesce(p->>'whatsapp', '')), '');
    if wa is not null and wa !~ ok_phone then raise exception 'The WhatsApp number is not valid'; end if;
    if wa is distinct from coalesce(a.whatsapp, ap.whatsapp) then b := b || jsonb_build_object('whatsapp', coalesce(a.whatsapp, ap.whatsapp)); n := n || jsonb_build_object('whatsapp', wa); end if;
  end if;
  if (p ? 'vat_registered') or (p ? 'vat_number') then
    begin vr := coalesce((p->>'vat_registered')::boolean, coalesce(ck.vat_registered, a.vat_registered, false)); exception when others then raise exception 'Invalid VAT answer'; end;
    vn := case when p ? 'vat_number' then nullif(btrim(coalesce(p->>'vat_number', '')), '') else coalesce(ck.vat_number, a.vat_number) end;
    if vr and vn is null then raise exception 'Enter the VAT number, or mark the business as not VAT registered'; end if;
    if not vr then vn := null; end if;
    if vn is not null and (char_length(vn) > 40 or vn ~ '[[:cntrl:]]') then raise exception 'The VAT number is too long or has invalid characters (max 40)'; end if;
    if vr is distinct from coalesce(ck.vat_registered, a.vat_registered, false) or vn is distinct from coalesce(ck.vat_number, a.vat_number) then
      b := b || jsonb_build_object('vat_registered', coalesce(ck.vat_registered, a.vat_registered, false), 'vat_number', coalesce(ck.vat_number, a.vat_number));
      n := n || jsonb_build_object('vat_registered', vr, 'vat_number', vn);
    end if;
  end if;
  if p ? 'admin_notes' then
    nt := nullif(btrim(coalesce(p->>'admin_notes', '')), '');
    if nt is not null and char_length(nt) > 1000 then raise exception 'Admin notes are too long (max 1000 characters)'; end if;
    if nt is distinct from ap.admin_notes then b := b || jsonb_build_object('admin_notes', ap.admin_notes); n := n || jsonb_build_object('admin_notes', nt); end if;
  end if;
  if n = '{}'::jsonb then raise exception 'Nothing was changed'; end if;
  -- apply
  if n ? 'name' or n ? 'description' or n ? 'location' then
    update public.vendors set name = coalesce(nm, name), description = coalesce(ds, description), location = coalesce(loc, location) where id = p_vendor;
  end if;
  if has_a and (n ? 'location' or n ? 'category' or n ? 'phone' or n ? 'whatsapp' or n ? 'vat_registered') then
    update public.vendor_applications set island = coalesce(isl, island), area = coalesce(ar, area), category = coalesce(cat, category), contact_phone = coalesce(ph, contact_phone),
      whatsapp = case when p ? 'whatsapp' then wa else whatsapp end,
      vat_registered = case when n ? 'vat_registered' then vr else vat_registered end, vat_number = case when n ? 'vat_registered' then vn else vat_number end,
      updated_at = now() where vendor_id = p_vendor;
  end if;
  if (not has_a and (n ? 'category' or n ? 'phone' or n ? 'whatsapp')) or n ? 'admin_notes' then
    insert into public.vendor_admin_profile(vendor_id, category, contact_phone, whatsapp, admin_notes, updated_by)
      values (p_vendor, case when not has_a then cat end, case when not has_a then ph end, case when not has_a and p ? 'whatsapp' then wa end, nt, auth.uid())
      on conflict (vendor_id) do update set category = case when not has_a and n ? 'category' then excluded.category else public.vendor_admin_profile.category end,
        contact_phone = case when not has_a and n ? 'phone' then excluded.contact_phone else public.vendor_admin_profile.contact_phone end,
        whatsapp = case when not has_a and n ? 'whatsapp' then excluded.whatsapp else public.vendor_admin_profile.whatsapp end,
        admin_notes = case when n ? 'admin_notes' then excluded.admin_notes else public.vendor_admin_profile.admin_notes end,
        updated_by = auth.uid(), updated_at = now();
  end if;
  if n ? 'vat_registered' then
    insert into public.vendor_checkout_settings(vendor_id, vat_registered, vat_number, updated_by) values (p_vendor, vr, vn, auth.uid())
      on conflict (vendor_id) do update set vat_registered = excluded.vat_registered, vat_number = excluded.vat_number, updated_by = auth.uid(), updated_at = now();
  end if;
  perform public._audit(p_vendor, 'vend_profile_edited', v.owner_id, jsonb_build_object('reason', rs, 'before', b, 'after', n));
  return jsonb_build_object('ok', true, 'changed', (select coalesce(jsonb_agg(key), '[]'::jsonb) from jsonb_object_keys(n) key));
end $$;

create or replace function public.admin_vend_set_tier(p_vendor uuid, p_tier text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.vendors; rs text;
begin
  v := public._ob_target(p_vendor);
  rs := public._ob_reason(p_reason, true);
  if not exists (select 1 from public.tier_limits where tier = p_tier) then raise exception 'Unknown plan'; end if;
  if v.tier = p_tier then raise exception 'This business is already on the % plan', p_tier; end if;
  perform public._apply_tier(p_vendor, p_tier);
  perform public._audit(p_vendor, 'vend_tier_changed', v.owner_id, jsonb_build_object('reason', rs, 'before', v.tier, 'after', p_tier, 'billing', 'test_mode'));
  return jsonb_build_object('ok', true, 'from', v.tier, 'to', p_tier);
end $$;

-- approve | reject | request_changes | suspend | reinstate  (delegates to the audited onboarding functions)
create or replace function public.admin_vend_decide(p_vendor uuid, p_decision text, p_reason text default null, p_tier text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  if p_decision in ('approve','reject','request_changes') then return public.admin_app_decide(p_vendor, p_decision, p_reason, p_tier);
  elsif p_decision in ('suspend','reinstate') then return public.admin_vendor_set_status(p_vendor, p_decision, p_reason);
  end if;
  raise exception 'Unknown decision';
end $$;

create or replace function public.admin_vend_assign_owner(p_vendor uuid, p_email text, p_reason text, p_new_name text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  return public.admin_assign_owner(p_vendor, p_email, p_reason, p_new_name);
end $$;

create or replace function public.admin_vend_set_hide_samples(p_hide boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  return public.admin_set_hide_samples(p_hide, p_reason);
end $$;

revoke all on function public.admin_vend_list(text, text, text, int, int), public.admin_vend_get(uuid), public.admin_vend_update(uuid, jsonb, text),
  public.admin_vend_set_tier(uuid, text, text), public.admin_vend_decide(uuid, text, text, text), public.admin_vend_assign_owner(uuid, text, text, text),
  public.admin_vend_set_hide_samples(boolean, text) from public, anon;
grant execute on function public.admin_vend_list(text, text, text, int, int), public.admin_vend_get(uuid), public.admin_vend_update(uuid, jsonb, text),
  public.admin_vend_set_tier(uuid, text, text), public.admin_vend_decide(uuid, text, text, text), public.admin_vend_assign_owner(uuid, text, text, text),
  public.admin_vend_set_hide_samples(boolean, text) to authenticated;


-- =====================================================================================================
-- 9. Permissions
-- =====================================================================================================
revoke all on function public.submit_vendor_application(jsonb), public.update_vendor_application(uuid, jsonb), public.my_applications(),
  public.vendor_onboarding_status(uuid), public.set_vendor_payment_info(uuid, text), public.get_vendor_payment_info(uuid),
  public.admin_app_list(text, text, int, int), public.admin_app_get(uuid), public.admin_app_decide(uuid, text, text, text),
  public.admin_vendor_set_status(uuid, text, text), public.admin_assign_owner(uuid, text, text, text), public.admin_set_hide_samples(boolean, text),
  public.transfer_vendor_ownership(uuid, uuid, text) from public, anon;
grant execute on function public.submit_vendor_application(jsonb), public.update_vendor_application(uuid, jsonb), public.my_applications(),
  public.vendor_onboarding_status(uuid), public.set_vendor_payment_info(uuid, text), public.get_vendor_payment_info(uuid),
  public.admin_app_list(text, text, int, int), public.admin_app_get(uuid), public.admin_app_decide(uuid, text, text, text),
  public.admin_vendor_set_status(uuid, text, text), public.admin_assign_owner(uuid, text, text, text), public.admin_set_hide_samples(boolean, text),
  public.transfer_vendor_ownership(uuid, uuid, text) to authenticated;

notify pgrst, 'reload schema';
