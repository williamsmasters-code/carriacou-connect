-- v1.18 SHOP-OWNED GIFT CARD TRACKER (record keeping only).
-- Shops that sell their OWN gift cards (off-platform, or as a normal product order) can record and track them here.
-- Carriacou Connect only keeps the record: it never holds, sells, pays out or guarantees money for these cards.
-- Separate from the admin Carriacou Connect gift cards bought with CC Points (wallet_repurpose.sql).
-- Access: Plus+ plan and higher can issue. Owner + sub-admins issue / adjust / void; staff can look up and redeem.
-- A shop that later drops below Plus+ keeps read, redeem and void on existing cards (so it can honour them) but cannot issue new ones.
-- Platform admin: read-only. Run AFTER shop_layouts.sql. Idempotent; ends with notify pgrst.

create table if not exists public.shop_gift_cards (
  id            uuid primary key default gen_random_uuid(),
  vendor_id     uuid not null references public.vendors(id) on delete cascade,
  code          text not null check (code ~ '^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$'),
  initial_cents bigint not null check (initial_cents between 100 and 10000000),
  balance_cents bigint not null check (balance_cents >= 0),
  issued_at     timestamptz not null default now(),
  buyer_name    text check (buyer_name is null or length(buyer_name) <= 120),
  buyer_contact text check (buyer_contact is null or length(buyer_contact) <= 160),
  expires_on    date,
  status        text not null default 'active' check (status in ('active','used','void')),
  note          text check (note is null or length(note) <= 300),
  void_reason   text check (void_reason is null or length(void_reason) <= 300),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  unique (vendor_id, code)
);
create index if not exists shop_gift_cards_vendor_idx on public.shop_gift_cards(vendor_id, issued_at desc);

create table if not exists public.shop_gift_card_events (
  id             bigserial primary key,
  card_id        uuid not null references public.shop_gift_cards(id) on delete cascade,
  vendor_id      uuid not null references public.vendors(id) on delete cascade,
  kind           text not null check (kind in ('issue','redeem','adjust','void')),
  amount_cents   bigint not null default 0,
  balance_after  bigint not null check (balance_after >= 0),
  note           text check (note is null or length(note) <= 300),
  by_user        uuid,
  created_at     timestamptz not null default now()
);
create index if not exists shop_gift_card_events_card_idx on public.shop_gift_card_events(card_id, created_at);
create index if not exists shop_gift_card_events_vendor_idx on public.shop_gift_card_events(vendor_id, created_at desc);

create table if not exists public.shop_gift_card_settings (
  vendor_id     uuid primary key references public.vendors(id) on delete cascade,
  public_check  boolean not null default false,
  updated_at    timestamptz not null default now()
);

-- RLS on every new table. Reads: members of that shop, or the platform admin. No direct writes for anyone (RPCs only).
alter table public.shop_gift_cards enable row level security;
alter table public.shop_gift_card_events enable row level security;
alter table public.shop_gift_card_settings enable row level security;
drop policy if exists sgc_read on public.shop_gift_cards;
create policy sgc_read on public.shop_gift_cards for select to authenticated using (public.vendor_role(vendor_id) is not null or public.is_admin());
drop policy if exists sgce_read on public.shop_gift_card_events;
create policy sgce_read on public.shop_gift_card_events for select to authenticated using (public.vendor_role(vendor_id) is not null or public.is_admin());
drop policy if exists sgcs_read on public.shop_gift_card_settings;
create policy sgcs_read on public.shop_gift_card_settings for select to authenticated using (public.vendor_role(vendor_id) is not null or public.is_admin());
revoke all on public.shop_gift_cards, public.shop_gift_card_events, public.shop_gift_card_settings from public, anon, authenticated;
grant select on public.shop_gift_cards, public.shop_gift_card_events, public.shop_gift_card_settings to authenticated;
revoke all on sequence public.shop_gift_card_events_id_seq from public, anon, authenticated;

