-- =====================================================================================================
-- wallet_repurpose.sql (v1.16) - CC Points (Rewards), Points Store gift cards, vendor Platform Funds,
-- per-order platform fees, vendor exit refunds. Implements Pay_Design_Notes.txt 'Wallet repurpose plan' (Steps 47-49).
-- RUN ORDER: LAST, after order_pay_requests.sql. Needs: orders/order_payments/_offpay_refresh (offline_payments.sql),
--   _opr_balance (order_pay_requests.sql), transactions (pay.sql), vendor_perm (staff.sql), is_admin (schema.sql),
--   _rt_add/_rt_team/_rt_money (realtime.sql). Idempotent. Every UPDATE has a WHERE. No DELETE.
-- Principles:
--   * The platform never holds or moves customers' money. The old play-money wallet (top-ups, transfers, wallet pay,
--     POS charges, Pay balance, payment requests) is PARKED behind platform_flags.wallet_mode ('test' | 'off', default 'off').
--     Nothing is dropped; set wallet_mode = 'test' to bring the parked test wallet back.
--   * CC Points are not money: earned only from completed orders (1 point per EC$1), never bought, transferred or cashed out.
--     A balance expires after points_expiry_days (365) with no points earned.
--   * Gift cards come only from the Points Store (paid with points), belong to one customer, work only at one shop on the
--     platform. When used, the platform credits the shop against its subscription (rollover ledger).
--   * Platform Funds = vendor prepaid credit (TEST MODE ONLY for now), spendable only on Carriacou Connect services.
--   * Ledgers are append-only (no update/delete for anyone).
-- =====================================================================================================

-- ---------- feature flags / settings (single row) ----------
create table if not exists public.platform_flags (
  id                       int primary key default 1 check (id = 1),
  wallet_mode              text not null default 'off' check (wallet_mode in ('test','off')),
  rewards_enabled          boolean not null default true,
  vendor_credit_enabled    boolean not null default true,
  gift_cards_enabled       boolean not null default true,
  credit_test_mode         boolean not null default true,      -- Platform Funds are play money until a processor is live
  fee_card_pct             numeric(5,2) not null default 1.00 check (fee_card_pct between 0 and 20),
  fee_direct_pct           numeric(5,2) not null default 2.00 check (fee_direct_pct between 0 and 20),
  fee_refund_pct           numeric(5,2) not null default 100.00 check (fee_refund_pct between 0 and 100), -- provisional: full refund
  points_per_ec            int not null default 1 check (points_per_ec between 0 and 100),
  points_expiry_days       int not null default 365 check (points_expiry_days between 30 and 3650),
  giftcard_tiers           text[] not null default array['plus','pro','enterprise'],  -- UNDECIDED: default Plus+ and above
  giftcard_points_per_ec   jsonb not null default '{"plus":100,"pro":90,"enterprise":80}',  -- EXAMPLE prices, not decided
  giftcard_values_cents    int[] not null default array[1000,2500,5000],
  giftcard_cap_cents_month int not null default 50000 check (giftcard_cap_cents_month >= 0),  -- per shop per calendar month
  giftcard_expiry_days     int not null default 365,            -- ASSUMED same as points (1 year without use)
  topup_test_max_cents     int not null default 50000,
  updated_at               timestamptz not null default now(),
  updated_by               uuid
);
insert into public.platform_flags(id) values (1) on conflict (id) do nothing;
alter table public.platform_flags enable row level security;
revoke all on public.platform_flags from public, anon, authenticated;

create or replace function public._flags() returns public.platform_flags
language sql stable security definer set search_path = public, pg_temp as $$ select * from public.platform_flags where id = 1 $$;
revoke all on function public._flags() from public, anon, authenticated;

create or replace function public.platform_flags_get() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$ select to_jsonb(f) - 'updated_by' from public.platform_flags f where id = 1 $$;
grant execute on function public.platform_flags_get() to anon, authenticated;

create or replace function public.admin_set_flags(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare k text; allowed text[] := array['wallet_mode','rewards_enabled','vendor_credit_enabled','gift_cards_enabled','fee_card_pct','fee_direct_pct',
  'fee_refund_pct','points_per_ec','points_expiry_days','giftcard_tiers','giftcard_points_per_ec','giftcard_values_cents','giftcard_cap_cents_month','giftcard_expiry_days'];
begin
  if not public.is_admin() then raise exception 'Only the platform admin can change settings'; end if;
  for k in select jsonb_object_keys(p) loop if not k = any(allowed) then raise exception 'Unknown setting %', k; end if; end loop;
  update public.platform_flags set
    wallet_mode = coalesce(p->>'wallet_mode', wallet_mode),
    rewards_enabled = coalesce((p->>'rewards_enabled')::boolean, rewards_enabled),
    vendor_credit_enabled = coalesce((p->>'vendor_credit_enabled')::boolean, vendor_credit_enabled),
    gift_cards_enabled = coalesce((p->>'gift_cards_enabled')::boolean, gift_cards_enabled),
    fee_card_pct = coalesce((p->>'fee_card_pct')::numeric, fee_card_pct),
    fee_direct_pct = coalesce((p->>'fee_direct_pct')::numeric, fee_direct_pct),
    fee_refund_pct = coalesce((p->>'fee_refund_pct')::numeric, fee_refund_pct),
    points_per_ec = coalesce((p->>'points_per_ec')::int, points_per_ec),
    points_expiry_days = coalesce((p->>'points_expiry_days')::int, points_expiry_days),
    giftcard_tiers = coalesce(case when p ? 'giftcard_tiers' then array(select jsonb_array_elements_text(p->'giftcard_tiers')) end, giftcard_tiers),
    giftcard_points_per_ec = coalesce(p->'giftcard_points_per_ec', giftcard_points_per_ec),
    giftcard_values_cents = coalesce(case when p ? 'giftcard_values_cents' then array(select (jsonb_array_elements_text(p->'giftcard_values_cents'))::int) end, giftcard_values_cents),
    giftcard_cap_cents_month = coalesce((p->>'giftcard_cap_cents_month')::int, giftcard_cap_cents_month),
    giftcard_expiry_days = coalesce((p->>'giftcard_expiry_days')::int, giftcard_expiry_days),
    updated_at = now(), updated_by = auth.uid()
  where id = 1;
  return public.platform_flags_get();
end $$;
revoke all on function public.admin_set_flags(jsonb) from public, anon;
grant execute on function public.admin_set_flags(jsonb) to authenticated;

-- shared append-only guard
create or replace function public._append_only() returns trigger language plpgsql as $$
begin raise exception '% is append-only', tg_table_name; end $$;

-- ---------- 1. park the money wallet (server side) ----------
-- Any new play-money movement except refunds of old test payments is refused while wallet_mode = 'off'.
create or replace function public.transactions_wallet_parked() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select wallet_mode from public.platform_flags where id = 1) = 'off' and new.type in ('topup_test','transfer','order_payment') then
    raise exception 'WALLET_PARKED: The money wallet is switched off. Carriacou Connect does not hold or move customer money; pay the shop directly.';
  end if;
  return new;
