-- v1.17 shop layout switch: each shop uses the DEFAULT layout unless the platform admin sets a CUSTOM one.
-- Custom layouts are bespoke builds by Carriacou Connect (paid service), served from /custom/<slug>/layout.js (+ optional layout.css).
-- Run AFTER wallet_repurpose.sql. Idempotent: safe to run more than once. Vendors cannot change this (no write grants; admin RPC only).
create table if not exists public.vendor_layouts (
  vendor_id   uuid primary key references public.vendors(id) on delete cascade,
  layout_mode text not null default 'default' check (layout_mode in ('default','custom')),
  layout_slug text check (layout_slug is null or layout_slug ~ '^[a-z0-9][a-z0-9-]{0,47}$'),
  note        text check (note is null or length(note) <= 300),
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
alter table public.vendor_layouts drop constraint if exists vendor_layouts_custom_slug_ck;
alter table public.vendor_layouts add constraint vendor_layouts_custom_slug_ck check (layout_mode = 'default' or layout_slug is not null);
alter table public.vendor_layouts enable row level security;
drop policy if exists vendor_layouts_read on public.vendor_layouts;
create policy vendor_layouts_read on public.vendor_layouts for select to anon, authenticated using (true);  -- shop pages are public
revoke insert, update, delete, truncate on public.vendor_layouts from public, anon, authenticated;
grant select on public.vendor_layouts to anon, authenticated;

create or replace function public.shop_layout(p_vendor uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select jsonb_build_object('mode', l.layout_mode, 'slug', l.layout_slug) from public.vendor_layouts l where l.vendor_id = p_vendor),
                  jsonb_build_object('mode', 'default', 'slug', null));
$$;
revoke all on function public.shop_layout(uuid) from public;
grant execute on function public.shop_layout(uuid) to anon, authenticated;

create or replace function public.admin_set_vendor_layout(p_vendor uuid, p_mode text, p_slug text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare s text := nullif(lower(btrim(coalesce(p_slug, ''))), '');
begin
  if not public.is_admin() then raise exception 'Only the platform admin can change a shop layout'; end if;
  if not exists (select 1 from public.vendors where id = p_vendor) then raise exception 'Shop not found'; end if;
  if p_mode not in ('default','custom') then raise exception 'Layout must be default or custom'; end if;
  if p_mode = 'custom' and s is null then raise exception 'Enter the custom layout key (folder name under /custom/)'; end if;
  if s is not null and s !~ '^[a-z0-9][a-z0-9-]{0,47}$' then raise exception 'Layout key: lowercase letters, numbers and dashes only'; end if;
  insert into public.vendor_layouts(vendor_id, layout_mode, layout_slug, note, updated_at, updated_by)
    values (p_vendor, p_mode, s, nullif(btrim(coalesce(p_note, '')), ''), now(), auth.uid())
  on conflict (vendor_id) do update set layout_mode = excluded.layout_mode, layout_slug = excluded.layout_slug,
    note = excluded.note, updated_at = now(), updated_by = excluded.updated_by;
  return public.shop_layout(p_vendor);
end $$;
revoke all on function public.admin_set_vendor_layout(uuid, text, text, text) from public, anon;
grant execute on function public.admin_set_vendor_layout(uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';
