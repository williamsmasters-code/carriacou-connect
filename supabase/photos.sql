-- Carriacou Connect v1.0 : multiple product photos per plan + bulk product upload.
-- Run this whole file once in Supabase Dashboard > SQL Editor, AFTER schema.sql, seed.sql, orders.sql, order_notes.sql,
-- pay.sql, analytics.sql, staff.sql (and storage.sql, which creates the product-images bucket). Safe to re-run.
-- If you ever re-run staff.sql / storage.sql / schema.sql afterwards, run photos.sql again (they put the older
-- vendor_plan(), enforce_product_limit() and storage rules back).
-- Supabase runs pg-safeupdate: every UPDATE and DELETE below has a WHERE clause.
--
-- What this adds
--   * tier_limits.max_photos : Lite 1, Standard 1, Plus+ 3, Pro 3, Enterprise 5 photos per product
--   * product_images table (RLS: public reads photos of visible products; owner and members with products_edit write)
--   * a trigger that refuses a photo beyond the plan's limit. Downgrades KEEP existing photos but block adding more.
--   * products.image_url stays as the cover photo (always = photo at position 0), so old code keeps working
--   * products.sku (optional, unique per business, not case sensitive)
--   * set_product_photos(product, urls) : replace/reorder a product's photos in one call
--   * bulk_upsert_products(vendor, rows, mode, dry_run) : set-based CSV import, tier cap enforced under a lock
--   * the product cap check now takes a per-business lock, so concurrent adds cannot overshoot the cap
--   * storage rules: owner AND team members with products_edit may upload into the owner's folder

-- =====================================================================================================
-- 1. Photos per product per tier
-- =====================================================================================================
alter table public.tier_limits add column if not exists max_photos integer not null default 1;
alter table public.tier_limits drop constraint if exists tier_limits_max_photos_check;
alter table public.tier_limits add constraint tier_limits_max_photos_check check (max_photos between 1 and 20);
update public.tier_limits set max_photos = 1 where tier in ('lite','standard');
update public.tier_limits set max_photos = 3 where tier in ('plus','pro');
update public.tier_limits set max_photos = 5 where tier = 'enterprise';

create or replace function public.tier_photo_limit(t text) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select max_photos from public.tier_limits where tier = t), 1);
$$;
revoke all on function public.tier_photo_limit(text) from public;
grant execute on function public.tier_photo_limit(text) to anon, authenticated;

-- =====================================================================================================
-- 2. products: sku + lookup indexes, and a race-safe product cap
-- =====================================================================================================
alter table public.products add column if not exists sku text;
alter table public.products drop constraint if exists products_sku_check;
alter table public.products add constraint products_sku_check
  check (sku is null or (char_length(sku) between 1 and 64 and sku !~ '[[:cntrl:]]'));
create unique index if not exists products_vendor_sku_uq on public.products (vendor_id, lower(sku)) where sku is not null;
create index if not exists products_vendor_lname_idx on public.products (vendor_id, lower(name));