end $$;
revoke all on function public.transactions_wallet_parked() from public, anon, authenticated;
drop trigger if exists trg_transactions_wallet_parked on public.transactions;
create trigger trg_transactions_wallet_parked before insert on public.transactions for each row execute function public.transactions_wallet_parked();

create or replace function public.parked_wallet_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select wallet_mode from public.platform_flags where id = 1) = 'off' then
    raise exception 'WALLET_PARKED: % is switched off while the money wallet is parked.', case tg_table_name when 'pay_requests' then 'POS charge codes' else 'Payment requests' end;
  end if;
  return new;
end $$;
revoke all on function public.parked_wallet_guard() from public, anon, authenticated;
drop trigger if exists trg_pay_requests_parked on public.pay_requests;
create trigger trg_pay_requests_parked before insert on public.pay_requests for each row execute function public.parked_wallet_guard();
drop trigger if exists trg_order_pay_requests_parked on public.order_pay_requests;
create trigger trg_order_pay_requests_parked before insert on public.order_pay_requests for each row execute function public.parked_wallet_guard();

-- ---------- 2. CC Points ----------
create table if not exists public.cc_points_ledger (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  delta        int not null check (delta <> 0),
  kind         text not null check (kind in ('earn','reverse','redeem','expire','adjust')),
  order_id     uuid references public.orders(id) on delete set null,
  gift_card_id uuid,
  note         text check (note is null or char_length(note) <= 200),
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index if not exists cc_points_user_idx on public.cc_points_ledger(user_id, created_at desc);
create unique index if not exists cc_points_one_earn on public.cc_points_ledger(order_id) where kind = 'earn';
create unique index if not exists cc_points_one_reverse on public.cc_points_ledger(order_id) where kind = 'reverse';
alter table public.cc_points_ledger enable row level security;
drop policy if exists cc_points_read on public.cc_points_ledger;
create policy cc_points_read on public.cc_points_ledger for select to authenticated using (user_id = auth.uid() or public.is_admin());
revoke insert, update, delete, truncate on public.cc_points_ledger from public, anon, authenticated;
grant select on public.cc_points_ledger to authenticated;
drop trigger if exists trg_cc_points_append on public.cc_points_ledger;
create trigger trg_cc_points_append before update or delete on public.cc_points_ledger for each row execute function public._append_only();

create or replace function public._points_bal(p_user uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(delta), 0)::int from public.cc_points_ledger where user_id = p_user $$;
revoke all on function public._points_bal(uuid) from public, anon, authenticated;

-- lazy expiry: whole balance expires when no points were earned for points_expiry_days
create or replace function public._points_expire(p_user uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare last_earn timestamptz; b int; days int := (public._flags()).points_expiry_days;
begin
  perform pg_advisory_xact_lock(hashtext('pts:' || p_user::text));
  select max(created_at) into last_earn from public.cc_points_ledger where user_id = p_user and kind = 'earn';
  b := public._points_bal(p_user);
  if b > 0 and last_earn is not null and last_earn < now() - make_interval(days => days) then
    insert into public.cc_points_ledger(user_id, delta, kind, note) values (p_user, -b, 'expire', 'No points earned for ' || days || ' days');
  end if;
end $$;
revoke all on function public._points_expire(uuid) from public, anon, authenticated;

-- earn on completion; reverse on cancel / refund (after an earn)
create or replace function public.orders_points_trg() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags(); pts int; earned int;
begin
  if not f.rewards_enabled then return new; end if;
  if new.status = 'completed' and old.status is distinct from 'completed' and new.payment_status <> 'refunded' then
    pts := floor(new.total_xcd * f.points_per_ec)::int;
    if pts > 0 and not exists (select 1 from public.cc_points_ledger where order_id = new.id and kind = 'earn') then
      perform public._points_expire(new.consumer_id);
      insert into public.cc_points_ledger(user_id, delta, kind, order_id, note) values (new.consumer_id, pts, 'earn', new.id, 'Order ' || new.order_number);
      begin perform public._rt_add(new.consumer_id, 'points', 'You earned ' || pts || ' CC Points', 'Order ' || new.order_number || ' is complete. Points are rewards, not money.',
        'rewards.html', 'order', new.id, new.vendor_id, false); exception when undefined_function then null; end;
    end if;
  end if;
  if (new.status = 'cancelled' and old.status is distinct from 'cancelled') or (new.payment_status = 'refunded' and old.payment_status is distinct from 'refunded') then
    select delta into earned from public.cc_points_ledger where order_id = new.id and kind = 'earn';
    if earned is not null and not exists (select 1 from public.cc_points_ledger where order_id = new.id and kind = 'reverse') then
      -- never take a balance below zero (points already spent stay spent; the shortfall is written off)
      earned := least(earned, greatest(public._points_bal(new.consumer_id), 0));
      if earned > 0 then
        insert into public.cc_points_ledger(user_id, delta, kind, order_id, note) values (new.consumer_id, -earned, 'reverse', new.id, 'Order ' || new.order_number || ' cancelled/refunded');
      end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.orders_points_trg() from public, anon, authenticated;
drop trigger if exists trg_orders_points on public.orders;
create trigger trg_orders_points after update on public.orders for each row execute function public.orders_points_trg();

create or replace function public.my_points() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); last_earn timestamptz; f public.platform_flags := public._flags();
begin
  if uid is null then raise exception 'Please sign in'; end if;
  perform public._points_expire(uid);
  select max(created_at) into last_earn from public.cc_points_ledger where user_id = uid and kind = 'earn';
  return jsonb_build_object('balance', public._points_bal(uid), 'last_earned_at', last_earn,
    'expires_at', case when last_earn is null then null else last_earn + make_interval(days => f.points_expiry_days) end,
    'points_per_ec', f.points_per_ec, 'expiry_days', f.points_expiry_days, 'enabled', f.rewards_enabled,
    'history', coalesce((select jsonb_agg(h order by h.created_at desc) from (select l.id, l.delta, l.kind, l.note, l.created_at, o.order_number
        from public.cc_points_ledger l left join public.orders o on o.id = l.order_id where l.user_id = uid order by l.created_at desc, l.id desc limit 50) h), '[]'::jsonb));
end $$;
revoke all on function public.my_points() from public, anon;
grant execute on function public.my_points() to authenticated;

-- ---------- 3. Points Store gift cards ----------
create table if not exists public.vendor_giftcard_settings (
  vendor_id      uuid primary key references public.vendors(id) on delete cascade,
  participating  boolean not null default false,
  points_per_ec  int check (points_per_ec is null or points_per_ec between 1 and 1000),  -- UNUSED since v1.16b (admin prices each card)
  cap_cents_month int check (cap_cents_month is null or cap_cents_month >= 0),             -- admin override of the cap
  agreed_at      timestamptz,
  agreed_by      uuid,
  updated_at     timestamptz not null default now()
);
alter table public.vendor_giftcard_settings enable row level security;
drop policy if exists vgs_read on public.vendor_giftcard_settings;
create policy vgs_read on public.vendor_giftcard_settings for select to authenticated using (public.vendor_perm(vendor_id, 'orders_view') or public.is_admin());
revoke insert, update, delete on public.vendor_giftcard_settings from public, anon, authenticated;
grant select on public.vendor_giftcard_settings to authenticated;

create table if not exists public.gift_cards (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  vendor_id     uuid not null references public.vendors(id) on delete restrict,
  owner_id      uuid not null references auth.users(id) on delete cascade,
  source        text not null default 'points' check (source = 'points'),   -- the ONLY kind of Carriacou Connect gift card
  value_cents   int not null check (value_cents > 0),
  balance_cents int not null check (balance_cents >= 0),
  points_cost   int not null check (points_cost > 0),
  status        text not null default 'active' check (status in ('active','used','expired')),
  issued_at     timestamptz not null default now(),
  expires_at    timestamptz not null,
  last_used_at  timestamptz,
  constraint gift_cards_bal_ck check (balance_cents <= value_cents)
);
create index if not exists gift_cards_owner_idx on public.gift_cards(owner_id, issued_at desc);
create index if not exists gift_cards_vendor_idx on public.gift_cards(vendor_id, issued_at);
alter table public.gift_cards enable row level security;
drop policy if exists gift_cards_read on public.gift_cards;
create policy gift_cards_read on public.gift_cards for select to authenticated using (owner_id = auth.uid() or public.vendor_perm(vendor_id, 'orders_view') or public.is_admin());
revoke insert, update, delete on public.gift_cards from public, anon, authenticated;
grant select on public.gift_cards to authenticated;

alter table public.order_payments add column if not exists gift_card_id uuid;
alter table public.order_payments drop constraint if exists order_payments_method_check;
alter table public.order_payments add constraint order_payments_method_check check (method in ('cash','card','bank','other','wallet','gift_card'));
create or replace function public.order_payments_no_gc_void() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.voided and not old.voided and old.method = 'gift_card' then raise exception 'Gift card payments cannot be voided'; end if;
  return new;
end $$;
revoke all on function public.order_payments_no_gc_void() from public, anon, authenticated;
drop trigger if exists trg_order_payments_no_gc_void on public.order_payments;
create trigger trg_order_payments_no_gc_void before update on public.order_payments for each row execute function public.order_payments_no_gc_void();

-- v1.16b: Carriacou Connect gift cards are created and priced ONLY by the platform admin.
-- Vendors cannot create or price cards; they only opt in / out (vendor_set_giftcards).
-- (vendor_giftcard_settings.points_per_ec and flags giftcard_points_per_ec / giftcard_values_cents are no longer used.)
create table if not exists public.cc_gift_card_types (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) between 1 and 80),
  value_cents int not null check (value_cents > 0 and value_cents <= 100000),
  points_cost int not null check (points_cost > 0),
  active      boolean not null default true,
  all_vendors boolean not null default false,   -- true = every opted-in, eligible shop
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create table if not exists public.cc_gift_card_type_vendors (
  type_id   uuid not null references public.cc_gift_card_types(id) on delete cascade,
  vendor_id uuid not null references public.vendors(id) on delete cascade,
  primary key (type_id, vendor_id)
);
alter table public.cc_gift_card_types enable row level security;
alter table public.cc_gift_card_type_vendors enable row level security;
drop policy if exists gct_read on public.cc_gift_card_types;
create policy gct_read on public.cc_gift_card_types for select to authenticated using (public.is_admin());
drop policy if exists gctv_read on public.cc_gift_card_type_vendors;
create policy gctv_read on public.cc_gift_card_type_vendors for select to authenticated using (public.is_admin() or public.vendor_perm(vendor_id, 'orders_view'));
revoke insert, update, delete on public.cc_gift_card_types, public.cc_gift_card_type_vendors from public, anon, authenticated;
grant select on public.cc_gift_card_types, public.cc_gift_card_type_vendors to authenticated;
alter table public.gift_cards add column if not exists type_id uuid references public.cc_gift_card_types(id) on delete restrict;
alter table public.vendor_giftcard_settings add column if not exists opted_out_at timestamptz;

