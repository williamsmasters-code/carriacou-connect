-- v1.21 ORDER REVIEWS. Run AFTER reviews.sql (and after payments_mock.sql on a v1.20 database). Idempotent; ends with notify pgrst.
-- One review per completed order: the customer who owns the order may leave a single shop / buying-experience
-- review (stars 1-5, optional text, no photos) once the order status is 'completed' (pickup marked collected
-- by the vendor, or a card order marked completed). Editable by the author for 30 days. One public vendor
-- reply per order review (owner or sub-admin), editable. Vendors cannot delete or hide reviews.
--
-- RELATION TO PRODUCT REVIEWS (kept as they are):
--   product_reviews stay one-per-order-item and rate the product (optional service_rating still allowed on
--   the product page). An order review does not create product reviews, and product reviews do not count as
--   the order review. The order review is the shop + buying-experience rating tied to that order, and is
--   included in shop_service_rating (service_avg / service_count) alongside any product-review service
--   ratings. Product averages (product_avg, review_count) still come only from product_reviews.
--
-- Reuses _rv_clean and _rv_noimg from reviews.sql (plain text, max 1000, images rejected).
-- Rate limits are shared with product reviews: 10 new reviews/hour and 30 edits/day per user (both tables).
-- No direct writes: SECURITY DEFINER RPCs only. RLS on every new table.

create table if not exists public.order_reviews (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null unique references public.orders(id) on delete cascade,
  vendor_id       uuid not null references public.vendors(id) on delete cascade,
  user_id         uuid not null,
  rating          smallint not null check (rating between 1 and 5),
  comment         text check (comment is null or length(comment) <= 1000),
  status          text not null default 'visible' check (status in ('visible','hidden')),
  hidden_reason   text check (hidden_reason is null or length(hidden_reason) <= 300),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  edited_at       timestamptz
);
create index if not exists order_reviews_vendor_idx on public.order_reviews(vendor_id, status, created_at desc);
create index if not exists order_reviews_user_idx on public.order_reviews(user_id, created_at desc);

