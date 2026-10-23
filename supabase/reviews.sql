-- v1.19 RATINGS AND REVIEWS. Run AFTER shop_gift_cards.sql. Idempotent; ends with notify pgrst.
-- Verified buyers only: the reviewer must own a COMPLETED order (delivery orders end as 'completed' once delivered) containing the product.
-- One review per order item, editable by its author for 30 days. Product rating 1-5 (required), shop service rating 1-5 (optional),
-- comment (optional, plain text, max 1000 characters, control characters removed; the browser always escapes it).
-- One public vendor reply per review (owner or sub-admin). Helpful votes: one per user, not on your own review.
-- Anyone signed in can report. The platform admin hides or restores (moderation queue). Vendors cannot delete or hide reviews.
-- Rate limits: 10 new reviews per user per hour, 30 edits per user per day, 10 reports per user per day, 60 helpful votes per hour.
-- NO PHOTOS OR IMAGES (Daniel's rule): text and stars only. No upload, image or attachment columns exist. The server REJECTS
--   image markup and links to images in comments, replies and report reasons (_rv_noimg): <img, <picture, <svg, <iframe, markdown ![..](..),
--   [img] BBCode, data:image/ URIs and any URL ending in an image extension (.jpg .jpeg .png .gif .webp .bmp .svg .heic .avif .tif .tiff .ico).
-- No direct writes on any table: SECURITY DEFINER RPCs only.
--
-- FEATURED RANKING (public_product_scores):
--   bayes   = (C*m + sum_of_ratings) / (C + n)        C = 5 (prior weight), m = platform mean of visible ratings (4.0 if no reviews yet)
--   recency = exp(-age_days / 45)                     age = days since the newer of: product created, latest visible review
--   score   = 0.75 * (bayes / 5) + 0.25 * recency      (0..1)
--   A product with no reviews gets bayes = m, so it stays eligible and is neither boosted nor punished.
--   Home page: the products flagged "featured" are ordered by score (falls back to the flag order if the RPC is missing).

create table if not exists public.product_reviews (
  id              uuid primary key default gen_random_uuid(),
  order_item_id   uuid not null unique references public.order_items(id) on delete cascade,
  order_id        uuid not null references public.orders(id) on delete cascade,
  product_id      uuid not null references public.products(id) on delete cascade,
  vendor_id       uuid not null references public.vendors(id) on delete cascade,
  user_id         uuid not null,
  rating          smallint not null check (rating between 1 and 5),
  service_rating  smallint check (service_rating between 1 and 5),
  comment         text check (comment is null or length(comment) <= 1000),
  status          text not null default 'visible' check (status in ('visible','hidden')),
  hidden_reason   text check (hidden_reason is null or length(hidden_reason) <= 300),
  helpful_count   integer not null default 0,
  report_count    integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  edited_at       timestamptz
);
create index if not exists product_reviews_product_idx on public.product_reviews(product_id, status, created_at desc);
create index if not exists product_reviews_vendor_idx on public.product_reviews(vendor_id, created_at desc);
create index if not exists product_reviews_user_idx on public.product_reviews(user_id, created_at desc);

create table if not exists public.review_replies (
  review_id   uuid primary key references public.product_reviews(id) on delete cascade,
  vendor_id   uuid not null references public.vendors(id) on delete cascade,
  body        text not null check (length(body) between 1 and 1000),
  by_user     uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create table if not exists public.review_helpful (
  review_id  uuid not null references public.product_reviews(id) on delete cascade,
  user_id    uuid not null,
  created_at timestamptz not null default now(),
  primary key (review_id, user_id)
);
create table if not exists public.review_reports (
  id         bigserial primary key,
  review_id  uuid not null references public.product_reviews(id) on delete cascade,
  user_id    uuid not null,
  reason     text not null check (length(reason) between 3 and 300),
  status     text not null default 'open' check (status in ('open','resolved')),
  created_at timestamptz not null default now(),
  unique (review_id, user_id)
);
create table if not exists public.review_mod_log (
  id         bigserial primary key,
  review_id  uuid not null references public.product_reviews(id) on delete cascade,
  action     text not null check (action in ('hide','restore','dismiss')),
  reason     text,
  by_user    uuid,
  created_at timestamptz not null default now()
);

alter table public.product_reviews enable row level security;
alter table public.review_replies  enable row level security;
alter table public.review_helpful  enable row level security;
alter table public.review_reports  enable row level security;
alter table public.review_mod_log  enable row level security;
drop policy if exists pr_read on public.product_reviews;
create policy pr_read on public.product_reviews for select to anon, authenticated
  using (status = 'visible' or user_id = auth.uid() or public.is_admin() or public.vendor_role(vendor_id) is not null);
drop policy if exists rr_read on public.review_replies;
create policy rr_read on public.review_replies for select to anon, authenticated
  using (exists (select 1 from public.product_reviews r where r.id = review_id and (r.status = 'visible' or public.is_admin() or public.vendor_role(r.vendor_id) is not null)));
drop policy if exists rh_read on public.review_helpful;
create policy rh_read on public.review_helpful for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists rp_read on public.review_reports;
create policy rp_read on public.review_reports for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists rml_read on public.review_mod_log;
create policy rml_read on public.review_mod_log for select to authenticated using (public.is_admin());
revoke all on public.product_reviews, public.review_replies, public.review_helpful, public.review_reports, public.review_mod_log from public, anon, authenticated;
grant select on public.product_reviews, public.review_replies to anon, authenticated;
grant select on public.review_helpful, public.review_reports, public.review_mod_log to authenticated;
revoke all on sequence public.review_reports_id_seq, public.review_mod_log_id_seq from public, anon, authenticated;

-- plain text: strip control chars (keep newlines), collapse 3+ newlines, trim
create or replace function public._rv_clean(t text, maxlen int) returns text
language sql immutable set search_path = public, pg_temp as $$
  select nullif(btrim(regexp_replace(regexp_replace(left(coalesce(t,''), maxlen * 2), E'[\\x00-\\x09\\x0B-\\x1F\\x7F]', '', 'g'), E'\\n{3,}', E'\n\n', 'g')), '');
$$;
revoke all on function public._rv_clean(text,int) from public, anon, authenticated;

create or replace function public._rv_noimg(t text) returns void
language plpgsql immutable set search_path = public, pg_temp as $$
begin
  if t is null then return; end if;
  if t ~* '<\s*(img|picture|svg|iframe|object|embed|video|source)\y'
     or t ~ '!\[[^\]]*\]\s*\('
     or t ~* '\[\s*img\s*\]'
     or t ~* 'data:\s*image/'
     or t ~* '\.(jpe?g|png|gif|webp|bmp|svg|heic|heif|avif|tiff?|ico)(\?[^\s]*)?(\s|$|[)"''>\]])'
  then raise exception 'Photos and images are not allowed in reviews or replies: text only, please remove the image or image link'; end if;
end $$;
revoke all on function public._rv_noimg(text) from public, anon, authenticated;

create or replace function public._rv_json(r public.product_reviews, p_me uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', r.id, 'product_id', r.product_id, 'vendor_id', r.vendor_id, 'rating', r.rating, 'service_rating', r.service_rating,
    'comment', r.comment, 'status', r.status, 'helpful', r.helpful_count, 'created_at', r.created_at, 'edited_at', r.edited_at,
    'author', coalesce(nullif(split_part(btrim(coalesce(pf.full_name,'')), ' ', 1), ''), 'Customer')
              || coalesce(' ' || nullif(left(split_part(btrim(coalesce(pf.full_name,'')), ' ', 2), 1), '') || '.', ''),
    'verified', true, 'mine', r.user_id = p_me,
    'can_edit', r.user_id = p_me and r.created_at > now() - interval '30 days',
    'voted', exists(select 1 from public.review_helpful h where h.review_id = r.id and h.user_id = p_me),
    'reply', (select jsonb_build_object('body', x.body, 'at', x.updated_at) from public.review_replies x where x.review_id = r.id))
  from (select 1) s left join public.profiles pf on pf.id = r.user_id;
$$;
revoke all on function public._rv_json(public.product_reviews, uuid) from public, anon, authenticated;

-- what can I review for this product? (completed orders of mine containing it)
create or replace function public.review_eligible(p_product uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('order_item_id', oi.id, 'order_id', o.id, 'order_number', o.order_number, 'ordered_at', o.created_at,
     'review', (select public._rv_json(r, auth.uid()) from public.product_reviews r where r.order_item_id = oi.id)) order by o.created_at desc), '[]'::jsonb)
  from public.order_items oi join public.orders o on o.id = oi.order_id
  where auth.uid() is not null and o.consumer_id = auth.uid() and o.status = 'completed' and oi.product_id = p_product;
$$;

create or replace function public.review_submit(p_order_item uuid, p_rating int, p_service_rating int default null, p_comment text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid := auth.uid(); it record; r public.product_reviews; c text := public._rv_clean(p_comment, 1000);
begin
  if u is null then raise exception 'Please log in to write a review'; end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'Choose a product rating from 1 to 5 stars'; end if;
  if p_service_rating is not null and (p_service_rating < 1 or p_service_rating > 5) then raise exception 'Shop service rating must be 1 to 5 stars'; end if;
  if c is not null and length(c) > 1000 then raise exception 'The comment is too long (max 1000 characters)'; end if;
  perform public._rv_noimg(c);
  select oi.id, oi.product_id, o.id as order_id, o.vendor_id, o.consumer_id, o.status into it
    from public.order_items oi join public.orders o on o.id = oi.order_id where oi.id = p_order_item;
  if not found or it.consumer_id <> u then raise exception 'Only verified buyers can review: this is not one of your orders'; end if;
  if it.status <> 'completed' then raise exception 'You can review once the order is completed or delivered'; end if;
  if it.product_id is null then raise exception 'This product is no longer available to review'; end if;
  select * into r from public.product_reviews where order_item_id = p_order_item for update;
  if found then
    if r.created_at < now() - interval '30 days' then raise exception 'Reviews can only be edited for 30 days'; end if;
    if (select count(*) from public.product_reviews where user_id = u and edited_at > now() - interval '1 day') >= 30 then raise exception 'Too many edits today. Please try again tomorrow.'; end if;
    update public.product_reviews set rating = p_rating, service_rating = p_service_rating, comment = c, updated_at = now(), edited_at = now()
      where id = r.id returning * into r;
  else
    if (select count(*) from public.product_reviews where user_id = u and created_at > now() - interval '1 hour') >= 10 then raise exception 'You have posted many reviews in the last hour. Please try again later.'; end if;
    insert into public.product_reviews(order_item_id, order_id, product_id, vendor_id, user_id, rating, service_rating, comment)
      values (p_order_item, it.order_id, it.product_id, it.vendor_id, u, p_rating, p_service_rating, c) returning * into r;
  end if;
  return public._rv_json(r, u);
end $$;

-- product page: summary + reviews (visible only). p_sort 'new' or 'helpful'
create or replace function public.review_list(p_product uuid, p_sort text default 'new', p_limit int default 20, p_offset int default 0) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'summary', (select jsonb_build_object('count', count(*), 'avg', round(avg(rating)::numeric, 2),
        'service_avg', round(avg(service_rating)::numeric, 2), 'service_count', count(service_rating),
        'breakdown', jsonb_build_object('5', count(*) filter (where rating = 5), '4', count(*) filter (where rating = 4), '3', count(*) filter (where rating = 3),
                                        '2', count(*) filter (where rating = 2), '1', count(*) filter (where rating = 1)))
        from public.product_reviews where product_id = p_product and status = 'visible'),
    'reviews', coalesce((select jsonb_agg(public._rv_json(r, auth.uid()) order by case when p_sort = 'helpful' then r.helpful_count end desc nulls last, r.created_at desc)
        from (select * from public.product_reviews where product_id = p_product and status = 'visible'
              order by case when p_sort = 'helpful' then helpful_count end desc nulls last, created_at desc
              limit least(greatest(coalesce(p_limit,20),1),50) offset greatest(coalesce(p_offset,0),0)) r), '[]'::jsonb));
$$;

create or replace function public.shop_service_rating(p_vendor uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('service_avg', round(avg(service_rating)::numeric, 2), 'service_count', count(service_rating),
    'product_avg', round(avg(rating)::numeric, 2), 'review_count', count(*))
  from public.product_reviews where vendor_id = p_vendor and status = 'visible';
$$;

create or replace function public.review_helpful_toggle(p_review uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid := auth.uid(); r public.product_reviews; on_ boolean;
begin
  if u is null then raise exception 'Please log in to vote'; end if;
  select * into r from public.product_reviews where id = p_review and status = 'visible' for update;
  if not found then raise exception 'Review not found'; end if;
  if r.user_id = u then raise exception 'You cannot vote on your own review'; end if;
  if exists (select 1 from public.review_helpful where review_id = p_review and user_id = u) then
    delete from public.review_helpful where review_id = p_review and user_id = u; on_ := false;
  else
    if (select count(*) from public.review_helpful where user_id = u and created_at > now() - interval '1 hour') >= 60 then raise exception 'Too many votes. Please slow down.'; end if;
    insert into public.review_helpful(review_id, user_id) values (p_review, u); on_ := true;
  end if;
  update public.product_reviews set helpful_count = (select count(*) from public.review_helpful where review_id = p_review) where id = p_review returning * into r;
  return jsonb_build_object('voted', on_, 'helpful', r.helpful_count);
end $$;

create or replace function public.review_report(p_review uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid := auth.uid(); why text := public._rv_clean(p_reason, 300);
begin
  if u is null then raise exception 'Please log in to report a review'; end if;
  if why is null or length(why) < 3 then raise exception 'Tell us what is wrong (at least 3 characters)'; end if;
  if length(why) > 300 then raise exception 'The reason is too long (max 300 characters)'; end if;
  perform public._rv_noimg(why);
  if not exists (select 1 from public.product_reviews where id = p_review) then raise exception 'Review not found'; end if;
  if exists (select 1 from public.review_reports where review_id = p_review and user_id = u) then raise exception 'You have already reported this review'; end if;
  if (select count(*) from public.review_reports where user_id = u and created_at > now() - interval '1 day') >= 10 then raise exception 'You have sent many reports today. Please try again tomorrow.'; end if;
  insert into public.review_reports(review_id, user_id, reason) values (p_review, u, why);
  update public.product_reviews set report_count = report_count + 1 where id = p_review;
  return jsonb_build_object('reported', true);
end $$;

create or replace function public.vendor_review_reply(p_review uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.product_reviews; b text := public._rv_clean(p_body, 1000);
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select * into r from public.product_reviews where id = p_review;
  if not found then raise exception 'Review not found'; end if;
  if coalesce(public.vendor_role(r.vendor_id), '') not in ('admin','subadmin') then raise exception 'Only the business owner or a sub-admin can reply'; end if;
  if b is null then raise exception 'Write a reply first'; end if;
  perform public._rv_noimg(b);
  if length(b) > 1000 then raise exception 'The reply is too long (max 1000 characters)'; end if;
  insert into public.review_replies(review_id, vendor_id, body, by_user) values (p_review, r.vendor_id, b, auth.uid())
    on conflict (review_id) do update set body = excluded.body, by_user = excluded.by_user, updated_at = now();
  return jsonb_build_object('review_id', p_review, 'body', b);
end $$;

-- vendor Reviews tab: averages, 6-month trend, low-rating alerts (1-2 stars, last 30 days, no reply yet), all reviews incl. hidden
create or replace function public.vendor_reviews(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if public.vendor_role(p_vendor) is null and not public.is_admin() then raise exception 'Business not found'; end if;
  return jsonb_build_object(
    'summary', (select jsonb_build_object('count', count(*), 'avg', round(avg(rating)::numeric,2), 'service_avg', round(avg(service_rating)::numeric,2),
        'service_count', count(service_rating), 'unreplied', count(*) filter (where not exists (select 1 from public.review_replies x where x.review_id = r.id)),
        'breakdown', jsonb_build_object('5', count(*) filter (where rating=5), '4', count(*) filter (where rating=4), '3', count(*) filter (where rating=3), '2', count(*) filter (where rating=2), '1', count(*) filter (where rating=1)))
        from public.product_reviews r where vendor_id = p_vendor and status = 'visible'),
    'trend', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'count', coalesce(x.n,0), 'avg', x.a) order by m), '[]'::jsonb)
        from generate_series(date_trunc('month', now() at time zone 'America/Grenada') - interval '5 months', date_trunc('month', now() at time zone 'America/Grenada'), interval '1 month') m
        left join (select date_trunc('month', created_at at time zone 'America/Grenada') mm, count(*) n, round(avg(rating)::numeric,2) a
                   from public.product_reviews where vendor_id = p_vendor and status = 'visible' group by 1) x on x.mm = m),
    'alerts', coalesce((select jsonb_agg(public._rv_json(r, auth.uid()) || jsonb_build_object('product_name', p.name) order by r.created_at desc)
        from public.product_reviews r join public.products p on p.id = r.product_id
        where r.vendor_id = p_vendor and r.status = 'visible' and r.rating <= 2 and r.created_at > now() - interval '30 days'
          and not exists (select 1 from public.review_replies x where x.review_id = r.id)), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(public._rv_json(r, auth.uid()) || jsonb_build_object('product_name', p.name, 'hidden_reason', r.hidden_reason) order by r.created_at desc)
        from (select * from public.product_reviews where vendor_id = p_vendor order by created_at desc limit 300) r join public.products p on p.id = r.product_id), '[]'::jsonb));
end $$;

-- admin moderation queue: 'reported' (open reports), 'hidden', or 'all'
create or replace function public.admin_review_queue(p_filter text default 'reported') returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Only the platform admin can moderate reviews'; end if;
  return jsonb_build_object(
    'open_reports', (select count(distinct review_id) from public.review_reports where status = 'open'),
    'hidden', (select count(*) from public.product_reviews where status = 'hidden'),
    'items', coalesce((select jsonb_agg(x order by x->>'last_report' desc nulls last, x->>'created_at' desc) from (
      select public._rv_json(r, null) || jsonb_build_object('product_name', p.name, 'vendor_name', v.name, 'hidden_reason', r.hidden_reason,
        'reports', coalesce((select jsonb_agg(jsonb_build_object('reason', rp.reason, 'at', rp.created_at, 'status', rp.status) order by rp.id desc) from public.review_reports rp where rp.review_id = r.id), '[]'::jsonb),
        'open_reports', (select count(*) from public.review_reports rp where rp.review_id = r.id and rp.status = 'open'),
        'last_report', (select max(created_at) from public.review_reports rp where rp.review_id = r.id),
        'log', coalesce((select jsonb_agg(jsonb_build_object('action', l.action, 'reason', l.reason, 'at', l.created_at) order by l.id desc) from public.review_mod_log l where l.review_id = r.id), '[]'::jsonb)) x
      from public.product_reviews r join public.products p on p.id = r.product_id join public.vendors v on v.id = r.vendor_id
      where case coalesce(p_filter,'reported') when 'hidden' then r.status = 'hidden'
                 when 'all' then true
                 else exists (select 1 from public.review_reports rp where rp.review_id = r.id and rp.status = 'open') end
      order by r.created_at desc limit 200) s), '[]'::jsonb));
end $$;

create or replace function public.admin_review_moderate(p_review uuid, p_action text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.product_reviews; why text := public._rv_clean(p_reason, 300);
begin
  if not public.is_admin() then raise exception 'Only the platform admin can moderate reviews'; end if;
  if p_action not in ('hide','restore','dismiss') then raise exception 'Unknown action'; end if;
  if p_action = 'hide' and (why is null or length(why) < 3) then raise exception 'Give a reason for hiding (at least 3 characters)'; end if;
  select * into r from public.product_reviews where id = p_review for update;
  if not found then raise exception 'Review not found'; end if;
  if p_action = 'hide' then update public.product_reviews set status = 'hidden', hidden_reason = left(why,300) where id = p_review;
  elsif p_action = 'restore' then update public.product_reviews set status = 'visible', hidden_reason = null where id = p_review; end if;
  update public.review_reports set status = 'resolved' where review_id = p_review and status = 'open';
  insert into public.review_mod_log(review_id, action, reason, by_user) values (p_review, p_action, why, auth.uid());
  select * into r from public.product_reviews where id = p_review;
  return jsonb_build_object('id', r.id, 'status', r.status);
end $$;

-- featured ranking scores (see formula at the top). Returns only id, n, avg and score for active products.
create or replace function public.public_product_scores(p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with g as (select coalesce(avg(rating), 4.0) m from public.product_reviews where status = 'visible'),
  s as (select p.id, count(r.id) n, coalesce(sum(r.rating),0) sm, avg(r.rating) a,
               greatest(p.created_at, coalesce(max(r.created_at), p.created_at)) fresh
          from public.products p left join public.product_reviews r on r.product_id = p.id and r.status = 'visible'
         where p.id = any(coalesce(p_ids, '{}')) and p.active
         group by p.id, p.created_at)
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'n', s.n, 'avg', round(s.a::numeric,2),
           'score', round((0.75 * ((5 * g.m + s.sm) / (5 + s.n)) / 5 + 0.25 * exp(-greatest(extract(epoch from now() - s.fresh), 0) / 86400.0 / 45))::numeric, 4))
         order by (0.75 * ((5 * g.m + s.sm) / (5 + s.n)) / 5 + 0.25 * exp(-greatest(extract(epoch from now() - s.fresh), 0) / 86400.0 / 45)) desc), '[]'::jsonb)
  from s, g;
