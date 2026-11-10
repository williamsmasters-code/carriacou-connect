-- v1.21 account cart: one cart per signed-in user, follows the account across devices.
-- Idempotent. Run AFTER reviews.sql / payments_mock.sql / order_reviews.sql (needs products, including stock_qty when present).
-- Do not grant direct writes; clients use the SECURITY DEFINER RPCs.

create table if not exists public.account_carts (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  qty        smallint not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, product_id),
  constraint account_carts_qty_check check (qty >= 1 and qty <= 99)
);
create index if not exists account_carts_user_idx on public.account_carts (user_id, updated_at desc);

alter table public.account_carts enable row level security;
alter table public.account_carts force row level security;

drop policy if exists account_carts_select_own on public.account_carts;
create policy account_carts_select_own on public.account_carts
  for select to authenticated
  using (user_id = auth.uid());

revoke all on table public.account_carts from public, anon, authenticated;
grant select on table public.account_carts to authenticated;

-- Helpers and RPCs: drop first so this file can be re-run after a signature change.
drop function if exists public._cart_parse(jsonb);
drop function if exists public._cart_clamp(uuid, integer);
drop function if exists public._cart_prune(uuid);
drop function if exists public._cart_dump(uuid);
drop function if exists public.cart_get();
drop function if exists public.cart_set(uuid, integer);
drop function if exists public.cart_replace(jsonb);
drop function if exists public.cart_merge(jsonb);
drop function if exists public.cart_remove(uuid[]);

-- Parse { "uuid": qty } or [{product_id, qty|quantity}] (and an optional {items:...} wrapper). Invalid ids are skipped.
create function public._cart_parse(p_cart jsonb)
returns table(product_id uuid, qty int)
language plpgsql immutable as $$
declare
  k text; v jsonb; e jsonb; q int; pid uuid; src jsonb;
begin
  if p_cart is null then return; end if;
  src := p_cart;
  if jsonb_typeof(src)='object' and src ? 'items' then src := src->'items'; end if;
  if jsonb_typeof(src)='object' then
    for k, v in select key, value from jsonb_each(src) loop
      if k ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        if jsonb_typeof(v) in ('number','string') then
          begin q := floor(v::text::numeric)::int; exception when others then q := 0; end;
        elsif jsonb_typeof(v)='object' then
          begin q := coalesce((v->>'qty')::int,(v->>'quantity')::int,0); exception when others then q := 0; end;
        else q := 0; end if;
        product_id := k::uuid; qty := q; return next;
      end if;
    end loop;
  elsif jsonb_typeof(src)='array' then
    for e in select value from jsonb_array_elements(src) loop
      begin
        pid := nullif(coalesce(e->>'product_id', e->>'id'),'')::uuid;
      exception when others then pid := null;
      end;
      if pid is null then continue; end if;
      begin q := coalesce((e->>'qty')::int,(e->>'quantity')::int,0); exception when others then q := 0; end;
      product_id := pid; qty := q; return next;
    end loop;
  end if;
end;
$$;

-- 0 = drop the line (missing, inactive, qty<=0, or out of stock). Caps at 99 and at stock_qty when that column is present and not null.
create function public._cart_clamp(p_product uuid, p_qty int)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare act boolean; stock int; q int;
begin
  if p_product is null then return 0; end if;
  q := coalesce(p_qty, 0);
  if q <= 0 then return 0; end if;
  q := least(99, q);
  select p.active,
         case when to_jsonb(p) ? 'stock_qty' then (to_jsonb(p)->>'stock_qty')::int else null end
    into act, stock
    from public.products p
   where p.id = p_product;
  if not found or act is not true then return 0; end if;
  if stock is not null then
    q := least(q, greatest(stock, 0));
    if q <= 0 then return 0; end if;
  end if;
  return q;
end;
$$;