create table if not exists public.order_review_replies (
  review_id   uuid primary key references public.order_reviews(id) on delete cascade,
  vendor_id   uuid not null references public.vendors(id) on delete cascade,
  body        text not null check (length(body) between 1 and 1000),
  by_user     uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.order_reviews enable row level security;
alter table public.order_review_replies enable row level security;

drop policy if exists orv_read on public.order_reviews;
create policy orv_read on public.order_reviews for select to anon, authenticated
  using (status = 'visible' or user_id = auth.uid() or public.is_admin() or public.vendor_role(vendor_id) is not null);
drop policy if exists orvr_read on public.order_review_replies;
create policy orvr_read on public.order_review_replies for select to anon, authenticated
  using (exists (select 1 from public.order_reviews r where r.id = review_id
                 and (r.status = 'visible' or public.is_admin() or public.vendor_role(r.vendor_id) is not null)));

revoke all on public.order_reviews, public.order_review_replies from public, anon, authenticated;
grant select on public.order_reviews, public.order_review_replies to anon, authenticated;

create or replace function public._orv_json(r public.order_reviews, p_me uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', r.id, 'order_id', r.order_id, 'vendor_id', r.vendor_id, 'rating', r.rating,
    'comment', r.comment, 'status', r.status, 'hidden_reason', r.hidden_reason,
    'created_at', r.created_at, 'edited_at', r.edited_at,
    'author', coalesce(nullif(split_part(btrim(coalesce(pf.full_name,'')), ' ', 1), ''), 'Customer')
              || coalesce(' ' || nullif(left(split_part(btrim(coalesce(pf.full_name,'')), ' ', 2), 1), '') || '.', ''),
    'verified', true, 'mine', r.user_id = p_me,
    'can_edit', r.user_id = p_me and r.created_at > now() - interval '30 days',
    'reply', (select jsonb_build_object('body', x.body, 'at', x.updated_at) from public.order_review_replies x where x.review_id = r.id))
  from (select 1) s left join public.profiles pf on pf.id = r.user_id;
$$;
revoke all on function public._orv_json(public.order_reviews, uuid) from public, anon, authenticated;

-- one order's review state for the signed-in customer (or null review if eligible and not yet reviewed)
create or replace function public.order_review_get(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u uuid := auth.uid(); ord record; r public.order_reviews;
begin
  if u is null then
    return jsonb_build_object('eligible', false, 'reason', 'Please log in to write a review');
  end if;
  select o.id, o.order_number, o.status, o.consumer_id, o.vendor_id, v.name as vendor_name
    into ord from public.orders o join public.vendors v on v.id = o.vendor_id where o.id = p_order;
  if not found or ord.consumer_id <> u then
    return jsonb_build_object('eligible', false, 'reason', 'Only the customer who placed this order can review it');
  end if;
  select * into r from public.order_reviews where order_id = p_order;
  if ord.status <> 'completed' then
    return jsonb_build_object('eligible', false, 'reason', 'You can review once the order is completed',
      'order_id', ord.id, 'order_number', ord.order_number, 'vendor_name', ord.vendor_name, 'status', ord.status,
      'review', case when found then public._orv_json(r, u) else null end);
  end if;
  return jsonb_build_object('eligible', true, 'order_id', ord.id, 'order_number', ord.order_number,
    'vendor_name', ord.vendor_name, 'status', ord.status,
    'review', case when found then public._orv_json(r, u) else null end);
end $$;

-- batch for the customer's order history: only their own orders are returned
create or replace function public.order_reviews_for_orders(p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'order_id', o.id, 'order_number', o.order_number, 'status', o.status,
      'eligible', o.status = 'completed' and o.consumer_id = auth.uid(),
      'review', (select public._orv_json(r, auth.uid()) from public.order_reviews r where r.order_id = o.id))
    order by o.created_at desc), '[]'::jsonb)
  from public.orders o
  where auth.uid() is not null and o.consumer_id = auth.uid() and o.id = any (coalesce(p_ids, '{}'::uuid[]));
$$;