create or replace function public._gc_cards_for(p_vendor uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('type_id', t.id, 'name', t.name, 'value_cents', t.value_cents, 'points_cost', t.points_cost)
         order by t.value_cents, t.points_cost), '[]'::jsonb)
  from public.cc_gift_card_types t
  where t.active and (t.all_vendors or exists (select 1 from public.cc_gift_card_type_vendors x where x.type_id = t.id and x.vendor_id = p_vendor));
$$;
revoke all on function public._gc_cards_for(uuid) from public, anon, authenticated;

create or replace function public._gc_price(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags(); v record; s record; cap int; used int; cards jsonb;
begin
  select id, name, tier, status into v from public.vendors where id = p_vendor;
  select * into s from public.vendor_giftcard_settings where vendor_id = p_vendor;
  cap := coalesce(s.cap_cents_month, f.giftcard_cap_cents_month);
  select coalesce(sum(value_cents), 0) into used from public.gift_cards where vendor_id = p_vendor and issued_at >= date_trunc('month', now() at time zone 'America/Grenada') at time zone 'America/Grenada';
  cards := public._gc_cards_for(p_vendor);
  return jsonb_build_object('vendor_id', v.id, 'name', v.name, 'tier', v.tier,
    'qualifies', v.tier = any(f.giftcard_tiers), 'participating', coalesce(s.participating, false), 'opted_out_at', s.opted_out_at,
    'cards', cards, 'cap_cents_month', cap, 'issued_cents_month', used, 'remaining_cents', greatest(cap - used, 0),
    'open', f.gift_cards_enabled and v.status = 'approved' and v.tier = any(f.giftcard_tiers) and coalesce(s.participating, false));
end $$;
revoke all on function public._gc_price(uuid) from public, anon, authenticated;

create or replace function public.points_store() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags();
begin
  -- only opted-in shops on an eligible tier that have at least one active admin card
  return jsonb_build_object('enabled', f.gift_cards_enabled and f.rewards_enabled,
    'tiers', to_jsonb(f.giftcard_tiers), 'expiry_days', f.giftcard_expiry_days,
    'shops', coalesce((select jsonb_agg(x order by x->>'name') from (select public._gc_price(s.vendor_id) x from public.vendor_giftcard_settings s where s.participating) q
                       where (x->>'open')::boolean and jsonb_array_length(x->'cards') > 0), '[]'::jsonb));
end $$;
grant execute on function public.points_store() to anon, authenticated;

create or replace function public.vendor_set_giftcards(p_vendor uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare pr jsonb;
begin
  if not public.vendor_perm(p_vendor, 'refunds') then raise exception 'Only the owner or a sub-admin can change this'; end if;
  pr := public._gc_price(p_vendor);
  if p_on and not (pr->>'qualifies')::boolean then raise exception 'Carriacou Connect gift cards are a perk of higher plans (%). Upgrade to take part.', array_to_string((public._flags()).giftcard_tiers, ', '); end if;
  -- opting out stops NEW cards only; cards already issued stay usable (ASSUMPTION, see notes)
  insert into public.vendor_giftcard_settings(vendor_id, participating, agreed_at, agreed_by, opted_out_at)
    values (p_vendor, p_on, case when p_on then now() end, case when p_on then auth.uid() end, case when p_on then null else now() end)
  on conflict (vendor_id) do update set participating = excluded.participating,
    agreed_at = coalesce(excluded.agreed_at, public.vendor_giftcard_settings.agreed_at),
    agreed_by = coalesce(excluded.agreed_by, public.vendor_giftcard_settings.agreed_by),
    opted_out_at = excluded.opted_out_at, updated_at = now();
  return public._gc_price(p_vendor);
end $$;
revoke all on function public.vendor_set_giftcards(uuid, boolean) from public, anon;
grant execute on function public.vendor_set_giftcards(uuid, boolean) to authenticated;

-- admin: list cards + every shop with eligibility, for the "Gift cards" admin screen
create or replace function public.admin_gc_types() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags();
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'types', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'value_cents', t.value_cents, 'points_cost', t.points_cost,
        'active', t.active, 'all_vendors', t.all_vendors, 'updated_at', t.updated_at,
        'vendor_ids', coalesce((select jsonb_agg(x.vendor_id) from public.cc_gift_card_type_vendors x where x.type_id = t.id), '[]'::jsonb),
        'issued', (select count(*) from public.gift_cards g where g.type_id = t.id)) order by t.created_at) from public.cc_gift_card_types t), '[]'::jsonb),
    'vendors', coalesce((select jsonb_agg(jsonb_build_object('vendor_id', v.id, 'name', v.name, 'tier', v.tier, 'status', v.status,
        'qualifies', v.tier = any(f.giftcard_tiers), 'participating', coalesce(s.participating, false)) order by v.name)
      from public.vendors v left join public.vendor_giftcard_settings s on s.vendor_id = v.id where v.status = 'approved'), '[]'::jsonb),
    'tiers', to_jsonb(f.giftcard_tiers));