-- same rule as schema.sql (counts ALL of a business's products) plus a per-business lock so two
-- concurrent inserts (or import batches) cannot both slip under the cap.
create or replace function public.enforce_product_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim integer; cnt integer; t text;
begin
  select tier into t from public.vendors where id = new.vendor_id;
  lim := public.tier_limit(t);
  if lim is not null then
    perform pg_advisory_xact_lock(hashtextextended('cc:products:' || new.vendor_id::text, 0));
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

-- =====================================================================================================
-- 3. product_images
-- =====================================================================================================
create table if not exists public.product_images (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  url        text not null check (char_length(url) <= 2000 and url ~* '^https?://[^[:space:]]+$'),
  position   integer not null check (position between 0 and 99),
  created_at timestamptz not null default now(),
  constraint product_images_pos_uq unique (product_id, position) deferrable initially deferred
);
create unique index if not exists product_images_product_url_uq on public.product_images (product_id, url);
create index if not exists product_images_product_idx on public.product_images (product_id, position);

-- per-plan limit. Counts existing photos under a per-product lock, so concurrent uploads cannot overshoot.
create or replace function public.enforce_photo_limit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare lim integer; cnt integer; t text; tl text; v uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('cc:photos:' || new.product_id::text, 0));
  select p.vendor_id into v from public.products p where p.id = new.product_id;
  -- BEFORE triggers run ahead of row-level security: refuse outsiders here so they learn nothing about the product
  if auth.uid() is not null and not (public.is_admin() or public.vendor_perm(v, 'products_edit')) then
    raise exception 'new row violates row-level security policy for table "product_images"' using errcode = '42501';
  end if;
  select tier into t from public.vendors where id = v;
  lim := public.tier_photo_limit(t);
  select count(*) into cnt from public.product_images i
    where i.product_id = new.product_id and (tg_op = 'INSERT' or i.id <> new.id);
  if cnt >= lim then
    select coalesce(label, t) into tl from public.tier_limits where tier = t;
    raise exception 'Photo limit reached: the % plan allows % photo(s) per product', coalesce(tl, t), lim
      using errcode = 'check_violation';
  end if;
  if new.position is null then
    select coalesce(max(i.position) + 1, 0) into new.position from public.product_images i where i.product_id = new.product_id;
  end if;
  return new;
end $$;
revoke all on function public.enforce_photo_limit() from public, anon, authenticated;
drop trigger if exists trg_product_images_limit on public.product_images;
create trigger trg_product_images_limit before insert or update of product_id on public.product_images
  for each row execute function public.enforce_photo_limit();

-- products.image_url = the cover = the photo with the lowest position
create or replace function public.product_images_sync_cover() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid := coalesce(new.product_id, old.product_id); cover text;
begin
  if coalesce(current_setting('cc.skip_img_sync', true), '') = '1' then return null; end if;
  select i.url into cover from public.product_images i where i.product_id = pid order by i.position, i.created_at, i.id limit 1;
  update public.products p set image_url = cover where p.id = pid and p.image_url is distinct from cover;
  return null;
end $$;
revoke all on function public.product_images_sync_cover() from public, anon, authenticated;
drop trigger if exists trg_product_images_cover on public.product_images;
create trigger trg_product_images_cover after insert or update of url, position or delete on public.product_images
  for each row execute function public.product_images_sync_cover();

-- Someone (an older page, the SQL editor) wrote products.image_url directly: keep product_images in step.
create or replace function public.products_sync_cover_image() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare first_id uuid;
begin
  if pg_trigger_depth() > 1 or coalesce(current_setting('cc.skip_img_sync', true), '') = '1' then return null; end if;
  if tg_op = 'UPDATE' and new.image_url is not distinct from old.image_url then return null; end if;
  select i.id into first_id from public.product_images i where i.product_id = new.id order by i.position, i.created_at, i.id limit 1;
  if new.image_url is null then
    if first_id is not null then delete from public.product_images where id = first_id; end if;
  elsif new.image_url ~* '^https?://[^[:space:]]+$' and char_length(new.image_url) <= 2000 then
    if exists (select 1 from public.product_images i where i.product_id = new.id and i.url = new.image_url) then
      update public.product_images set position = position + 1 where product_id = new.id and url <> new.image_url;
      update public.product_images set position = 0 where product_id = new.id and url = new.image_url;
      update public.product_images i set position = r.rn - 1
        from (select x.id, row_number() over (order by x.position, x.created_at, x.id) as rn from public.product_images x where x.product_id = new.id) r
       where i.id = r.id and i.position <> r.rn - 1;
    elsif first_id is not null then
      update public.product_images set url = new.image_url where id = first_id;
    else
      insert into public.product_images (product_id, url, position) values (new.id, new.image_url, 0);
    end if;
  end if;
  return null;