$$;

revoke all on function public.review_eligible(uuid), public.review_submit(uuid,int,int,text), public.review_list(uuid,text,int,int),
  public.shop_service_rating(uuid), public.review_helpful_toggle(uuid), public.review_report(uuid,text), public.vendor_review_reply(uuid,text),
  public.vendor_reviews(uuid), public.admin_review_queue(text), public.admin_review_moderate(uuid,text,text), public.public_product_scores(uuid[]) from public, anon;
grant execute on function public.review_list(uuid,text,int,int), public.shop_service_rating(uuid), public.public_product_scores(uuid[]) to anon, authenticated;
grant execute on function public.review_eligible(uuid), public.review_submit(uuid,int,int,text), public.review_helpful_toggle(uuid), public.review_report(uuid,text),
  public.vendor_review_reply(uuid,text), public.vendor_reviews(uuid), public.admin_review_queue(text), public.admin_review_moderate(uuid,text,text) to authenticated;

-- ======================================================================================================
-- v1.19 REAL PRODUCT PHOTOS RULE (Daniel): vendors must use actual photos of their own products (food: the actual dish as served).
-- Stock, AI-generated or borrowed images are not allowed (Vendor Terms 3a).
--  * Every photo save goes through set_product_photos_confirmed(): new photos need p_confirm = true
--    ("These are real photos of this product taken by my shop"). The time and user are stored on each photo row and in a log.
--  * Direct writes to product_images and the old set_product_photos() are closed to signed-in users (RPC only).
--  * EXIF camera data is an ADVISORY hint only (sent by the browser, never trusted, never blocks). No automatic detection is promised.
--  * Customers report a listing ("Photo doesn't match / stock photo") with report_listing(); same rate limit as review reports.
--  * Admin queue: hide image, hide listing, or dismiss, with a note shown to the vendor in their dashboard.
--  * Known gap: bulk CSV import (bulk_upsert_products) can still add an image link; those rows have no confirmation and the
--    vendor dashboard asks the vendor to open the product and confirm (see unconfirmed count in vendor_photo_status).
-- ======================================================================================================
alter table public.product_images add column if not exists real_photo_confirmed_at timestamptz;
alter table public.product_images add column if not exists real_photo_confirmed_by uuid;
alter table public.product_images add column if not exists exif_camera boolean;          -- advisory: true = camera data seen, false = none seen, null = unknown
alter table public.product_images add column if not exists hidden_at timestamptz;          -- set by the platform admin (hide image)
alter table public.product_images add column if not exists hidden_reason text check (hidden_reason is null or length(hidden_reason) <= 300);
alter table public.products add column if not exists admin_hidden_at timestamptz;         -- set by the platform admin (hide listing)
alter table public.products add column if not exists admin_hidden_reason text check (admin_hidden_reason is null or length(admin_hidden_reason) <= 300);