end $$;
revoke all on function public.admin_gc_types() from public, anon;
grant execute on function public.admin_gc_types() to authenticated;

create or replace function public.admin_gc_type_save(p_id uuid, p_name text, p_value_cents int, p_points_cost int, p_active boolean,
  p_all_vendors boolean, p_vendors uuid[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare tid uuid := p_id;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if coalesce(p_value_cents, 0) <= 0 then raise exception 'Enter a gift card value'; end if;
  if coalesce(p_points_cost, 0) <= 0 then raise exception 'Enter a points price'; end if;
  if tid is null then
    insert into public.cc_gift_card_types(name, value_cents, points_cost, active, all_vendors, created_by)
      values (btrim(coalesce(p_name, '')), p_value_cents, p_points_cost, coalesce(p_active, true), coalesce(p_all_vendors, false), auth.uid()) returning id into tid;
  else
    update public.cc_gift_card_types set name = btrim(coalesce(p_name, '')), value_cents = p_value_cents, points_cost = p_points_cost,
      active = coalesce(p_active, active), all_vendors = coalesce(p_all_vendors, all_vendors), updated_at = now() where id = tid;
    if not found then raise exception 'Gift card not found'; end if;
  end if;
  delete from public.cc_gift_card_type_vendors where type_id = tid;
  insert into public.cc_gift_card_type_vendors(type_id, vendor_id)
    select tid, v.id from public.vendors v where v.id = any(coalesce(p_vendors, '{}'::uuid[])) on conflict do nothing;
  return jsonb_build_object('id', tid);
end $$;
revoke all on function public.admin_gc_type_save(uuid, text, int, int, boolean, boolean, uuid[]) from public, anon;
grant execute on function public.admin_gc_type_save(uuid, text, int, int, boolean, boolean, uuid[]) to authenticated;

drop function if exists public.redeem_points_gift_card(uuid, int);
create or replace function public.redeem_points_gift_card(p_vendor uuid, p_type uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); f public.platform_flags := public._flags(); pr jsonb; t public.cc_gift_card_types; bal int; gid uuid; cd text;
begin
  if uid is null then raise exception 'Please sign in'; end if;
  if not (f.rewards_enabled and f.gift_cards_enabled) then raise exception 'The Points Store is closed'; end if;
  perform pg_advisory_xact_lock(hashtext('gc:' || p_vendor::text));
  perform public._points_expire(uid);
  pr := public._gc_price(p_vendor);
  -- server-side block: opted-out shop, ineligible tier, unapproved shop
  if pr->>'vendor_id' is null or not (pr->>'open')::boolean then raise exception 'This shop is not in the Points Store'; end if;
  select * into t from public.cc_gift_card_types where id = p_type;
  if not found or not t.active or not (t.all_vendors or exists (select 1 from public.cc_gift_card_type_vendors x where x.type_id = t.id and x.vendor_id = p_vendor))
    then raise exception 'This gift card is not available at this shop'; end if;
  if (pr->>'remaining_cents')::int < t.value_cents then raise exception 'This shop has reached its gift card limit for this month. Try a smaller card or next month.'; end if;
  bal := public._points_bal(uid);
  if bal < t.points_cost then raise exception 'You need % CC Points for this card (you have %)', t.points_cost, bal; end if;
  loop cd := public._pay_alphabet_code('GC'); exit when not exists (select 1 from public.gift_cards where code = cd); end loop;
  insert into public.gift_cards(code, vendor_id, owner_id, value_cents, balance_cents, points_cost, expires_at, type_id)
    values (cd, p_vendor, uid, t.value_cents, t.value_cents, t.points_cost, now() + make_interval(days => f.giftcard_expiry_days), t.id) returning id into gid;
  insert into public.cc_points_ledger(user_id, delta, kind, gift_card_id, note, created_by) values (uid, -t.points_cost, 'redeem', gid, 'Gift card ' || cd || ' for ' || (pr->>'name'), uid);
  return jsonb_build_object('gift_card_id', gid, 'code', cd, 'value_cents', t.value_cents, 'points_cost', t.points_cost, 'points_balance', bal - t.points_cost, 'vendor', pr->>'name');
end $$;
revoke all on function public.redeem_points_gift_card(uuid, uuid) from public, anon;
grant execute on function public.redeem_points_gift_card(uuid, uuid) to authenticated;

create or replace function public.my_gift_cards() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please sign in'; end if;
  update public.gift_cards set status = 'expired' where owner_id = uid and status = 'active' and expires_at < now();
  return coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'code', g.code, 'vendor_id', g.vendor_id, 'vendor', v.name, 'value_cents', g.value_cents,
     'balance_cents', g.balance_cents, 'points_cost', g.points_cost, 'status', g.status, 'issued_at', g.issued_at, 'expires_at', g.expires_at) order by g.issued_at desc)
    from public.gift_cards g join public.vendors v on v.id = g.vendor_id where g.owner_id = uid), '[]'::jsonb);