end $$;
revoke all on function public.products_sync_cover_image() from public, anon, authenticated;
drop trigger if exists trg_products_cover_image on public.products;
create trigger trg_products_cover_image after insert or update of image_url on public.products
  for each row execute function public.products_sync_cover_image();

-- existing single photos become photo 1 (only real http(s) links; anything else is left in image_url untouched)
do $$
begin
  perform set_config('cc.skip_img_sync', '1', true);
  insert into public.product_images (product_id, url, position)
  select p.id, p.image_url, 0 from public.products p
   where p.image_url ~* '^https?://[^[:space:]]+$' and char_length(p.image_url) <= 2000
     and not exists (select 1 from public.product_images i where i.product_id = p.id);
  perform set_config('cc.skip_img_sync', '', true);
end $$;

-- ---- RLS: reading follows product visibility (the products policies decide); writing needs products_edit ----
alter table public.product_images enable row level security;
drop policy if exists product_images_select on public.product_images;
create policy product_images_select on public.product_images for select
  using (exists (select 1 from public.products p where p.id = product_id));
drop policy if exists product_images_insert on public.product_images;
create policy product_images_insert on public.product_images for insert
  with check (public.is_admin() or exists (select 1 from public.products p where p.id = product_id and public.vendor_perm(p.vendor_id, 'products_edit')));
drop policy if exists product_images_update on public.product_images;
create policy product_images_update on public.product_images for update
  using (public.is_admin() or exists (select 1 from public.products p where p.id = product_id and public.vendor_perm(p.vendor_id, 'products_edit')))
  with check (public.is_admin() or exists (select 1 from public.products p where p.id = product_id and public.vendor_perm(p.vendor_id, 'products_edit')));
drop policy if exists product_images_delete on public.product_images;
create policy product_images_delete on public.product_images for delete
  using (public.is_admin() or exists (select 1 from public.products p where p.id = product_id and public.vendor_perm(p.vendor_id, 'products_edit')));
revoke all on public.product_images from public, anon, authenticated;
grant select on public.product_images to anon, authenticated;
grant insert, update, delete on public.product_images to authenticated;

