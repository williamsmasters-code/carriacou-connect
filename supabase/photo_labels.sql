-- Carriacou Connect v1.19.1: photo labels ('Real photo' / 'Stock photo') replace the mandatory real-photos tick.
-- Run AFTER supabase/reviews.sql. Idempotent: safe to run more than once.
--   * product_images.photo_label ('real' | 'stock', default 'stock') + photo_labeled_at / photo_labeled_by (time and person who chose it)
--   * Existing photos: confirmed under the old tick -> 'real' (time = old confirmation time); everything else stays 'stock'.
--   * CSV import / any insert that does not go through the label RPC -> 'stock' until the vendor relabels it (closes the unconfirmed-photo gap).
--   * products.image_label mirrors the cover photo's label for product cards; kept by triggers, cannot be set by hand.
--   * set_product_photos_labeled(product, [{url,label}], exif): every photo must carry a label; replaces set_product_photos_confirmed.
--   * Report reason 'label_mismatch' = "Photo labelled real but isn't / doesn't match". admin_photo_relabel lets the admin relabel.

alter table public.product_images add column if not exists photo_label text not null default 'stock';
alter table public.product_images add column if not exists photo_labeled_at timestamptz;
alter table public.product_images add column if not exists photo_labeled_by uuid;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'product_images_photo_label_chk') then
    alter table public.product_images add constraint product_images_photo_label_chk check (photo_label in ('real','stock'));
  end if;
end $$;
-- one-off migration (only rows never labelled): old confirmed photos become 'real', the rest stay 'stock'
update public.product_images set photo_label = 'real', photo_labeled_at = real_photo_confirmed_at, photo_labeled_by = real_photo_confirmed_by
 where photo_labeled_at is null and real_photo_confirmed_at is not null;

alter table public.products add column if not exists image_label text not null default 'stock';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'products_image_label_chk') then
    alter table public.products add constraint products_image_label_chk check (image_label in ('real','stock'));
  end if;
end $$;

-- products.image_label is always derived from the cover photo (a vendor cannot write 'real' by hand)
create or replace function public.products_image_label_sync() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.image_label := coalesce((select i.photo_label from public.product_images i where i.product_id = new.id and i.url = new.image_url and i.hidden_at is null limit 1), 'stock');
  return new;
end $$;
revoke all on function public.products_image_label_sync() from public, anon, authenticated;
drop trigger if exists trg_products_image_label on public.products;
create trigger trg_products_image_label before insert or update on public.products for each row execute function public.products_image_label_sync();

create or replace function public.product_images_label_touch() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid := coalesce(new.product_id, old.product_id); want text;
begin
  select coalesce((select i.photo_label from public.product_images i where i.product_id = p.id and i.url = p.image_url and i.hidden_at is null limit 1), 'stock')
    into want from public.products p where p.id = pid;
  if want is not null then
    update public.products set image_label = want where id = pid and image_label is distinct from want;
  end if;
  return null;
end $$;
revoke all on function public.product_images_label_touch() from public, anon, authenticated;
drop trigger if exists trg_product_images_label on public.product_images;
create trigger trg_product_images_label after insert or update or delete on public.product_images for each row execute function public.product_images_label_touch();
update public.products p set image_label = coalesce((select i.photo_label from public.product_images i where i.product_id = p.id and i.url = p.image_url and i.hidden_at is null limit 1), 'stock');