end $$;
revoke all on function public.my_gift_cards() from public, anon;
grant execute on function public.my_gift_cards() to authenticated;

-- ---------- 4. vendor Platform Funds + subscription credit ----------
create table if not exists public.vendor_funds_ledger (
  id           bigint generated always as identity primary key,
  vendor_id    uuid not null references public.vendors(id) on delete restrict,
  amount_cents bigint not null check (amount_cents <> 0),       -- + money in (top-up, fee refund), - spent
  kind         text not null check (kind in ('topup_card_test','topup_office','fees','fee_refund','subscription','featured','setup','adjustment','exit_payout')),
  note         text check (note is null or char_length(note) <= 200),
  ref          text check (ref is null or char_length(ref) <= 80),
  test_mode    boolean not null default true,
  created_by   uuid,
  idempotency_key text,
  created_at   timestamptz not null default now()
);
create index if not exists vfl_vendor_idx on public.vendor_funds_ledger(vendor_id, created_at desc);
create unique index if not exists vfl_idem on public.vendor_funds_ledger(vendor_id, idempotency_key) where idempotency_key is not null;
create table if not exists public.vendor_sub_credit_ledger (
  id           bigint generated always as identity primary key,
  vendor_id    uuid not null references public.vendors(id) on delete restrict,
  amount_cents bigint not null check (amount_cents <> 0),       -- + gift card redemptions credited, - applied to subscription / paid out
  kind         text not null check (kind in ('redemption','applied','exit_payout','adjustment')),
  gift_card_id uuid,
  order_id     uuid references public.orders(id) on delete set null,
  note         text check (note is null or char_length(note) <= 200),
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index if not exists vscl_vendor_idx on public.vendor_sub_credit_ledger(vendor_id, created_at desc);
create table if not exists public.order_fees (
  order_id     uuid primary key references public.orders(id) on delete cascade,
  vendor_id    uuid not null references public.vendors(id) on delete restrict,
  fee_class    text not null check (fee_class in ('card','direct')),
  rate_pct     numeric(5,2) not null,
  base_cents   bigint not null check (base_cents >= 0),
  fee_cents    bigint not null check (fee_cents >= 0),
  status       text not null default 'charged' check (status in ('charged','refunded')),
  refund_cents bigint not null default 0,
  charged_at   timestamptz not null default now(),
  refunded_at  timestamptz,
  billed_at    timestamptz,
  bill_id      uuid
);
create index if not exists order_fees_vendor_idx on public.order_fees(vendor_id, charged_at desc);
create table if not exists public.vendor_bills (
  id            uuid primary key default gen_random_uuid(),
  vendor_id     uuid not null references public.vendors(id) on delete restrict,
  kind          text not null check (kind in ('fees','subscription','featured','setup')),
  period_end    date not null,
  total_cents   bigint not null check (total_cents >= 0),
  from_sub_credit_cents bigint not null default 0,
  from_funds_cents bigint not null default 0,
  invoice_cents bigint not null default 0,                     -- shortfall: invoiced (fallback)
  status        text not null default 'settled' check (status in ('settled','invoiced','paid')),
  note          text,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  paid_at       timestamptz
);
create index if not exists vendor_bills_vendor_idx on public.vendor_bills(vendor_id, created_at desc);
create table if not exists public.vendor_exit_requests (
  id              uuid primary key default gen_random_uuid(),
  vendor_id       uuid not null references public.vendors(id) on delete restrict,
  requested_by    uuid not null,
  reason          text check (reason is null or char_length(reason) <= 300),
  funds_cents     bigint not null default 0,
  sub_credit_cents bigint not null default 0,
  status          text not null default 'pending' check (status in ('pending','confirmed','paid','rejected','withdrawn')),
  scheduled_for   date,
  decided_by      uuid, decided_at timestamptz, decision_note text,
  paid_at         timestamptz, pay_ref text,
  test_mode       boolean not null default true,
  created_at      timestamptz not null default now()
);
create unique index if not exists vendor_exit_one_open on public.vendor_exit_requests(vendor_id) where status in ('pending','confirmed');

do $$ declare t text; begin
  foreach t in array array['vendor_funds_ledger','vendor_sub_credit_ledger','order_fees','vendor_bills','vendor_exit_requests'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.vendor_perm(vendor_id, ''refunds'') or public.is_admin())', t || '_read', t);
    execute format('revoke insert, update, delete, truncate on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
drop trigger if exists trg_vfl_append on public.vendor_funds_ledger;
create trigger trg_vfl_append before update or delete on public.vendor_funds_ledger for each row execute function public._append_only();
drop trigger if exists trg_vscl_append on public.vendor_sub_credit_ledger;
create trigger trg_vscl_append before update or delete on public.vendor_sub_credit_ledger for each row execute function public._append_only();

create or replace function public._funds_bal(p_vendor uuid) returns bigint
language sql stable security definer set search_path = public, pg_temp as $$ select coalesce(sum(amount_cents), 0)::bigint from public.vendor_funds_ledger where vendor_id = p_vendor $$;
create or replace function public._subcred_bal(p_vendor uuid) returns bigint
language sql stable security definer set search_path = public, pg_temp as $$ select coalesce(sum(amount_cents), 0)::bigint from public.vendor_sub_credit_ledger where vendor_id = p_vendor $$;
revoke all on function public._funds_bal(uuid), public._subcred_bal(uuid) from public, anon, authenticated;

-- next pay cycle: the payout scheduler default (Thursday, Grenada time); a holiday calendar can replace this later
create or replace function public._next_cycle(p_from timestamptz default now()) returns date
language sql stable as $$
  select d + case when (4 - extract(isodow from d)::int + 7) % 7 = 0 then 7 else (4 - extract(isodow from d)::int + 7) % 7 end
  from (select (p_from at time zone 'America/Grenada')::date d) x $$;

-- per-order fee: charged when the order is placed; class follows how it is paid; refunded on cancel/refund
create or replace function public.orders_fee_trg() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags(); cls text; rate numeric; fee record; base bigint; amt bigint;
begin
  if not f.vendor_credit_enabled then return new; end if;
  cls := case when new.payment_method = 'pay_with_wallet' then 'card' else 'direct' end;  -- 'card' = paid online through a processor
  rate := case when cls = 'card' then f.fee_card_pct else f.fee_direct_pct end;
  base := round(new.total_xcd * 100);
  select * into fee from public.order_fees where order_id = new.id;
  if (tg_op = 'UPDATE' and ((new.status = 'cancelled' and old.status is distinct from 'cancelled') or (new.payment_status = 'refunded' and old.payment_status is distinct from 'refunded'))) then
    if found and fee.status = 'charged' then
      amt := round(fee.fee_cents * f.fee_refund_pct / 100);
      update public.order_fees set status = 'refunded', refund_cents = amt, refunded_at = now() where order_id = new.id;
      if fee.billed_at is not null and amt > 0 then   -- already billed: credit it back to Platform Funds
        insert into public.vendor_funds_ledger(vendor_id, amount_cents, kind, note, created_by)
          values (new.vendor_id, amt, 'fee_refund', 'Fee refund, order ' || new.order_number, auth.uid());
      end if;
    end if;
    return new;
  end if;
  if new.status = 'cancelled' then return new; end if;
  if not found then
    if tg_op = 'UPDATE' then return new; end if;   -- orders placed before this migration are not charged retroactively
    insert into public.order_fees(order_id, vendor_id, fee_class, rate_pct, base_cents, fee_cents)
      values (new.id, new.vendor_id, cls, rate, base, round(base * rate / 100));
  elsif fee.billed_at is null and fee.status = 'charged' and (fee.base_cents <> base or fee.fee_class <> cls) then
    update public.order_fees set fee_class = cls, rate_pct = rate, base_cents = base, fee_cents = round(base * rate / 100) where order_id = new.id;
  end if;
  return new;
end $$;
revoke all on function public.orders_fee_trg() from public, anon, authenticated;
drop trigger if exists trg_orders_fee_ins on public.orders;
create trigger trg_orders_fee_ins after insert on public.orders for each row execute function public.orders_fee_trg();
drop trigger if exists trg_orders_fee_upd on public.orders;
create trigger trg_orders_fee_upd after update of total_xcd, payment_method, payment_status, status on public.orders for each row execute function public.orders_fee_trg();

-- settle an amount: subscription credit first (subscription only), then Platform Funds, shortfall invoiced
create or replace function public._settle(p_vendor uuid, p_kind text, p_total bigint, p_note text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare sc bigint := 0; fu bigint := 0; inv bigint; bid uuid := gen_random_uuid();
begin
  perform pg_advisory_xact_lock(hashtext('funds:' || p_vendor::text));
  if p_kind = 'subscription' then sc := least(greatest(public._subcred_bal(p_vendor), 0), p_total); end if;
  fu := least(greatest(public._funds_bal(p_vendor), 0), p_total - sc);
  inv := p_total - sc - fu;
  insert into public.vendor_bills(id, vendor_id, kind, period_end, total_cents, from_sub_credit_cents, from_funds_cents, invoice_cents, status, note, created_by)
    values (bid, p_vendor, p_kind, (now() at time zone 'America/Grenada')::date, p_total, sc, fu, inv, case when inv > 0 then 'invoiced' else 'settled' end, p_note, auth.uid());
  if sc > 0 then insert into public.vendor_sub_credit_ledger(vendor_id, amount_cents, kind, note, created_by) values (p_vendor, -sc, 'applied', coalesce(p_note, p_kind), auth.uid()); end if;
  if fu > 0 then insert into public.vendor_funds_ledger(vendor_id, amount_cents, kind, note, ref, created_by) values (p_vendor, -fu, p_kind, coalesce(p_note, p_kind), bid::text, auth.uid()); end if;
  return bid;
end $$;
revoke all on function public._settle(uuid, text, bigint, text) from public, anon, authenticated;

-- end-of-cycle billing of per-order fees (admin / manager; later a scheduled job)
create or replace function public.admin_bill_fees() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; bid uuid; n int := 0; tot bigint := 0;
begin
  if not public.is_admin() then raise exception 'Only the platform admin can run billing'; end if;
  for r in select vendor_id, sum(fee_cents)::bigint s, count(*) c from public.order_fees where billed_at is null and status = 'charged' group by vendor_id loop
    bid := public._settle(r.vendor_id, 'fees', r.s, 'Platform fees, ' || r.c || ' order(s)');
    update public.order_fees set billed_at = now(), bill_id = bid where vendor_id = r.vendor_id and billed_at is null and status = 'charged';
    n := n + 1; tot := tot + r.s;
    begin perform public._rt_add(u, 'platform_bill', 'Platform fees billed: ' || public._rt_money(r.s / 100.0), 'See Platform Funds for the fee lines.', 'funds.html', 'vendor', r.vendor_id, r.vendor_id, false)
      from public._rt_team(r.vendor_id, 'refunds') u; exception when undefined_function then null; end;
  end loop;
  -- refunded before billing: nothing to bill
  update public.order_fees set billed_at = now() where billed_at is null and status = 'refunded';
  return jsonb_build_object('vendors', n, 'total_cents', tot);
end $$;

create or replace function public.admin_charge_service(p_vendor uuid, p_kind text, p_amount_cents bigint, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare bid uuid;
begin
  if not public.is_admin() then raise exception 'Only the platform admin can charge services'; end if;
  if p_kind not in ('subscription','featured','setup') then raise exception 'Platform Funds can only pay for subscription, featured listings/ads or setup'; end if;
  if coalesce(p_amount_cents, 0) <= 0 then raise exception 'Enter an amount'; end if;
  bid := public._settle(p_vendor, p_kind, p_amount_cents, nullif(btrim(coalesce(p_note, '')), ''));
  return (select to_jsonb(b) from public.vendor_bills b where id = bid);
end $$;

create or replace function public.vendor_funds_topup_test(p_vendor uuid, p_amount_cents bigint, p_key text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags();
begin
  if not public.vendor_perm(p_vendor, 'refunds') then raise exception 'Only the owner or a sub-admin can top up Platform Funds'; end if;
  if not f.vendor_credit_enabled then raise exception 'Platform Funds are switched off'; end if;
  if not f.credit_test_mode then raise exception 'Card top-ups need the live card processor'; end if;
  if coalesce(p_amount_cents, 0) <= 0 or p_amount_cents > f.topup_test_max_cents then raise exception 'Test top-ups are EC$0.01 to %', public._rt_money(f.topup_test_max_cents / 100.0); end if;
  if p_key is not null and exists (select 1 from public.vendor_funds_ledger where vendor_id = p_vendor and idempotency_key = p_key) then
    return jsonb_build_object('replay', true, 'balance_cents', public._funds_bal(p_vendor)); end if;
  perform pg_advisory_xact_lock(hashtext('funds:' || p_vendor::text));
  insert into public.vendor_funds_ledger(vendor_id, amount_cents, kind, note, created_by, idempotency_key)
    values (p_vendor, p_amount_cents, 'topup_card_test', 'Test card top-up (play money)', auth.uid(), left(p_key, 60));
  return jsonb_build_object('replay', false, 'balance_cents', public._funds_bal(p_vendor));
end $$;

create or replace function public.admin_funds_topup(p_vendor uuid, p_amount_cents bigint, p_method text, p_receipt text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Only the platform admin / office can record office top-ups'; end if;
  if p_method not in ('cash','card') then raise exception 'Office top-ups are cash or card'; end if;
  if coalesce(p_amount_cents, 0) <= 0 or p_amount_cents > 1000000 then raise exception 'Enter an amount up to EC$10,000'; end if;
  perform pg_advisory_xact_lock(hashtext('funds:' || p_vendor::text));
  insert into public.vendor_funds_ledger(vendor_id, amount_cents, kind, note, ref, created_by)
    values (p_vendor, p_amount_cents, 'topup_office', 'Office top-up (' || p_method || ', TEST)', left(nullif(btrim(coalesce(p_receipt, '')), ''), 80), auth.uid());
  return jsonb_build_object('balance_cents', public._funds_bal(p_vendor));
end $$;

create or replace function public.vendor_funds(p_vendor uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags();
begin
  if not (public.vendor_perm(p_vendor, 'refunds') or public.is_admin()) then raise exception 'Only the owner or a sub-admin can see Platform Funds'; end if;
  return jsonb_build_object(
    'vendor_id', p_vendor, 'balance_cents', public._funds_bal(p_vendor), 'sub_credit_cents', public._subcred_bal(p_vendor),
    'test_mode', f.credit_test_mode, 'fee_card_pct', f.fee_card_pct, 'fee_direct_pct', f.fee_direct_pct, 'fee_refund_pct', f.fee_refund_pct,
    'next_cycle', public._next_cycle(), 'topup_max_cents', f.topup_test_max_cents,
    'unbilled_cents', (select coalesce(sum(fee_cents), 0) from public.order_fees where vendor_id = p_vendor and billed_at is null and status = 'charged'),
    'fees', coalesce((select jsonb_agg(x order by x->>'charged_at' desc) from (select jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'fee_class', fe.fee_class,
        'rate_pct', fe.rate_pct, 'base_cents', fe.base_cents, 'fee_cents', fe.fee_cents, 'status', fe.status, 'refund_cents', fe.refund_cents,
        'charged_at', fe.charged_at, 'billed_at', fe.billed_at) x from public.order_fees fe join public.orders o on o.id = fe.order_id
        where fe.vendor_id = p_vendor order by fe.charged_at desc limit 50) q), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(to_jsonb(l) - 'idempotency_key' order by l.created_at desc, l.id desc) from (select * from public.vendor_funds_ledger where vendor_id = p_vendor order by created_at desc, id desc limit 50) l), '[]'::jsonb),
    'sub_credit', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc, l.id desc) from (select * from public.vendor_sub_credit_ledger where vendor_id = p_vendor order by created_at desc, id desc limit 30) l), '[]'::jsonb),
    'bills', coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at desc) from (select * from public.vendor_bills where vendor_id = p_vendor order by created_at desc limit 20) b), '[]'::jsonb),
    'giftcards', public._gc_price(p_vendor),
    'exit', (select to_jsonb(e) from public.vendor_exit_requests e where vendor_id = p_vendor order by created_at desc limit 1));
