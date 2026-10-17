-- Carriacou Connect v0.5 : two-way order Notes (vendor <-> customer)
-- Run this whole file once in Supabase Dashboard > SQL Editor (after schema.sql and orders.sql). Safe to re-run.
-- NOTE for Supabase: pg-safeupdate is on, so every UPDATE / DELETE here has a WHERE clause.

-- ---------- notes table ----------
create table if not exists public.order_notes (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  author_id   uuid not null references auth.users(id) on delete cascade,
  author_role text not null check (author_role in ('consumer','vendor')),
  author_name text,
  body        text not null check (char_length(body) between 1 and 1000 and btrim(body) <> ''),
  created_at  timestamptz not null default now()
);
create index if not exists order_notes_order_idx on public.order_notes(order_id, created_at);

-- ---------- unread tracking: one row per (order, person) ----------
create table if not exists public.order_note_reads (
  order_id     uuid not null references public.orders(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (order_id, user_id)
);

-- ---------- helper: is the current user a party to this order? (consumer or the vendor's owner) ----------
create or replace function public.is_order_party(p_order uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.orders o
    where o.id = p_order
      and (o.consumer_id = auth.uid()
           or exists (select 1 from public.vendors v where v.id = o.vendor_id and v.owner_id = auth.uid())));
$$;
revoke all on function public.is_order_party(uuid) from public, anon;
grant execute on function public.is_order_party(uuid) to authenticated;

-- ---------- insert guard: trim, name snapshot, flood limits ----------
-- Max 30 notes per order (both sides together) and max 10 notes per person per minute.
create or replace function public.order_notes_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  new.body := btrim(new.body);
  new.created_at := now();
  perform pg_advisory_xact_lock(hashtext(new.order_id::text));   -- serialise inserts per order so the cap is exact
  if (select count(*) from public.order_notes where order_id = new.order_id) >= 30 then
    raise exception 'This order has reached the limit of 30 notes. Please contact the other party by phone.';
  end if;
  if (select count(*) from public.order_notes where author_id = new.author_id and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'You are sending notes too quickly. Please wait a minute.';
  end if;
  if new.author_role = 'vendor' then
    select v.name into nm from public.orders o join public.vendors v on v.id = o.vendor_id where o.id = new.order_id;
  else
    select coalesce(nullif(btrim(p.full_name),''), nullif(btrim(o.contact_name),'')) into nm
      from public.orders o left join public.profiles p on p.id = o.consumer_id where o.id = new.order_id;
  end if;
  new.author_name := left(coalesce(nm, case new.author_role when 'vendor' then 'Vendor' else 'Customer' end), 80);
  return new;
end $$;
drop trigger if exists trg_order_notes_insert on public.order_notes;
create trigger trg_order_notes_insert before insert on public.order_notes
  for each row execute function public.order_notes_before_insert();

-- ---------- Row Level Security ----------
alter table public.order_notes enable row level security;
alter table public.order_note_reads enable row level security;

-- read: only the order's customer or the order's vendor owner (admins can read too)
drop policy if exists order_notes_select on public.order_notes;
create policy order_notes_select on public.order_notes for select
  using (public.is_order_party(order_id) or public.is_admin());

-- insert: you must be the author, and the role must match your side of THIS order
drop policy if exists order_notes_insert on public.order_notes;
create policy order_notes_insert on public.order_notes for insert
  with check (
    author_id = auth.uid()
    and exists (select 1 from public.orders o
      where o.id = order_id
        and ((author_role = 'consumer' and o.consumer_id = auth.uid())
          or (author_role = 'vendor' and exists (select 1 from public.vendors v where v.id = o.vendor_id and v.owner_id = auth.uid())))));

-- no update / delete policies at all (notes are permanent); reads rows are only touched by mark_order_notes_read()
drop policy if exists order_notes_update on public.order_notes;
drop policy if exists order_notes_delete on public.order_notes;
drop policy if exists order_note_reads_select on public.order_note_reads;
create policy order_note_reads_select on public.order_note_reads for select using (user_id = auth.uid());

-- ---------- grants ----------
revoke all on public.order_notes, public.order_note_reads from anon, authenticated;
grant select on public.order_notes to authenticated;
grant insert (order_id, author_id, author_role, body) on public.order_notes to authenticated;
grant select on public.order_note_reads to authenticated;

-- ---------- mark an order's notes as read for the current user ----------
create or replace function public.mark_order_notes_read(p_order_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_order_party(p_order_id) then return; end if;
  insert into public.order_note_reads(order_id, user_id, last_read_at) values (p_order_id, auth.uid(), now())
  on conflict (order_id, user_id) do update set last_read_at = now()
  where public.order_note_reads.order_id = p_order_id and public.order_note_reads.user_id = auth.uid();
end $$;
revoke all on function public.mark_order_notes_read(uuid) from public, anon;
grant execute on function public.mark_order_notes_read(uuid) to authenticated;

-- ---------- per-order note counts for the dashboards (RLS applies: only your own orders) ----------
create or replace function public.order_note_summary()
returns table(oid uuid, total integer, unread integer, last_at timestamptz)
language sql stable security invoker set search_path = public as $$
  select n.order_id, count(*)::int,
         (count(*) filter (where n.author_id <> auth.uid() and n.created_at > coalesce(r.last_read_at, '-infinity')))::int,
         max(n.created_at)
    from public.order_notes n
    left join public.order_note_reads r on r.order_id = n.order_id and r.user_id = auth.uid()
   group by n.order_id;
$$;
revoke all on function public.order_note_summary() from public, anon;
grant execute on function public.order_note_summary() to authenticated;

-- make the API pick up the new tables and functions right away
notify pgrst, 'reload schema';