-- vendor save: p_photos = [{"url": "...", "label": "real"|"stock"}, ...] in display order. Every photo needs a label.
create or replace function public.set_product_photos_labeled(p_product uuid, p_photos jsonb, p_exif jsonb default '[]'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; res jsonb; urls jsonb; e jsonb;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select p.vendor_id into v from public.products p where p.id = p_product;
  if v is null or not (public.is_admin() or public.vendor_perm(v, 'products_edit')) then raise exception 'Product not found'; end if;
  if p_photos is null or jsonb_typeof(p_photos) <> 'array' then raise exception 'Photos must be a list'; end if;
  for e in select * from jsonb_array_elements(p_photos) loop
    if jsonb_typeof(e) <> 'object' or jsonb_typeof(e->'url') <> 'string' then raise exception 'Each photo needs a link'; end if;
    if coalesce(e->>'label','') not in ('real','stock') then
      raise exception 'Choose "Real photo" or "Stock photo" for every photo before saving.';
    end if;
  end loop;
  select coalesce(jsonb_agg(x->'url' order by o), '[]'::jsonb) into urls from jsonb_array_elements(p_photos) with ordinality t(x, o);
  if exists (select 1 from jsonb_array_elements_text(urls) u(url) join public.product_images i on i.product_id = p_product and i.url = u.url and i.hidden_at is not null) then
    raise exception 'A photo removed by Carriacou Connect cannot be added back. Use a different photo.';
  end if;
  res := public.set_product_photos(p_product, urls);
  update public.product_images i set photo_label = x.label, photo_labeled_at = now(), photo_labeled_by = auth.uid(),
         exif_camera = case when x.label = 'real' then (select case when jsonb_typeof(q->'camera') = 'boolean' then (q->>'camera')::boolean end
                          from jsonb_array_elements(case when jsonb_typeof(p_exif) = 'array' then p_exif else '[]'::jsonb end) q where q->>'url' = i.url limit 1) end
    from (select t->>'url' url, t->>'label' label from jsonb_array_elements(p_photos) t) x
   where i.product_id = p_product and i.url = x.url and (i.photo_label is distinct from x.label or i.photo_labeled_at is null);
  return res || jsonb_build_object(
    'real', (select count(*) from public.product_images where product_id = p_product and photo_label = 'real'),
    'stock', (select count(*) from public.product_images where product_id = p_product and photo_label = 'stock'),
    'no_camera_data', (select count(*) from public.product_images where product_id = p_product and photo_label = 'real' and exif_camera is false));
end $$;
revoke all on function public.set_product_photos_labeled(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.set_product_photos_labeled(uuid, jsonb, jsonb) to authenticated;
-- the tick-box save is retired
revoke execute on function public.set_product_photos_confirmed(uuid, jsonb, boolean, jsonb) from authenticated;

alter table public.vendor_notices drop constraint if exists vendor_notices_kind_check;
alter table public.vendor_notices add constraint vendor_notices_kind_check check (kind in ('photo_hidden','listing_hidden','photo_report_dismissed','review_hidden','photo_relabelled'));

-- report reason: label_mismatch = "Photo labelled real but isn't / doesn't match" (photo_mismatch kept for old rows)
alter table public.listing_reports drop constraint if exists listing_reports_reason_check;
alter table public.listing_reports add constraint listing_reports_reason_check check (reason in ('label_mismatch','photo_mismatch','other'));

create or replace function public.report_listing(p_product uuid, p_reason text, p_note text default null, p_image_url text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid := auth.uid(); v uuid; n text := public._rv_clean(p_note, 300);
begin
  if u is null then raise exception 'Please log in to report a listing'; end if;
  if p_reason not in ('label_mismatch','other') then raise exception 'Choose a reason'; end if;
  if p_reason = 'other' and (n is null or length(n) < 3) then raise exception 'Tell us what is wrong (at least 3 characters)'; end if;
  perform public._rv_noimg(n);
  select vendor_id into v from public.products where id = p_product and active;
  if v is null then raise exception 'Listing not found'; end if;
  if exists (select 1 from public.listing_reports where product_id = p_product and user_id = u) then raise exception 'You have already reported this listing'; end if;
  if (select count(*) from public.review_reports where user_id = u and created_at > now() - interval '1 day')
   + (select count(*) from public.listing_reports where user_id = u and created_at > now() - interval '1 day') >= 10 then
    raise exception 'You have sent many reports today. Please try again tomorrow.'; end if;
  insert into public.listing_reports(product_id, vendor_id, user_id, reason, note, image_url)
    values (p_product, v, u, p_reason, n, case when exists (select 1 from public.product_images where product_id = p_product and url = p_image_url) then p_image_url end);
  return jsonb_build_object('reported', true);
end $$;

create or replace function public.admin_listing_queue(p_filter text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Only the platform admin can moderate listings'; end if;
  return jsonb_build_object('open', (select count(distinct product_id) from public.listing_reports where status = 'open'),
   'items', coalesce((select jsonb_agg(x order by x->>'last_report' desc) from (
     select jsonb_build_object('product_id', p.id, 'product_name', p.name, 'vendor_id', v.id, 'vendor_name', v.name, 'active', p.active,
       'admin_hidden', p.admin_hidden_at is not null,
       'images', coalesce((select jsonb_agg(jsonb_build_object('url', i.url, 'hidden', i.hidden_at is not null, 'label', i.photo_label,
                  'labeled_at', i.photo_labeled_at, 'exif_camera', i.exif_camera) order by i.position) from public.product_images i where i.product_id = p.id), '[]'::jsonb),
       'reports', (select jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'note', r.note, 'image_url', r.image_url, 'status', r.status, 'at', r.created_at) order by r.id desc)
                   from public.listing_reports r where r.product_id = p.id),
       'open_reports', (select count(*) from public.listing_reports r where r.product_id = p.id and r.status = 'open'),
       'last_report', (select max(created_at) from public.listing_reports r where r.product_id = p.id)) x
     from public.products p join public.vendors v on v.id = p.vendor_id
     where exists (select 1 from public.listing_reports r where r.product_id = p.id and (coalesce(p_filter,'open') = 'all' or r.status = 'open'))
     limit 200) s), '[]'::jsonb));
end $$;

-- p_action: hide_image (needs p_image_url) | hide_listing | dismiss. p_note is shown to the vendor.
create or replace function public.admin_listing_moderate(p_product uuid, p_action text, p_image_url text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare p record; n text := public._rv_clean(p_note, 300); nxt text;
begin
  if not public.is_admin() then raise exception 'Only the platform admin can moderate listings'; end if;
  if p_action not in ('hide_image','hide_listing','dismiss') then raise exception 'Unknown action'; end if;
  select * into p from public.products where id = p_product for update;
  if not found then raise exception 'Listing not found'; end if;
  if p_action <> 'dismiss' and (n is null or length(n) < 3) then raise exception 'Write a note to the vendor (at least 3 characters)'; end if;
  perform set_config('cc.admin_mod', '1', true);
  if p_action = 'hide_image' then
    if not exists (select 1 from public.product_images where product_id = p_product and url = p_image_url) then raise exception 'Choose which photo to hide'; end if;
    update public.product_images set hidden_at = now(), hidden_reason = n where product_id = p_product and url = p_image_url;
    if p.image_url = p_image_url then
      select url into nxt from public.product_images where product_id = p_product and hidden_at is null order by position limit 1;
      update public.products set image_url = nxt where id = p_product;
    end if;
    insert into public.vendor_notices(vendor_id, product_id, kind, message) values (p.vendor_id, p_product, 'photo_hidden',
      'A photo of "' || left(p.name, 120) || '" was hidden because its label or content did not match the listing (photo labelling rule). ' || n);
  elsif p_action = 'hide_listing' then
    update public.products set active = false, admin_hidden_at = now(), admin_hidden_reason = n where id = p_product;
    insert into public.vendor_notices(vendor_id, product_id, kind, message) values (p.vendor_id, p_product, 'listing_hidden',
      'Your listing "' || left(p.name, 120) || '" was hidden under the photo labelling rule. ' || n);
  else
    if n is not null then insert into public.vendor_notices(vendor_id, product_id, kind, message) values (p.vendor_id, p_product, 'photo_report_dismissed',
      'A photo report on "' || left(p.name, 120) || '" was checked and closed. ' || n); end if;
  end if;
  update public.listing_reports set status = 'resolved', resolution = p_action where product_id = p_product and status = 'open';
  return jsonb_build_object('product_id', p_product, 'action', p_action);
end $$;

-- admin relabels one photo (e.g. 'real' -> 'stock' after a report). Optional note is shown in the vendor's dashboard.
create or replace function public.admin_photo_relabel(p_product uuid, p_image_url text, p_label text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare nm text; v uuid; n text := public._rv_clean(p_note, 300);
begin
  if not public.is_admin() then raise exception 'Only the platform admin can relabel photos'; end if;
  if p_label not in ('real','stock') then raise exception 'Label must be Real photo or Stock photo'; end if;
  select name, vendor_id into nm, v from public.products where id = p_product;
  if v is null then raise exception 'Listing not found'; end if;
  update public.product_images set photo_label = p_label, photo_labeled_at = now(), photo_labeled_by = auth.uid()
   where product_id = p_product and url = p_image_url;
  if not found then raise exception 'Choose which photo to relabel'; end if;
  insert into public.vendor_notices(vendor_id, product_id, kind, message) values (v, p_product, 'photo_relabelled',
    'A photo of "' || left(nm, 120) || '" was relabelled "' || case p_label when 'real' then 'Real photo' else 'Stock photo' end || '" by Carriacou Connect.' || coalesce(' ' || n, ''));
  return jsonb_build_object('product_id', p_product, 'label', p_label);
end $$;
revoke all on function public.admin_photo_relabel(uuid, text, text, text) from public, anon;
grant execute on function public.admin_photo_relabel(uuid, text, text, text) to authenticated;

-- vendor notices: stock-labelled count replaces the old "unconfirmed" count; camera hint counts only photos marked Real
create or replace function public.vendor_notices_list(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if public.vendor_role(p_vendor) is null and not public.is_admin() then raise exception 'Business not found'; end if;
  return jsonb_build_object(
    'notices', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'message', message, 'product_id', product_id, 'at', created_at, 'read', read_at is not null) order by id desc)
                from (select * from public.vendor_notices where vendor_id = p_vendor order by id desc limit 30) n), '[]'::jsonb),
    'unconfirmed_photos', 0,
    'stock_default_photos', (select count(*) from public.product_images i join public.products p on p.id = i.product_id where p.vendor_id = p_vendor and i.photo_labeled_at is null and i.hidden_at is null),
    'no_camera_data', (select count(*) from public.product_images i join public.products p on p.id = i.product_id where p.vendor_id = p_vendor and i.photo_label = 'real' and i.exif_camera is false and i.hidden_at is null));
end $$;

notify pgrst, 'reload schema';