end $$;

-- ---------- gift card used on an order (pay-on-pickup/delivery balance) ----------
create or replace function public.apply_gift_card(p_order uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); o public.orders; g public.gift_cards; bal numeric; amt int; pid uuid; res jsonb; u uuid;
begin
  if uid is null then raise exception 'Please sign in'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found or o.consumer_id <> uid then raise exception 'Order not found'; end if;
  select * into g from public.gift_cards where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found or g.owner_id <> uid then raise exception 'Gift card not found'; end if;
  if g.vendor_id <> o.vendor_id then raise exception 'This gift card is for another shop'; end if;
  if g.status <> 'active' or g.expires_at < now() or g.balance_cents <= 0 then raise exception 'This gift card is used up or expired'; end if;
  bal := public._opr_balance(o);
  if bal <= 0 then raise exception 'This order is already paid in full'; end if;
  amt := least(g.balance_cents, round(bal * 100))::int;
  update public.gift_cards set balance_cents = balance_cents - amt, last_used_at = now(),
    status = case when balance_cents - amt = 0 then 'used' else 'active' end,
    expires_at = greatest(expires_at, now() + make_interval(days => (public._flags()).giftcard_expiry_days)) where id = g.id;
  insert into public.order_payments(order_id, vendor_id, amount_xcd, kind, method, note, recorded_by, gift_card_id)
    values (o.id, o.vendor_id, amt / 100.0, case when amt >= round(bal * 100) then 'full' else 'partial' end, 'gift_card', 'Gift card ' || g.code, uid, g.id) returning id into pid;
  res := public._offpay_refresh(o.id);
  -- the platform credits the shop against its subscription (rolls over to later billing cycles)
  insert into public.vendor_sub_credit_ledger(vendor_id, amount_cents, kind, gift_card_id, order_id, note, created_by)
    values (o.vendor_id, amt, 'redemption', g.id, o.id, 'Gift card ' || g.code || ' on ' || o.order_number, uid);
  begin
    for u in select * from public._rt_team(o.vendor_id, 'orders_view') loop
      perform public._rt_add(u, 'gift_card_used', o.order_number || ': gift card ' || public._rt_money(amt / 100.0),
        'Credited to your subscription by Carriacou Connect. Balance due ' || public._rt_money((res->>'balance_due_xcd')::numeric) || '.', 'dashboard-vendor.html#orders', 'order', o.id, o.vendor_id, false);
    end loop;
  exception when undefined_function then null; end;
  return res || jsonb_build_object('payment_id', pid, 'amount_cents', amt, 'card_balance_cents', g.balance_cents - amt);