-- ---- set_product_photos: make a product's photos exactly this ordered list of links (adds, removes, reorders) ----
-- Existing photos that stay keep their row. Adding beyond the plan limit fails (trigger). After a downgrade a product
-- may keep more photos than the plan allows; it can reorder or remove them, but not add until it is under the limit.
create or replace function public.set_product_photos(p_product uuid, p_urls jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; urls text[]; n integer;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select p.vendor_id into v from public.products p where p.id = p_product;
  if v is null or not (public.is_admin() or public.vendor_perm(v, 'products_edit')) then
    raise exception 'Product not found';
  end if;
  if p_urls is null or jsonb_typeof(p_urls) <> 'array' then raise exception 'Photos must be a list of links'; end if;
  if jsonb_array_length(p_urls) > 20 then raise exception 'Too many photos'; end if;
  if exists (select 1 from jsonb_array_elements(p_urls) e where jsonb_typeof(e) <> 'string') then raise exception 'Photos must be a list of links'; end if;
  -- de-duplicate, keep order
  select coalesce(array_agg(u order by o), array[]::text[]) into urls
    from (select e.u, min(e.o) as o from (select x.value #>> '{}' as u, x.ordinality as o from jsonb_array_elements(p_urls) with ordinality x) e group by e.u) d;
  if exists (select 1 from unnest(urls) u where u !~* '^https?://[^[:space:]]+$' or char_length(u) > 2000) then
    raise exception 'Each photo must be a web link starting with http:// or https://';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cc:photos:' || p_product::text, 0));
  delete from public.product_images where product_id = p_product and url <> all (urls);
  update public.product_images i set position = u.o - 1
    from unnest(urls) with ordinality u(url, o)
   where i.product_id = p_product and i.url = u.url and i.position <> u.o - 1;
  insert into public.product_images (product_id, url, position)
  select p_product, u.url, u.o - 1 from unnest(urls) with ordinality u(url, o)
   where not exists (select 1 from public.product_images i where i.product_id = p_product and i.url = u.url)
   order by u.o;
  select count(*) into n from public.product_images where product_id = p_product;
  return jsonb_build_object('ok', true, 'count', n, 'cover', (select p.image_url from public.products p where p.id = p_product));
end $$;
revoke all on function public.set_product_photos(uuid, jsonb) from public, anon;
grant execute on function public.set_product_photos(uuid, jsonb) to authenticated;

-- ---- plan summary now also reports the photo limit and how many products are over it ----
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
    'limits', jsonb_build_object('max_staff', coalesce(o.max_staff, t.max_staff), 'max_subadmins', coalesce(o.max_subadmins, t.max_subadmins),
                                 'max_products', t.max_products, 'max_photos', t.max_photos),
    'overridden', o.vendor_id is not null,
    'usage', jsonb_build_object('staff', public._seat_used(p_vendor, 'staff'), 'subadmins', public._seat_used(p_vendor, 'subadmin'),
        'pending_staff', public._seat_used(p_vendor, 'staff', true) - public._seat_used(p_vendor, 'staff'),
        'pending_subadmins', public._seat_used(p_vendor, 'subadmin', true) - public._seat_used(p_vendor, 'subadmin'),
        'products', (select count(*) from public.products where vendor_id = p_vendor),
        'products_over_photo_limit', (select count(*) from (
            select i.product_id from public.product_images i join public.products pp on pp.id = i.product_id
             where pp.vendor_id = p_vendor group by i.product_id having count(*) > t.max_photos) s)),
    'next_tier', nxt.tier,
    'pending_request', case when req.id is null then null else jsonb_build_object('id', req.id, 'to_tier', req.to_tier, 'created_at', req.created_at, 'note', req.note) end);
end $$;
revoke all on function public.vendor_plan(uuid) from public, anon;
grant execute on function public.vendor_plan(uuid) to authenticated;

-- =====================================================================================================
-- 4. bulk_upsert_products
-- =====================================================================================================
-- p_rows : array (max 500 per call) of objects with keys row (the line number shown to the user), sku, name, description,
--          category, price_xcd, stock_qty, low_stock_threshold, cost_price, active, image_url (all text/number, all optional but
--          name, category, price_xcd).
-- p_mode : 'add'    = add new products only; rows that already exist (same sku, or same name when no sku) are skipped
--          'update' = update existing products only (matched by sku, else name); unknown rows are skipped
--          'upsert' = update existing and add new
-- p_dry_run : true = validate and report what WOULD happen, change nothing
-- On update, blank optional cells keep the current value. Returns {created, updated, skipped, errors, cap, results[]}.
create or replace function public.bulk_upsert_products(p_vendor uuid, p_rows jsonb, p_mode text default 'add', p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  lim integer; cnt integer; room integer; t text; tl text; has_cost boolean; n integer;
  c_created integer; c_updated integer; c_skipped integer; c_errors integer; res jsonb;
  cats constant text[] := array['food','crafts','fashion','beauty','sea','home'];
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_mode is null or p_mode not in ('add','update','upsert') then raise exception 'Unknown import mode'; end if;
  if not public.vendor_perm(p_vendor, 'products_edit') then
    raise exception 'You do not have permission to change products for this business';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Rows must be a list'; end if;
  n := jsonb_array_length(p_rows);
  if n = 0 then raise exception 'There are no rows to import'; end if;
  if n > 500 then raise exception 'Send at most 500 rows at a time (got %)', n; end if;

  perform pg_advisory_xact_lock(hashtextextended('cc:products:' || p_vendor::text, 0));
  select v.tier into t from public.vendors v where v.id = p_vendor;
  lim := public.tier_limit(t);
  select coalesce(label, t) into tl from public.tier_limits where tier = t;
  select count(*) into cnt from public.products where vendor_id = p_vendor;
  has_cost := exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name = 'cost_price');

  drop table if exists pg_temp.bu_rows;
  create temp table bu_rows (
    idx integer primary key, rownum integer,
    r_sku text, r_name text, r_desc text, r_cat text, r_price text, r_stock text, r_thr text, r_cost text, r_act text, r_img text,
    is_obj boolean,
    sku text, name text, descr text, cat text, price numeric, stock integer, thr integer, cost numeric, act boolean, img text,
    err text, code text, warn text, dkey text, pid uuid, new_id uuid, action text, status text, msg text
  ) on commit drop;

  insert into bu_rows (idx, rownum, r_sku, r_name, r_desc, r_cat, r_price, r_stock, r_thr, r_cost, r_act, r_img, is_obj)
  select e.ord::integer,
         case when (e.v ->> 'row') ~ '^[0-9]{1,9}$' then (e.v ->> 'row')::integer else e.ord::integer end,
         btrim(e.v ->> 'sku'), btrim(e.v ->> 'name'), e.v ->> 'description', lower(btrim(e.v ->> 'category')),
         btrim(e.v ->> 'price_xcd'), btrim(e.v ->> 'stock_qty'), btrim(e.v ->> 'low_stock_threshold'), btrim(e.v ->> 'cost_price'),
         lower(btrim(e.v ->> 'active')), btrim(e.v ->> 'image_url'), jsonb_typeof(e.v) = 'object'
    from jsonb_array_elements(p_rows) with ordinality as e(v, ord);

  -- 1. typed values (only cast what looks valid; errors are reported below)
  update bu_rows set
    sku  = nullif(r_sku, ''), name = r_name, descr = nullif(r_desc, ''), cat = r_cat,
    price = case when r_price ~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' then r_price::numeric end,
    stock = case when r_stock ~ '^[0-9]{1,7}$' then r_stock::integer end,
    thr   = case when r_thr ~ '^[0-9]{1,7}$' then r_thr::integer end,
    cost  = case when r_cost ~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' then r_cost::numeric end,
    act   = case when r_act in ('true','yes','y','1','active') then true when r_act in ('false','no','n','0','hidden','inactive') then false end,
    img   = nullif(r_img, '')
  where idx > 0;

  -- 2. validation, first problem wins
  update bu_rows set err = case
      when not is_obj then 'This row is not valid'
      when name is null or char_length(name) < 2 or char_length(name) > 120 then 'Name must be 2 to 120 characters'
      when descr is not null and char_length(descr) > 1000 then 'Description is longer than 1000 characters'
      when cat is null or cat <> all (cats) then 'Category must be one of: food, crafts, fashion, beauty, sea, home'
      when r_price is null or r_price = '' then 'Price is required'
      when price is null then 'Price must be a number like 12.50 (up to 2 decimals)'
      when price > 1000000 then 'Price is over EC$1,000,000'
      when r_stock is not null and r_stock <> '' and (stock is null or stock > 1000000) then 'Stock must be a whole number from 0 to 1,000,000'
      when r_thr is not null and r_thr <> '' and (thr is null or thr > 1000000) then 'Low-stock level must be a whole number from 0 to 1,000,000'
      when r_cost is not null and r_cost <> '' and (cost is null or cost > 1000000) then 'Cost price must be a number like 8.00 (up to 2 decimals)'
      when r_act is not null and r_act <> '' and act is null then 'Active must be yes or no'
      when sku is not null and (char_length(sku) > 64 or sku ~ '[[:cntrl:]]') then 'SKU must be 1 to 64 characters'
      when img is not null and (img !~* '^https://[^[:space:]]+$' or char_length(img) > 2000) then 'Image link must start with https://'
    end
  where idx > 0;

  -- 3. duplicates inside this batch: the first valid row wins
  update bu_rows set dkey = case when sku is not null then 's:' || lower(sku) else 'n:' || lower(name) end where err is null;
  update bu_rows b set err = 'Duplicate of row ' || d.first_row || ' in this upload', code = 'duplicate'
    from (select idx, first_value(rownum) over (partition by dkey order by idx) as first_row,
                 row_number() over (partition by dkey order by idx) as rn
            from bu_rows where err is null) d
   where b.idx = d.idx and d.rn > 1;

  -- 4. match existing products: by sku when given, otherwise by name
  update bu_rows b set pid = p.id
    from public.products p
   where b.err is null and b.sku is not null and p.vendor_id = p_vendor and lower(p.sku) = lower(b.sku);
  update bu_rows b set pid = m.pid, err = case when m.c > 1 then 'Several of your products are named "' || b.name || '": add a sku to pick one' end,
         code = case when m.c > 1 then 'ambiguous' end
    from (select lower(p.name) as ln, count(*) as c, (array_agg(p.id order by p.created_at, p.id))[1] as pid
            from public.products p where p.vendor_id = p_vendor group by lower(p.name)) m
   where b.err is null and b.sku is null and m.ln = lower(b.name);

  -- 5. decide
  update bu_rows set
    action = case when err is not null then null
                  when pid is not null and p_mode in ('update','upsert') then 'update'
                  when pid is null and p_mode in ('add','upsert') then 'create' end,
    status = case when err is not null then 'error'
                  when pid is not null and p_mode = 'add' then 'skipped'
                  when pid is null and p_mode = 'update' then 'skipped' end,
    msg = case when err is not null then err
               when pid is not null and p_mode = 'add' then 'Already in your catalog (matched by ' || case when sku is not null then 'sku' else 'name' end || '): skipped. Use update mode to change it.'
               when pid is null and p_mode = 'update' then 'Not found in your catalog (matched by ' || case when sku is not null then 'sku' else 'name' end || '): skipped.' end
  where idx > 0;

  -- 6. plan cap for NEW products, first rows win. Counts every product, hidden or not.
  if lim is not null then
    room := greatest(lim - cnt, 0);
    update bu_rows b set action = null, status = 'error', code = 'plan_limit',
           msg = 'Not added: the ' || tl || ' plan allows ' || lim || ' products and you have ' || cnt || '.'
      from (select idx, row_number() over (order by idx) as rn from bu_rows where action = 'create') c
     where b.idx = c.idx and c.rn > room;
  end if;

  -- 7. apply
  if not p_dry_run then
    perform set_config('cc.skip_img_sync', '1', true);
    update public.products p set
        name = b.name, category = b.cat, price_xcd = b.price,
        description = coalesce(b.descr, p.description),
        stock_qty = coalesce(b.stock, p.stock_qty),
        low_stock_threshold = coalesce(b.thr, p.low_stock_threshold),
        active = coalesce(b.act, p.active),
        sku = coalesce(b.sku, p.sku)
      from bu_rows b
     where b.action = 'update' and p.id = b.pid and p.vendor_id = p_vendor;
    update bu_rows set status = 'updated', msg = null where action = 'update';

    update bu_rows set new_id = gen_random_uuid() where action = 'create';
    with ins as (
      insert into public.products (id, vendor_id, name, description, price_xcd, category, image_url, active, sku, stock_qty, low_stock_threshold)
      select b.new_id, p_vendor, b.name, coalesce(b.descr, ''), b.price, b.cat, b.img, coalesce(b.act, true), b.sku, b.stock, coalesce(b.thr, 5)
        from bu_rows b where b.action = 'create' order by b.idx
      on conflict do nothing
      returning id)
    update bu_rows b set status = 'created' from ins where b.new_id = ins.id;
    update bu_rows set status = 'error', code = 'conflict', msg = 'Not added: another product already uses this sku.'
     where action = 'create' and status is null;

    -- cost price, only if the products table has the column (planned for the Standard analytics step)
    if has_cost then
      execute 'update public.products p set cost_price = b.cost from pg_temp.bu_rows b where p.id = coalesce(b.pid, b.new_id) and b.cost is not null and b.status in (''created'',''updated'') and p.vendor_id = $1' using p_vendor;
    end if;

    -- photo link: only for products that have no photos yet (cover = position 0)
    update public.products p set image_url = b.img
      from bu_rows b
     where b.status = 'updated' and b.img is not null and p.id = b.pid and p.vendor_id = p_vendor
       and not exists (select 1 from public.product_images i where i.product_id = p.id);
    insert into public.product_images (product_id, url, position)
    select coalesce(b.pid, b.new_id), b.img, 0 from bu_rows b
     where b.status in ('created','updated') and b.img is not null
       and not exists (select 1 from public.product_images i where i.product_id = coalesce(b.pid, b.new_id))
     order by b.idx;
    update bu_rows set msg = 'Updated. Image link ignored: this product already has photos (change them in the product editor).'
     where status = 'updated' and img is not null
       and exists (select 1 from public.product_images i where i.product_id = pid and i.url <> img)
       and not exists (select 1 from public.product_images i where i.product_id = pid and i.url = img);
    perform set_config('cc.skip_img_sync', '', true);
  else
    update bu_rows set status = case action when 'create' then 'created' else 'updated' end where action is not null;
  end if;

  -- notes
  update bu_rows set msg = coalesce(msg || ' ', '') || 'cost_price ignored (not supported yet).'
   where not has_cost and cost is not null and status in ('created','updated');

  select count(*) filter (where status = 'created'), count(*) filter (where status = 'updated'),
         count(*) filter (where status = 'skipped'), count(*) filter (where status = 'error')
    into c_created, c_updated, c_skipped, c_errors from bu_rows;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('row', rownum, 'status', status, 'message', msg, 'code', code,
           'id', case when status in ('created','updated') and not p_dry_run then coalesce(pid, new_id) end)) order by idx), '[]'::jsonb)
    into res from bu_rows;
  if not p_dry_run then
    perform public._audit(p_vendor, 'products_bulk', null, jsonb_build_object('mode', p_mode, 'created', c_created, 'updated', c_updated, 'skipped', c_skipped, 'errors', c_errors));
  end if;
  return jsonb_build_object('ok', true, 'mode', p_mode, 'dry_run', p_dry_run, 'created', c_created, 'updated', c_updated,
    'skipped', c_skipped, 'errors', c_errors,
    'cap', jsonb_build_object('limit', lim, 'used_before', cnt, 'used_after', cnt + case when p_dry_run then 0 else c_created end),
    'results', res);
