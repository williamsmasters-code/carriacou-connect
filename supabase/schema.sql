-- Carriacou Connect Marketplace v0.2 : Supabase schema
-- Run this whole file once in Supabase Dashboard > SQL Editor. Safe to re-run.
-- Uses only the anon key on the website; Row Level Security (RLS) protects the data.

create extension if not exists pgcrypto;

-- ---------- helpers ----------
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

-- ---------- profiles ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'consumer' check (role in ('consumer','vendor','admin')),
  full_name text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists trg_profiles_updated on public.profiles;
create trigger trg_profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

-- helper: is the current user an admin? (security definer avoids RLS recursion)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- auto-create profile on signup. Role comes from signup metadata but ONLY consumer/vendor is honoured.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text := coalesce(new.raw_user_meta_data->>'role','consumer');
begin
  if r not in ('consumer','vendor') then r := 'consumer'; end if;
  insert into public.profiles (id, role, full_name)
  values (new.id, r, nullif(new.raw_user_meta_data->>'full_name',''))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- users may not promote themselves to admin (or change role at all, except consumer<->vendor).
-- Changes made from the SQL editor (no logged-in user) are allowed, so you can make an admin there.
create or replace function public.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if new.role is distinct from old.role and (new.role = 'admin' or old.role = 'admin') then
      raise exception 'Not allowed to change to/from admin role';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_profiles_guard on public.profiles;
create trigger trg_profiles_guard before update on public.profiles
  for each row execute function public.guard_profile_role();

-- ---------- vendors ----------
create table if not exists public.vendors (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references auth.users(id) on delete cascade,  -- null for seeded SAMPLE vendors
  name text not null check (char_length(name) between 2 and 80),
  description text not null default '',
  location text not null default '',
  tier text not null default 'lite' check (tier in ('lite','standard','plus','pro','enterprise')),
  is_sample boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists vendors_owner_idx on public.vendors(owner_id);
drop trigger if exists trg_vendors_updated on public.vendors;
create trigger trg_vendors_updated before update on public.vendors
  for each row execute function public.set_updated_at();

-- Tier limits. 'plus' = Plus+. Returns null for unlimited.
create or replace function public.tier_limit(t text) returns integer
language sql immutable as $$
  select case t when 'lite' then 10 when 'standard' then 25 when 'plus' then 50 else null end;
$$;

-- Vendors can only create/own a business on Lite, and cannot change their own tier
-- (upgrades will come from billing later; admins or the SQL editor can change tiers now).
create or replace function public.guard_vendor() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if tg_op = 'INSERT' then
      if not exists (select 1 from public.profiles where id = auth.uid() and role = 'vendor') then
        raise exception 'Only vendor accounts can create a business profile';
      end if;
      new.tier := 'lite';
      new.owner_id := auth.uid();
      new.is_sample := false;
    else
      new.tier := old.tier;
      new.owner_id := old.owner_id;
      new.is_sample := old.is_sample;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_vendors_guard on public.vendors;
create trigger trg_vendors_guard before insert or update on public.vendors
  for each row execute function public.guard_vendor();

-- ---------- products ----------
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references public.vendors(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 120),
  description text not null default '',
  price_xcd numeric(10,2) not null check (price_xcd >= 0),
  category text not null default 'food' check (category in ('food','crafts','fashion','beauty','sea','home')),
  image_url text,
  active boolean not null default true,
  featured boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists products_vendor_idx on public.products(vendor_id);
drop trigger if exists trg_products_updated on public.products;
create trigger trg_products_updated before update on public.products
  for each row execute function public.set_updated_at();

-- Enforce tier product limit (counts ALL of a vendor's products, active or not).
create or replace function public.enforce_product_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim integer; cnt integer; t text;
begin
  select tier into t from public.vendors where id = new.vendor_id;
  lim := public.tier_limit(t);
  if lim is not null then
    select count(*) into cnt from public.products
      where vendor_id = new.vendor_id and (tg_op = 'INSERT' or id <> new.id);
    if cnt >= lim then
      raise exception 'Product limit reached: the % plan allows % products', t, lim
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_products_limit on public.products;
create trigger trg_products_limit before insert or update of vendor_id on public.products
  for each row execute function public.enforce_product_limit();

-- ---------- orders (stubs; checkout/Pay not built yet) ----------
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  consumer_id uuid not null references auth.users(id) on delete cascade,
  vendor_id uuid not null references public.vendors(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending','confirmed','ready','completed','cancelled')),
  total_xcd numeric(10,2) not null default 0 check (total_xcd >= 0),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists orders_consumer_idx on public.orders(consumer_id);
create index if not exists orders_vendor_idx on public.orders(vendor_id);
drop trigger if exists trg_orders_updated on public.orders;
create trigger trg_orders_updated before update on public.orders
  for each row execute function public.set_updated_at();

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  unit_price_xcd numeric(10,2) not null check (unit_price_xcd >= 0),
  quantity integer not null check (quantity > 0)
);
create index if not exists order_items_order_idx on public.order_items(order_id);

-- ---------- Row Level Security ----------
alter table public.profiles    enable row level security;
alter table public.vendors     enable row level security;
alter table public.products    enable row level security;
alter table public.orders      enable row level security;
alter table public.order_items enable row level security;

-- profiles: own row only (admin can read/update all)
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert
  with check (id = auth.uid() and role in ('consumer','vendor'));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

-- vendors: public read; owner writes own
drop policy if exists vendors_select on public.vendors;
create policy vendors_select on public.vendors for select using (true);
drop policy if exists vendors_insert on public.vendors;
create policy vendors_insert on public.vendors for insert
  with check (owner_id = auth.uid() or public.is_admin());
drop policy if exists vendors_update on public.vendors;
create policy vendors_update on public.vendors for update
  using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());
drop policy if exists vendors_delete on public.vendors;
create policy vendors_delete on public.vendors for delete
  using (owner_id = auth.uid() or public.is_admin());

-- products: public reads active ones; owner sees/edits all of their own
drop policy if exists products_select on public.products;
create policy products_select on public.products for select
  using (active or public.is_admin()
         or exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()));
drop policy if exists products_insert on public.products;
create policy products_insert on public.products for insert
  with check (public.is_admin()
         or exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()));
drop policy if exists products_update on public.products;
create policy products_update on public.products for update
  using (public.is_admin()
         or exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()))
  with check (public.is_admin()
         or exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()));
drop policy if exists products_delete on public.products;
create policy products_delete on public.products for delete
  using (public.is_admin()
         or exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()));

-- orders (stub): consumer sees own; vendor sees orders for own business. Writes come later (checkout step).
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select
  using (consumer_id = auth.uid() or public.is_admin()
         or exists (select 1 from public.vendors v where v.id = vendor_id and v.owner_id = auth.uid()));
drop policy if exists order_items_select on public.order_items;
create policy order_items_select on public.order_items for select
  using (exists (select 1 from public.orders o where o.id = order_id
         and (o.consumer_id = auth.uid() or public.is_admin()
              or exists (select 1 from public.vendors v where v.id = o.vendor_id and v.owner_id = auth.uid()))));

-- ---------- grants (anon = not logged in, authenticated = logged in) ----------
grant usage on schema public to anon, authenticated;
grant select on public.vendors, public.products to anon;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.vendors, public.products to authenticated;
grant select on public.orders, public.order_items to authenticated;
