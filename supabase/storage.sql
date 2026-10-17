-- Carriacou Connect v0.3: product image storage. Safe to run again.
-- Run in Supabase Dashboard > SQL Editor (after schema.sql).
-- Public bucket 'product-images': anyone can read; only the signed-in owner can write
-- inside the folder named with their own auth.uid():  <uid>/<file>
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images','product-images', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 2097152,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "product-images public read" on storage.objects;
create policy "product-images public read" on storage.objects for select
  using (bucket_id = 'product-images');

drop policy if exists "product-images owner insert" on storage.objects;
create policy "product-images owner insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "product-images owner update" on storage.objects;
create policy "product-images owner update" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'product-images' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "product-images owner delete" on storage.objects;
create policy "product-images owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and (storage.foldername(name))[1] = auth.uid()::text);