end $$;
revoke all on function public.bulk_upsert_products(uuid, jsonb, text, boolean) from public, anon;
grant execute on function public.bulk_upsert_products(uuid, jsonb, text, boolean) to authenticated;

-- =====================================================================================================
-- 5. Storage: the owner keeps the <owner uid>/ folder; team members with products_edit may upload into
--    (and clean up in) their business owner's folder. Skipped automatically if Storage is not set up.
-- =====================================================================================================
do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'storage.objects not found: skipping storage policies (run storage.sql first, then this file again)';
    return;
  end if;
  execute 'drop policy if exists "product-images owner insert" on storage.objects';
  execute $p$create policy "product-images owner insert" on storage.objects for insert to authenticated
    with check (bucket_id = 'product-images' and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (select 1 from public.vendors v where v.owner_id::text = (storage.foldername(objects.name))[1] and public.vendor_perm(v.id, 'products_edit'))))$p$;
  execute 'drop policy if exists "product-images owner delete" on storage.objects';
  execute $p$create policy "product-images owner delete" on storage.objects for delete to authenticated
    using (bucket_id = 'product-images' and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (select 1 from public.vendors v where v.owner_id::text = (storage.foldername(objects.name))[1] and public.vendor_perm(v.id, 'products_edit'))))$p$;
end $$;

notify pgrst, 'reload schema';