end $$;
revoke all on function public.apply_gift_card(uuid, text) from public, anon;
grant execute on function public.apply_gift_card(uuid, text) to authenticated;

-- ---------- 5. vendor exit refund (manager queue) ----------
create or replace function public.vendor_request_exit(p_vendor uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); v record; rid uuid; a uuid;
begin
  select * into v from public.vendors where id = p_vendor;
  if not found or v.owner_id is distinct from uid then raise exception 'Only the shop owner can close the shop and ask for a refund'; end if;
  if exists (select 1 from public.vendor_exit_requests where vendor_id = p_vendor and status in ('pending','confirmed')) then raise exception 'You already have an open request'; end if;
  insert into public.vendor_exit_requests(vendor_id, requested_by, reason, funds_cents, sub_credit_cents, scheduled_for)
    values (p_vendor, uid, left(nullif(btrim(coalesce(p_reason, '')), ''), 300), greatest(public._funds_bal(p_vendor), 0), greatest(public._subcred_bal(p_vendor), 0), public._next_cycle())
    returning id into rid;
  begin
    for a in select id from public.profiles where role = 'admin' loop
      perform public._rt_add(a, 'exit_request', 'Shop exit refund to confirm: ' || v.name, 'Manager queue: confirm and pay in the next cycle.', 'admin.html#exits', 'vendor', p_vendor, p_vendor, false);
    end loop;
  exception when undefined_function then null; end;
  return (select to_jsonb(e) from public.vendor_exit_requests e where id = rid);
