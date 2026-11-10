-- v1.21.1 review edit window: 24 hours from the original created_at (not the last edit).
-- Idempotent. Run AFTER reviews.sql and order_reviews.sql (safe to run twice). Ends with notify pgrst.
-- Applies to both product reviews (review_submit / _rv_json) and order reviews (order_review_submit / _orv_json).
-- Vendor reply rules are unchanged. Error on a late edit: Reviews can only be edited within 24 hours of posting.
-- Do not grant direct writes; this file only replaces SECURITY DEFINER helpers and submit/get JSON RPCs.

create or replace function public._rv_edit_open(p_created timestamptz)
returns boolean
language sql stable
as $$
  select p_created is not null and p_created >= now() - interval '24 hours';
$$;
revoke all on function public._rv_edit_open(timestamptz) from public, anon, authenticated;

create or replace function public._rv_json(r public.product_reviews, p_me uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', r.id, 'product_id', r.product_id, 'vendor_id', r.vendor_id, 'rating', r.rating, 'service_rating', r.service_rating,
    'comment', r.comment, 'status', r.status, 'helpful', r.helpful_count, 'created_at', r.created_at, 'edited_at', r.edited_at,
    'author', coalesce(nullif(split_part(btrim(coalesce(pf.full_name,'')), ' ', 1), ''), 'Customer')
              || coalesce(' ' || nullif(left(split_part(btrim(coalesce(pf.full_name,'')), ' ', 2), 1), '') || '.', ''),
    'verified', true, 'mine', r.user_id = p_me,
    'can_edit', r.user_id = p_me and public._rv_edit_open(r.created_at),
    'voted', exists(select 1 from public.review_helpful h where h.review_id = r.id and h.user_id = p_me),
    'reply', (select jsonb_build_object('body', x.body, 'at', x.updated_at) from public.review_replies x where x.review_id = r.id))
  from (select 1) s left join public.profiles pf on pf.id = r.user_id;
$$;
revoke all on function public._rv_json(public.product_reviews, uuid) from public, anon, authenticated;

-- what can I review for this product? (completed orders of mine containing it)

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
    if not public._rv_edit_open(r.created_at) then raise exception 'Reviews can only be edited within 24 hours of posting'; end if;
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

create or replace function public._orv_json(r public.order_reviews, p_me uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', r.id, 'order_id', r.order_id, 'vendor_id', r.vendor_id, 'rating', r.rating,
    'comment', r.comment, 'status', r.status, 'hidden_reason', r.hidden_reason,
    'created_at', r.created_at, 'edited_at', r.edited_at,
    'author', coalesce(nullif(split_part(btrim(coalesce(pf.full_name,'')), ' ', 1), ''), 'Customer')
              || coalesce(' ' || nullif(left(split_part(btrim(coalesce(pf.full_name,'')), ' ', 2), 1), '') || '.', ''),
    'verified', true, 'mine', r.user_id = p_me,
    'can_edit', r.user_id = p_me and public._rv_edit_open(r.created_at),
    'reply', (select jsonb_build_object('body', x.body, 'at', x.updated_at) from public.order_review_replies x where x.review_id = r.id))
  from (select 1) s left join public.profiles pf on pf.id = r.user_id;
$$;
revoke all on function public._orv_json(public.order_reviews, uuid) from public, anon, authenticated;

-- one order's review state for the signed-in customer (or null review if eligible and not yet reviewed)

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
    if not public._rv_edit_open(r.created_at) then raise exception 'Reviews can only be edited within 24 hours of posting'; end if;
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

notify pgrst, 'reload schema';