create table if not exists public.product_photo_confirmations (
  id           bigserial primary key,
  product_id   uuid not null references public.products(id) on delete cascade,
  vendor_id    uuid not null references public.vendors(id) on delete cascade,
  user_id      uuid not null,
  photo_count  integer not null,
  new_count    integer not null,
  statement    text not null default 'These are real photos of this product taken by my shop',
  confirmed_at timestamptz not null default now()
);
create index if not exists ppc_product_idx on public.product_photo_confirmations(product_id, confirmed_at desc);

create table if not exists public.listing_reports (
  id          bigserial primary key,
  product_id  uuid not null references public.products(id) on delete cascade,
  vendor_id   uuid not null references public.vendors(id) on delete cascade,
  user_id     uuid not null,
  reason      text not null check (reason in ('photo_mismatch','other')),
  note        text check (note is null or length(note) <= 300),
  image_url   text check (image_url is null or length(image_url) <= 2000),
  status      text not null default 'open' check (status in ('open','resolved')),
  resolution  text check (resolution is null or resolution in ('hide_image','hide_listing','dismiss')),
  created_at  timestamptz not null default now(),
  unique (product_id, user_id)
);
create index if not exists listing_reports_open_idx on public.listing_reports(status, created_at desc);

create table if not exists public.vendor_notices (
  id          bigserial primary key,
  vendor_id   uuid not null references public.vendors(id) on delete cascade,
  product_id  uuid references public.products(id) on delete set null,
  kind        text not null check (kind in ('photo_hidden','listing_hidden','photo_report_dismissed','review_hidden')),
  message     text not null check (length(message) <= 600),
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index if not exists vendor_notices_vendor_idx on public.vendor_notices(vendor_id, created_at desc);

alter table public.product_photo_confirmations enable row level security;
alter table public.listing_reports enable row level security;
alter table public.vendor_notices enable row level security;
drop policy if exists ppc_read on public.product_photo_confirmations;
create policy ppc_read on public.product_photo_confirmations for select to authenticated using (public.is_admin() or public.vendor_role(vendor_id) is not null);
drop policy if exists lr_read on public.listing_reports;
create policy lr_read on public.listing_reports for select to authenticated using (public.is_admin() or user_id = auth.uid());
drop policy if exists vn_read on public.vendor_notices;
create policy vn_read on public.vendor_notices for select to authenticated using (public.is_admin() or public.vendor_role(vendor_id) is not null);
revoke all on public.product_photo_confirmations, public.listing_reports, public.vendor_notices from public, anon, authenticated;
grant select on public.product_photo_confirmations, public.listing_reports, public.vendor_notices to authenticated;
revoke all on sequence public.product_photo_confirmations_id_seq, public.listing_reports_id_seq, public.vendor_notices_id_seq from public, anon, authenticated;

-- hidden photos are not public any more (vendor members and admin still see them, marked hidden)
drop policy if exists product_images_select on public.product_images;
create policy product_images_select on public.product_images for select
  using (exists (select 1 from public.products p where p.id = product_id)
         and (hidden_at is null or public.is_admin() or exists (select 1 from public.products p where p.id = product_id and public.vendor_role(p.vendor_id) is not null)));
-- RPC only from now on
revoke insert, update, delete on public.product_images from authenticated;
revoke execute on function public.set_product_photos(uuid, jsonb) from authenticated;

-- a listing the admin hid cannot be switched back on by the shop
create or replace function public.products_admin_hidden_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.is_admin() or current_setting('cc.admin_mod', true) = '1' then return new; end if;
  if old.admin_hidden_at is not null and new.active then
    raise exception 'This listing was hidden by Carriacou Connect (photo rule). Replace the photos and contact support to have it reviewed.';
  end if;
  new.admin_hidden_at := old.admin_hidden_at; new.admin_hidden_reason := old.admin_hidden_reason;
  return new;
end $$;
drop trigger if exists products_admin_hidden_guard on public.products;
create trigger products_admin_hidden_guard before update on public.products for each row execute function public.products_admin_hidden_guard();

create or replace function public.set_product_photos_confirmed(p_product uuid, p_urls jsonb, p_confirm boolean, p_exif jsonb default '[]'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; res jsonb; newn int; total int;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select p.vendor_id into v from public.products p where p.id = p_product;
  if v is null or not (public.is_admin() or public.vendor_perm(v, 'products_edit')) then raise exception 'Product not found'; end if;
  if p_urls is null or jsonb_typeof(p_urls) <> 'array' then raise exception 'Photos must be a list of links'; end if;
  select count(*) into newn from jsonb_array_elements_text(p_urls) u(url)
    where not exists (select 1 from public.product_images i where i.product_id = p_product and i.url = u.url);
  if newn > 0 and coalesce(p_confirm, false) is not true then
    raise exception 'Tick "These are real photos of this product taken by my shop" to add photos. Stock, AI-generated or borrowed images are not allowed.';
  end if;
  if exists (select 1 from jsonb_array_elements_text(p_urls) u(url) join public.product_images i on i.product_id = p_product and i.url = u.url and i.hidden_at is not null) then
    raise exception 'A photo removed by Carriacou Connect cannot be added back. Take a new photo of the product.';
  end if;
  res := public.set_product_photos(p_product, p_urls);
  update public.product_images i set real_photo_confirmed_at = now(), real_photo_confirmed_by = auth.uid(),
         exif_camera = (select case when e ? 'camera' and jsonb_typeof(e->'camera') = 'boolean' then (e->>'camera')::boolean end
                          from jsonb_array_elements(case when jsonb_typeof(p_exif) = 'array' then p_exif else '[]'::jsonb end) e where e->>'url' = i.url limit 1)
   where i.product_id = p_product and (i.real_photo_confirmed_at is null and coalesce(p_confirm,false));
  select count(*) into total from public.product_images where product_id = p_product;
  if coalesce(p_confirm,false) then
    insert into public.product_photo_confirmations(product_id, vendor_id, user_id, photo_count, new_count) values (p_product, v, auth.uid(), total, newn);
  end if;
  return res || jsonb_build_object('confirmed', coalesce(p_confirm,false), 'new', newn,
     'no_camera_data', (select count(*) from public.product_images where product_id = p_product and exif_camera is false));
end $$;
revoke all on function public.set_product_photos_confirmed(uuid, jsonb, boolean, jsonb) from public, anon;
grant execute on function public.set_product_photos_confirmed(uuid, jsonb, boolean, jsonb) to authenticated;

-- customer report: "Photo doesn't match / stock photo" (same path and limit as review reports: 10 per user per day across both)
create or replace function public.report_listing(p_product uuid, p_reason text, p_note text default null, p_image_url text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid := auth.uid(); v uuid; n text := public._rv_clean(p_note, 300);
begin
  if u is null then raise exception 'Please log in to report a listing'; end if;
  if p_reason not in ('photo_mismatch','other') then raise exception 'Choose a reason'; end if;
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
revoke all on function public.report_listing(uuid, text, text, text) from public, anon;
grant execute on function public.report_listing(uuid, text, text, text) to authenticated;

create or replace function public.admin_listing_queue(p_filter text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Only the platform admin can moderate listings'; end if;
  return jsonb_build_object('open', (select count(distinct product_id) from public.listing_reports where status = 'open'),
   'items', coalesce((select jsonb_agg(x order by x->>'last_report' desc) from (
     select jsonb_build_object('product_id', p.id, 'product_name', p.name, 'vendor_id', v.id, 'vendor_name', v.name, 'active', p.active,
       'admin_hidden', p.admin_hidden_at is not null,
       'images', coalesce((select jsonb_agg(jsonb_build_object('url', i.url, 'hidden', i.hidden_at is not null, 'confirmed_at', i.real_photo_confirmed_at,
                  'exif_camera', i.exif_camera) order by i.position) from public.product_images i where i.product_id = p.id), '[]'::jsonb),
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
      'A photo of "' || left(p.name, 120) || '" was hidden because it may not be a real photo of your product. ' || n);
  elsif p_action = 'hide_listing' then
    update public.products set active = false, admin_hidden_at = now(), admin_hidden_reason = n where id = p_product;
    insert into public.vendor_notices(vendor_id, product_id, kind, message) values (p.vendor_id, p_product, 'listing_hidden',
      'Your listing "' || left(p.name, 120) || '" was hidden under the real-photos rule. ' || n);
  else
    if n is not null then insert into public.vendor_notices(vendor_id, product_id, kind, message) values (p.vendor_id, p_product, 'photo_report_dismissed',
      'A photo report on "' || left(p.name, 120) || '" was checked and closed. ' || n); end if;
  end if;
  update public.listing_reports set status = 'resolved', resolution = p_action where product_id = p_product and status = 'open';
  return jsonb_build_object('product_id', p_product, 'action', p_action);
end $$;

create or replace function public.admin_listing_restore(p_product uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Only the platform admin can moderate listings'; end if;
  perform set_config('cc.admin_mod', '1', true);
  update public.products set admin_hidden_at = null, admin_hidden_reason = null where id = p_product;
  return jsonb_build_object('product_id', p_product, 'restored', true);
end $$;

-- vendor dashboard: notices + photo status (unconfirmed / no camera data hints)
create or replace function public.vendor_notices_list(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if public.vendor_role(p_vendor) is null and not public.is_admin() then raise exception 'Business not found'; end if;
  return jsonb_build_object(
    'notices', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'message', message, 'product_id', product_id, 'at', created_at, 'read', read_at is not null) order by id desc)
                from (select * from public.vendor_notices where vendor_id = p_vendor order by id desc limit 30) n), '[]'::jsonb),
    'unconfirmed_photos', (select count(*) from public.product_images i join public.products p on p.id = i.product_id where p.vendor_id = p_vendor and i.real_photo_confirmed_at is null and i.hidden_at is null),
    'no_camera_data', (select count(*) from public.product_images i join public.products p on p.id = i.product_id where p.vendor_id = p_vendor and i.exif_camera is false and i.hidden_at is null));
end $$;
create or replace function public.vendor_notice_read(p_vendor uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.vendor_role(p_vendor) is null then raise exception 'Business not found'; end if;
  update public.vendor_notices set read_at = now() where vendor_id = p_vendor and read_at is null;
end $$;
revoke all on function public.admin_listing_queue(text), public.admin_listing_moderate(uuid,text,text,text), public.admin_listing_restore(uuid),
  public.vendor_notices_list(uuid), public.vendor_notice_read(uuid) from public, anon;
grant execute on function public.admin_listing_queue(text), public.admin_listing_moderate(uuid,text,text,text), public.admin_listing_restore(uuid),
  public.vendor_notices_list(uuid), public.vendor_notice_read(uuid) to authenticated;

-- sign-up acceptance of the real-photos rule (Vendor Terms 3a): stored per user with the time
create table if not exists public.photo_rule_acceptances (
  user_id     uuid primary key,
  terms_ref   text not null default 'vendor-terms 3a (v1.19)',
  accepted_at timestamptz not null default now()
);
alter table public.photo_rule_acceptances enable row level security;
drop policy if exists pra_read on public.photo_rule_acceptances;
create policy pra_read on public.photo_rule_acceptances for select to authenticated using (user_id = auth.uid() or public.is_admin());
revoke all on public.photo_rule_acceptances from public, anon, authenticated;
grant select on public.photo_rule_acceptances to authenticated;
create or replace function public.accept_photo_rule() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  insert into public.photo_rule_acceptances(user_id) values (auth.uid())
    on conflict (user_id) do update set accepted_at = now(), terms_ref = excluded.terms_ref;
  return jsonb_build_object('accepted', true);
end $$;
revoke all on function public.accept_photo_rule() from public, anon;
grant execute on function public.accept_photo_rule() to authenticated;

notify pgrst, 'reload schema';