create function public._cart_prune(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user is null then return; end if;
  delete from public.account_carts a
   where a.user_id = p_user
     and public._cart_clamp(a.product_id, a.qty) = 0;
  update public.account_carts a
     set qty = public._cart_clamp(a.product_id, a.qty),
         updated_at = now()
   where a.user_id = p_user
     and public._cart_clamp(a.product_id, a.qty) is distinct from a.qty;
end;
$$;

create function public._cart_dump(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._cart_prune(p_user);
  return coalesce((select jsonb_object_agg(product_id::text, qty) from public.account_carts where user_id = p_user), '{}'::jsonb);
end;
$$;

create function public.cart_get()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  return public._cart_dump(auth.uid());
end;
$$;

create function public.cart_set(p_product uuid, p_qty int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare u uuid; q int;
begin
  u := auth.uid();
  if u is null then raise exception 'Please log in'; end if;
  q := public._cart_clamp(p_product, p_qty);
  if q = 0 then
    delete from public.account_carts where user_id = u and product_id = p_product;
  else
    insert into public.account_carts(user_id, product_id, qty, updated_at)
    values (u, p_product, q, now())
    on conflict (user_id, product_id) do update
      set qty = excluded.qty, updated_at = now();
  end if;
  return public._cart_dump(u);
end;
$$;

create function public.cart_replace(p_cart jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare u uuid; r record; q int;
begin
  u := auth.uid();
  if u is null then raise exception 'Please log in'; end if;
  delete from public.account_carts where user_id = u;
  for r in select * from public._cart_parse(p_cart) loop
    q := public._cart_clamp(r.product_id, r.qty);
    if q > 0 then
      insert into public.account_carts(user_id, product_id, qty, updated_at)
      values (u, r.product_id, q, now())
      on conflict (user_id, product_id) do update
        set qty = excluded.qty, updated_at = now();
    end if;
  end loop;
  return public._cart_dump(u);
end;
$$;

-- Sum incoming quantities with the existing account cart, then clamp. Used on guest -> sign-in merge.
create function public.cart_merge(p_cart jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare u uuid; r record; q int; cur int;
begin
  u := auth.uid();
  if u is null then raise exception 'Please log in'; end if;
  for r in select * from public._cart_parse(p_cart) loop
    select qty into cur from public.account_carts where user_id = u and product_id = r.product_id;
    q := public._cart_clamp(r.product_id, coalesce(cur, 0) + coalesce(r.qty, 0));
    if q = 0 then
      delete from public.account_carts where user_id = u and product_id = r.product_id;
    else
      insert into public.account_carts(user_id, product_id, qty, updated_at)
      values (u, r.product_id, q, now())
      on conflict (user_id, product_id) do update
        set qty = excluded.qty, updated_at = now();
    end if;
  end loop;
  return public._cart_dump(u);
end;
$$;

-- After a successful order, drop the product ids that were just purchased (other lines stay).
create function public.cart_remove(p_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare u uuid;
begin
  u := auth.uid();
  if u is null then raise exception 'Please log in'; end if;
  if p_ids is not null then
    delete from public.account_carts where user_id = u and product_id = any(p_ids);
  end if;
  return public._cart_dump(u);
end;
$$;

revoke all on function public._cart_parse(jsonb) from public, anon, authenticated;
revoke all on function public._cart_clamp(uuid, integer) from public, anon, authenticated;
revoke all on function public._cart_prune(uuid) from public, anon, authenticated;
revoke all on function public._cart_dump(uuid) from public, anon, authenticated;
revoke all on function public.cart_get() from public, anon;
revoke all on function public.cart_set(uuid, integer) from public, anon;
revoke all on function public.cart_replace(jsonb) from public, anon;
revoke all on function public.cart_merge(jsonb) from public, anon;
revoke all on function public.cart_remove(uuid[]) from public, anon;
grant execute on function public.cart_get() to authenticated;
grant execute on function public.cart_set(uuid, integer) to authenticated;
grant execute on function public.cart_replace(jsonb) to authenticated;
grant execute on function public.cart_merge(jsonb) to authenticated;
grant execute on function public.cart_remove(uuid[]) to authenticated;

notify pgrst, 'reload schema';