-- Plus+ (rank 3) or higher, read from the server (never trusted from the browser)
create or replace function public._sgc_tier_ok(p_vendor uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select t.rank >= 3 from public.vendors v join public.tier_limits t on t.tier = v.tier where v.id = p_vendor), false);
$$;
-- may this user use the tracker? p_need: 'read' (any member or admin), 'redeem' (any member), 'manage' (owner/subadmin)
create or replace function public._sgc_check(p_vendor uuid, p_need text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r text := public.vendor_role(p_vendor); has_cards boolean;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_need = 'read' and r is null and public.is_admin() then return; end if;
  if r is null then raise exception 'Business not found'; end if;
  if p_need = 'manage' and r not in ('admin','subadmin') then raise exception 'Only the business owner or a sub-admin can do this'; end if;
  if not public._sgc_tier_ok(p_vendor) then
    select exists(select 1 from public.shop_gift_cards where vendor_id = p_vendor) into has_cards;
    if p_need = 'issue' or not has_cards then raise exception 'The gift card tracker is part of the Plus+ plan and higher'; end if;
  end if;
end $$;
revoke all on function public._sgc_tier_ok(uuid), public._sgc_check(uuid, text) from public, anon, authenticated;

create or replace function public._sgc_json(c public.shop_gift_cards) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object('id', c.id, 'code', c.code, 'initial_cents', c.initial_cents, 'balance_cents', c.balance_cents,
    'issued_at', c.issued_at, 'buyer_name', c.buyer_name, 'buyer_contact', c.buyer_contact, 'expires_on', c.expires_on,
    'status', c.status, 'expired', (c.expires_on is not null and c.expires_on < (now() at time zone 'America/Grenada')::date),
    'note', c.note, 'void_reason', c.void_reason, 'updated_at', c.updated_at);
$$;
revoke all on function public._sgc_json(public.shop_gift_cards) from public, anon, authenticated;

create or replace function public._sgc_norm(p_code text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case when length(x) = 12 then substr(x,1,4)||'-'||substr(x,5,4)||'-'||substr(x,9,4) else x end
    from (select upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g')) x) s;
$$;

-- ISSUE: auto-generates a unique code per shop (12 chars from 31 unambiguous letters/digits)
create or replace function public.sgc_issue(p_vendor uuid, p_value_cents bigint, p_buyer_name text default null, p_buyer_contact text default null,
  p_expires_on date default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; k text; i int; tries int := 0; c public.shop_gift_cards;
begin
  perform public._sgc_check(p_vendor, 'manage');
  perform public._sgc_check(p_vendor, 'issue');
  if p_value_cents is null or p_value_cents < 100 or p_value_cents > 10000000 then raise exception 'Enter a value from EC$1 to EC$100,000'; end if;
  if p_expires_on is not null and p_expires_on < (now() at time zone 'America/Grenada')::date then raise exception 'The expiry date cannot be in the past'; end if;
  if (select count(*) from public.shop_gift_cards where vendor_id = p_vendor and issued_at > now() - interval '1 day') >= 500 then
    raise exception 'Daily limit reached (500 cards a day)'; end if;
  loop
    k := '';
    for i in 1..12 loop k := k || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    k := substr(k,1,4)||'-'||substr(k,5,4)||'-'||substr(k,9,4);
    exit when not exists (select 1 from public.shop_gift_cards where vendor_id = p_vendor and code = k);
    tries := tries + 1; if tries > 20 then raise exception 'Could not make a unique code, try again'; end if;
  end loop;
  insert into public.shop_gift_cards(vendor_id, code, initial_cents, balance_cents, buyer_name, buyer_contact, expires_on, note, created_by)
    values (p_vendor, k, p_value_cents, p_value_cents, nullif(btrim(coalesce(p_buyer_name,'')),''), nullif(btrim(coalesce(p_buyer_contact,'')),''),
            p_expires_on, nullif(btrim(coalesce(p_note,'')),''), auth.uid()) returning * into c;
  insert into public.shop_gift_card_events(card_id, vendor_id, kind, amount_cents, balance_after, note, by_user)
    values (c.id, p_vendor, 'issue', c.initial_cents, c.balance_cents, c.note, auth.uid());
  return public._sgc_json(c);
end $$;

create or replace function public.sgc_lookup(p_vendor uuid, p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.shop_gift_cards;
begin
  perform public._sgc_check(p_vendor, 'read');
  select * into c from public.shop_gift_cards where vendor_id = p_vendor and code = public._sgc_norm(p_code);
  if not found then raise exception 'No card with that code in this shop'; end if;
  return public._sgc_json(c) || jsonb_build_object('events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'amount_cents', e.amount_cents,
    'balance_after', e.balance_after, 'note', e.note, 'by', coalesce(p.full_name, 'Team member'), 'at', e.created_at) order by e.id)
    from public.shop_gift_card_events e left join public.profiles p on p.id = e.by_user where e.card_id = c.id), '[]'::jsonb));
end $$;

-- REDEEM part or all of the balance (row lock, never below zero, never on void/used/expired cards)
create or replace function public.sgc_redeem(p_vendor uuid, p_code text, p_amount_cents bigint, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.shop_gift_cards;
begin
  perform public._sgc_check(p_vendor, 'redeem');
  select * into c from public.shop_gift_cards where vendor_id = p_vendor and code = public._sgc_norm(p_code) for update;
  if not found then raise exception 'No card with that code in this shop'; end if;
  if c.status = 'void' then raise exception 'This card was voided'; end if;
  if c.status = 'used' or c.balance_cents = 0 then raise exception 'This card is used up'; end if;
  if c.expires_on is not null and c.expires_on < (now() at time zone 'America/Grenada')::date then raise exception 'This card expired on %', c.expires_on; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'Enter an amount above zero'; end if;
  if p_amount_cents > c.balance_cents then raise exception 'That is more than the balance (EC$%)', to_char(c.balance_cents / 100.0, 'FM999999990.00'); end if;
  update public.shop_gift_cards set balance_cents = balance_cents - p_amount_cents,
    status = case when balance_cents - p_amount_cents = 0 then 'used' else 'active' end, updated_at = now()
    where id = c.id returning * into c;
  insert into public.shop_gift_card_events(card_id, vendor_id, kind, amount_cents, balance_after, note, by_user)
    values (c.id, p_vendor, 'redeem', -p_amount_cents, c.balance_cents, nullif(btrim(coalesce(p_note,'')),''), auth.uid());
  return public._sgc_json(c);
end $$;

-- ADJUST (owner/sub-admin, reason required): correct a mistake. Balance stays between 0 and the initial value.
create or replace function public.sgc_adjust(p_vendor uuid, p_code text, p_delta_cents bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.shop_gift_cards; nb bigint;
begin
  perform public._sgc_check(p_vendor, 'manage');
  if length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'Give a reason (at least 3 characters)'; end if;
  select * into c from public.shop_gift_cards where vendor_id = p_vendor and code = public._sgc_norm(p_code) for update;
  if not found then raise exception 'No card with that code in this shop'; end if;
  if c.status = 'void' then raise exception 'This card was voided'; end if;
  if p_delta_cents is null or p_delta_cents = 0 then raise exception 'Enter an adjustment other than zero'; end if;
  nb := c.balance_cents + p_delta_cents;
  if nb < 0 or nb > c.initial_cents then raise exception 'The balance must stay between EC$0 and the initial value'; end if;
  update public.shop_gift_cards set balance_cents = nb, status = case when nb = 0 then 'used' else 'active' end, updated_at = now()
    where id = c.id returning * into c;
  insert into public.shop_gift_card_events(card_id, vendor_id, kind, amount_cents, balance_after, note, by_user)
    values (c.id, p_vendor, 'adjust', p_delta_cents, nb, left(btrim(p_reason), 300), auth.uid());
  return public._sgc_json(c);
end $$;

create or replace function public.sgc_void(p_vendor uuid, p_code text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.shop_gift_cards;
begin
  perform public._sgc_check(p_vendor, 'manage');
  if length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'Give a reason (at least 3 characters)'; end if;
  select * into c from public.shop_gift_cards where vendor_id = p_vendor and code = public._sgc_norm(p_code) for update;
  if not found then raise exception 'No card with that code in this shop'; end if;
  if c.status = 'void' then raise exception 'This card is already void'; end if;
  update public.shop_gift_cards set status = 'void', void_reason = left(btrim(p_reason), 300), updated_at = now() where id = c.id returning * into c;
  insert into public.shop_gift_card_events(card_id, vendor_id, kind, amount_cents, balance_after, note, by_user)
    values (c.id, p_vendor, 'void', 0, c.balance_cents, left(btrim(p_reason), 300), auth.uid());
  return public._sgc_json(c);
end $$;

-- LIST + summary (members and platform admin). Also used for the CSV export.
create or replace function public.sgc_list(p_vendor uuid, p_status text default null, p_limit integer default 500) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._sgc_check(p_vendor, 'read');
  return jsonb_build_object(
    'tier_ok', public._sgc_tier_ok(p_vendor),
    'public_check', coalesce((select public_check from public.shop_gift_card_settings where vendor_id = p_vendor), false),
    'summary', (select jsonb_build_object('count', count(*), 'active', count(*) filter (where status = 'active'),
        'outstanding_cents', coalesce(sum(balance_cents) filter (where status = 'active'), 0),
        'issued_cents', coalesce(sum(initial_cents), 0)) from public.shop_gift_cards where vendor_id = p_vendor),
    'cards', coalesce((select jsonb_agg(public._sgc_json(c) order by c.issued_at desc) from (select * from public.shop_gift_cards
        where vendor_id = p_vendor and (p_status is null or status = p_status) order by issued_at desc limit least(greatest(coalesce(p_limit,500),1),5000)) c), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(x order by (x->>'id')::bigint desc) from (select jsonb_build_object('id', e.id, 'code', g.code, 'kind', e.kind,
        'amount_cents', e.amount_cents, 'balance_after', e.balance_after, 'note', e.note, 'by', coalesce(p.full_name, 'Team member'), 'at', e.created_at) x
        from public.shop_gift_card_events e join public.shop_gift_cards g on g.id = e.card_id left join public.profiles p on p.id = e.by_user
        where e.vendor_id = p_vendor order by e.id desc limit 200) s), '[]'::jsonb));
end $$;

create or replace function public.sgc_set_public_check(p_vendor uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._sgc_check(p_vendor, 'manage');
  if public.vendor_role(p_vendor) <> 'admin' then raise exception 'Only the business owner can change this'; end if;
  if p_on and not public._sgc_tier_ok(p_vendor) then raise exception 'The gift card tracker is part of the Plus+ plan and higher'; end if;
  insert into public.shop_gift_card_settings(vendor_id, public_check, updated_at) values (p_vendor, coalesce(p_on,false), now())
    on conflict (vendor_id) do update set public_check = excluded.public_check, updated_at = now();
  return jsonb_build_object('public_check', coalesce(p_on,false));
end $$;

-- OPTIONAL public balance check on the shop page (only if the owner switched it on). Shows balance, status and expiry only.
create or replace function public.sgc_public_balance(p_vendor uuid, p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.shop_gift_cards;
begin
  if not coalesce((select public_check from public.shop_gift_card_settings where vendor_id = p_vendor), false)
     or not public._sgc_tier_ok(p_vendor) then raise exception 'This shop does not offer an online balance check'; end if;
  if length(public._sgc_norm(p_code)) <> 14 then raise exception 'Enter the 12-character code on your card'; end if;
  select * into c from public.shop_gift_cards where vendor_id = p_vendor and code = public._sgc_norm(p_code);
  if not found then raise exception 'No card with that code. Check the code or ask the shop.'; end if;
  return jsonb_build_object('balance_cents', c.balance_cents, 'status', c.status, 'expires_on', c.expires_on,
    'expired', (c.expires_on is not null and c.expires_on < (now() at time zone 'America/Grenada')::date));
end $$;

revoke all on function public.sgc_issue(uuid,bigint,text,text,date,text), public.sgc_lookup(uuid,text), public.sgc_redeem(uuid,text,bigint,text),
  public.sgc_adjust(uuid,text,bigint,text), public.sgc_void(uuid,text,text), public.sgc_list(uuid,text,integer),
  public.sgc_set_public_check(uuid,boolean), public.sgc_public_balance(uuid,text), public._sgc_norm(text) from public, anon;
grant execute on function public.sgc_issue(uuid,bigint,text,text,date,text), public.sgc_lookup(uuid,text), public.sgc_redeem(uuid,text,bigint,text),
  public.sgc_adjust(uuid,text,bigint,text), public.sgc_void(uuid,text,text), public.sgc_list(uuid,text,integer),
  public.sgc_set_public_check(uuid,boolean) to authenticated;
grant execute on function public.sgc_public_balance(uuid,text) to anon, authenticated;

-- v1.18 home page live stats: ONLY two numbers (approved, non-sample shops; active products in those shops). Safe for anon.
create or replace function public.public_market_counts() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'vendors', (select count(*) from public.vendors v where v.status = 'approved' and not v.is_sample),
    'items',   (select count(*) from public.products p join public.vendors v on v.id = p.vendor_id
                 where p.active and v.status = 'approved' and not v.is_sample));
$$;
revoke all on function public.public_market_counts() from public;
grant execute on function public.public_market_counts() to anon, authenticated;

notify pgrst, 'reload schema';