end $$;

create or replace function public.vendor_withdraw_exit(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record;
begin
  select * into r from public.vendor_exit_requests where id = p_request for update;
  if not found or not exists (select 1 from public.vendors where id = r.vendor_id and owner_id = auth.uid()) then raise exception 'Request not found'; end if;
  if r.status <> 'pending' then raise exception 'Only a pending request can be withdrawn'; end if;
  update public.vendor_exit_requests set status = 'withdrawn', decided_at = now() where id = r.id;
  return jsonb_build_object('id', r.id, 'status', 'withdrawn');
end $$;

create or replace function public.admin_exit_queue() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Only the platform manager can see the exit queue'; end if;
  return coalesce((select jsonb_agg(to_jsonb(e) || jsonb_build_object('vendor', v.name, 'funds_now_cents', public._funds_bal(e.vendor_id), 'sub_credit_now_cents', public._subcred_bal(e.vendor_id))
    order by case e.status when 'pending' then 0 when 'confirmed' then 1 else 2 end, e.created_at desc)
    from public.vendor_exit_requests e join public.vendors v on v.id = e.vendor_id where e.status in ('pending','confirmed') or e.created_at > now() - interval '60 days'), '[]'::jsonb);
end $$;

create or replace function public.admin_exit_decide(p_request uuid, p_action text, p_note text default null, p_ref text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; fb bigint; sb bigint; u uuid;
begin
  if not public.is_admin() then raise exception 'Only the platform manager can decide exit refunds'; end if;
  select * into r from public.vendor_exit_requests where id = p_request for update;
  if not found then raise exception 'Request not found'; end if;
  if p_action = 'confirm' then
    if r.status <> 'pending' then raise exception 'Only a pending request can be confirmed'; end if;
    update public.vendor_exit_requests set status = 'confirmed', decided_by = auth.uid(), decided_at = now(), decision_note = p_note, scheduled_for = public._next_cycle() where id = r.id;
  elsif p_action = 'reject' then
    if r.status not in ('pending','confirmed') then raise exception 'This request is already closed'; end if;
    if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Give a reason'; end if;
    update public.vendor_exit_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = r.id;
  elsif p_action = 'paid' then
    if r.status <> 'confirmed' then raise exception 'Confirm the request before marking it paid'; end if;
    perform pg_advisory_xact_lock(hashtext('funds:' || r.vendor_id::text));
    fb := greatest(public._funds_bal(r.vendor_id), 0); sb := greatest(public._subcred_bal(r.vendor_id), 0);
    if fb > 0 then insert into public.vendor_funds_ledger(vendor_id, amount_cents, kind, note, ref, created_by) values (r.vendor_id, -fb, 'exit_payout', 'Exit refund (TEST, no real money)', left(p_ref, 80), auth.uid()); end if;
    if sb > 0 then insert into public.vendor_sub_credit_ledger(vendor_id, amount_cents, kind, note, created_by) values (r.vendor_id, -sb, 'exit_payout', 'Exit refund of rolled-over credit (TEST)', auth.uid()); end if;
    update public.vendor_exit_requests set status = 'paid', paid_at = now(), pay_ref = left(p_ref, 80), funds_cents = fb, sub_credit_cents = sb where id = r.id;
  else raise exception 'Unknown action'; end if;
  begin
    for u in select * from public._rt_team(r.vendor_id, 'refunds') loop
      perform public._rt_add(u, 'exit_update', 'Shop exit refund: ' || p_action, coalesce(p_note, 'See Platform Funds.'), 'funds.html', 'vendor', r.vendor_id, r.vendor_id, false);
    end loop;
  exception when undefined_function then null; end;
  return (select to_jsonb(e) from public.vendor_exit_requests e where id = r.id);
end $$;

-- a small admin overview of every shop's funds
create or replace function public.admin_funds_overview() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('vendor_id', v.id, 'name', v.name, 'tier', v.tier, 'balance_cents', public._funds_bal(v.id), 'sub_credit_cents', public._subcred_bal(v.id),
    'unbilled_cents', (select coalesce(sum(fee_cents), 0) from public.order_fees where vendor_id = v.id and billed_at is null and status = 'charged'),
    'open_invoice_cents', (select coalesce(sum(invoice_cents), 0) from public.vendor_bills where vendor_id = v.id and status = 'invoiced')) order by v.name)
    from public.vendors v where v.status = 'approved'), '[]'::jsonb);
end $$;

revoke all on function public.admin_bill_fees(), public.admin_charge_service(uuid,text,bigint,text), public.vendor_funds_topup_test(uuid,bigint,text),
  public.admin_funds_topup(uuid,bigint,text,text), public.vendor_funds(uuid), public.vendor_request_exit(uuid,text), public.vendor_withdraw_exit(uuid),
  public.admin_exit_queue(), public.admin_exit_decide(uuid,text,text,text), public.admin_funds_overview() from public, anon;
grant execute on function public.admin_bill_fees(), public.admin_charge_service(uuid,text,bigint,text), public.vendor_funds_topup_test(uuid,bigint,text),
  public.admin_funds_topup(uuid,bigint,text,text), public.vendor_funds(uuid), public.vendor_request_exit(uuid,text), public.vendor_withdraw_exit(uuid),
  public.admin_exit_queue(), public.admin_exit_decide(uuid,text,text,text), public.admin_funds_overview() to authenticated;

-- ---------- backfill: fees for open orders placed before this migration are NOT charged retroactively ----------
-- (only orders inserted after this file runs get an order_fees row; updates to older orders are skipped)

notify pgrst, 'reload schema';