create or replace function public.order_review_submit(p_order uuid, p_rating int, p_comment text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid := auth.uid(); ord record; r public.order_reviews; c text := public._rv_clean(p_comment, 1000);
begin
  if u is null then raise exception 'Please log in to write a review'; end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'Choose a rating from 1 to 5 stars'; end if;
  if c is not null and length(c) > 1000 then raise exception 'The comment is too long (max 1000 characters)'; end if;
  perform public._rv_noimg(c);
  select o.id, o.consumer_id, o.vendor_id, o.status into ord from public.orders o where o.id = p_order for update;
  if not found or ord.consumer_id <> u then raise exception 'Only the customer who placed this order can review it'; end if;
  if ord.status <> 'completed' then raise exception 'You can review once the order is completed'; end if;
  select * into r from public.order_reviews where order_id = p_order for update;
  if found then
    if r.user_id <> u then raise exception 'Only the customer who placed this order can review it'; end if;
    if r.created_at < now() - interval '30 days' then raise exception 'Reviews can only be edited for 30 days'; end if;
    if (select count(*) from (
          select edited_at from public.product_reviews where user_id = u and edited_at > now() - interval '1 day'
          union all
          select edited_at from public.order_reviews where user_id = u and edited_at > now() - interval '1 day'
        ) x) >= 30 then raise exception 'Too many edits today. Please try again tomorrow.'; end if;
    update public.order_reviews set rating = p_rating, comment = c, updated_at = now(), edited_at = now()
      where id = r.id returning * into r;
  else
    if (select count(*) from (
          select created_at from public.product_reviews where user_id = u and created_at > now() - interval '1 hour'
          union all
          select created_at from public.order_reviews where user_id = u and created_at > now() - interval '1 hour'
        ) x) >= 10 then raise exception 'You have posted many reviews in the last hour. Please try again later.'; end if;
    insert into public.order_reviews(order_id, vendor_id, user_id, rating, comment)
      values (p_order, ord.vendor_id, u, p_rating, c) returning * into r;
  end if;
  return public._orv_json(r, u);
end $$;

create or replace function public.vendor_order_reviews(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if public.vendor_role(p_vendor) is null and not public.is_admin() then raise exception 'Business not found'; end if;
  return jsonb_build_object(
    'summary', (select jsonb_build_object(
        'count', count(*), 'avg', round(avg(rating)::numeric, 2),
        'unreplied', count(*) filter (where not exists (select 1 from public.order_review_replies x where x.review_id = r.id)),
        'breakdown', jsonb_build_object(
          '5', count(*) filter (where rating=5), '4', count(*) filter (where rating=4),
          '3', count(*) filter (where rating=3), '2', count(*) filter (where rating=2),
          '1', count(*) filter (where rating=1)))
      from public.order_reviews r where vendor_id = p_vendor and status = 'visible'),
    'reviews', coalesce((select jsonb_agg(
        public._orv_json(r, auth.uid()) || jsonb_build_object('order_number', o.order_number, 'hidden_reason', r.hidden_reason)
        order by r.created_at desc)
      from (select * from public.order_reviews where vendor_id = p_vendor order by created_at desc limit 300) r
      join public.orders o on o.id = r.order_id), '[]'::jsonb));
end $$;

create or replace function public.vendor_order_review_reply(p_review uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.order_reviews; b text := public._rv_clean(p_body, 1000);
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select * into r from public.order_reviews where id = p_review;
  if not found then raise exception 'Review not found'; end if;
  if coalesce(public.vendor_role(r.vendor_id), '') not in ('admin','subadmin') then raise exception 'Only the business owner or a sub-admin can reply'; end if;
  if b is null then raise exception 'Write a reply first'; end if;
  perform public._rv_noimg(b);
  if length(b) > 1000 then raise exception 'The reply is too long (max 1000 characters)'; end if;
  insert into public.order_review_replies(review_id, vendor_id, body, by_user) values (p_review, r.vendor_id, b, auth.uid())
    on conflict (review_id) do update set body = excluded.body, by_user = excluded.by_user, updated_at = now();
  return jsonb_build_object('review_id', p_review, 'body', b);
end $$;

-- Extend shop_service_rating: shop/service stars now include order-review ratings as well as
-- optional product-review service ratings. Product averages are unchanged.
create or replace function public.shop_service_rating(p_vendor uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'service_avg', (select round(avg(x)::numeric, 2) from (
        select service_rating as x from public.product_reviews where vendor_id = p_vendor and status = 'visible' and service_rating is not null
        union all
        select rating from public.order_reviews where vendor_id = p_vendor and status = 'visible') s),
    'service_count', (select count(*) from (
        select 1 from public.product_reviews where vendor_id = p_vendor and status = 'visible' and service_rating is not null
        union all
        select 1 from public.order_reviews where vendor_id = p_vendor and status = 'visible') s),
    'product_avg', (select round(avg(rating)::numeric, 2) from public.product_reviews where vendor_id = p_vendor and status = 'visible'),
    'review_count', (select count(*) from public.product_reviews where vendor_id = p_vendor and status = 'visible'),
    'order_avg', (select round(avg(rating)::numeric, 2) from public.order_reviews where vendor_id = p_vendor and status = 'visible'),
    'order_count', (select count(*) from public.order_reviews where vendor_id = p_vendor and status = 'visible'));
$$;

revoke all on function public.order_review_get(uuid), public.order_reviews_for_orders(uuid[]),
  public.order_review_submit(uuid,int,text), public.vendor_order_reviews(uuid),
  public.vendor_order_review_reply(uuid,text) from public, anon;
grant execute on function public.order_review_get(uuid), public.order_reviews_for_orders(uuid[]),
  public.order_review_submit(uuid,int,text), public.vendor_order_reviews(uuid),
  public.vendor_order_review_reply(uuid,text) to authenticated;
-- shop_service_rating already granted to anon + authenticated; CREATE OR REPLACE keeps privileges.

notify pgrst, 'reload schema';
