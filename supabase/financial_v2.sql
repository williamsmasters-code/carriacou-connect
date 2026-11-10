-- =====================================================================================================
-- financial_v2.sql (v1.20) - Daniel's financial structure (10 Nov 2026) + the products grant fix.
-- RUN ORDER: LAST, after reviews.sql / photo_labels.sql (i.e. after every earlier file). Idempotent: safe to run twice.
-- Supabase uses pg-safeupdate: every UPDATE has a WHERE. No DELETE. Nothing is dropped: old rows and old functions stay.
--
-- THE RULES (enforced here, on the server, not only in the page):
--  1. CC Points are earned ONLY on orders placed on the platform that are
--       (a) pickup orders paid on pickup, once the vendor marks the order completed, or
--       (b) orders paid online by card (payment_status = 'paid'), once the vendor marks the order completed.
--     Nothing else earns points: no POS / in-person sales that were not ordered on the platform, no wallet
--     transfers, no sign-ups, reviews or referrals, no delivery orders (delivery is paused), no wallet-paid
--     test orders, and no orders a shop's own owner or team member places with their own shop.
--     Cancelled or refunded orders earn nothing (and earned points are taken back, as before).
--  2. CC Cash (the old "Platform Funds" ledger, renamed) belongs ONLY to vendors. It is credited only by
--     top-ups, fee refunds or admin adjustments and spent only on Carriacou Connect's own services and goods
--     (plan subscription, platform fees, featured listings/ads, setup/photo service, custom shop layout,
--     Carriacou Connect goods). It cannot be sent to anyone. Customers never hold CC Cash.
--  3. Customers pay vendors ONLY (a) on pickup (cash, card or another in-person method at the counter) or
--     (b) online by credit/debit card (switched off until a card processor is connected: card_payments_enabled).
--     The customer money wallet is RETIRED: no top-ups, wallet-to-wallet transfers, wallet order payments,
--     POS charge codes or payment requests. Points can no longer pay for a vendor's goods: the Points Store
--     shop gift cards are closed and unused ones are turned back into points.
--  4. Delivery is PAUSED behind platform_flags.delivery_enabled (default false). New orders are pickup only.
--     Vendors' saved delivery settings are kept untouched (frozen) so delivery can be switched back on later.
--  Plus: grant select (image_label) on products (the live click-through fix, Step 61) and sgc_status() so the
--  locked gift card tab does not need a call that fails with 400.
-- =====================================================================================================

-- ---------- 0. products grant fix (Step 61) ----------
grant select (image_label) on public.products to anon, authenticated;

-- ---------- 1. flags ----------
alter table public.platform_flags add column if not exists delivery_enabled boolean not null default false;
alter table public.platform_flags add column if not exists card_payments_enabled boolean not null default false;   -- on when a card processor is live
alter table public.platform_flags add column if not exists financial_version text not null default 'v2';
update public.platform_flags set wallet_mode = 'off', gift_cards_enabled = false, updated_at = now() where id = 1 and (wallet_mode <> 'off' or gift_cards_enabled);
alter table public.platform_flags drop constraint if exists platform_flags_fin2_ck;
alter table public.platform_flags add constraint platform_flags_fin2_ck check (wallet_mode = 'off' and not gift_cards_enabled);

create or replace function public.admin_set_flags(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare k text; allowed text[] := array['rewards_enabled','vendor_credit_enabled','fee_card_pct','fee_direct_pct','fee_refund_pct','points_per_ec','points_expiry_days',
  'giftcard_tiers','giftcard_cap_cents_month','giftcard_expiry_days','delivery_enabled','card_payments_enabled','wallet_mode','gift_cards_enabled'];
begin
  if not public.is_admin() then raise exception 'Only the platform admin can change settings'; end if;
  for k in select jsonb_object_keys(p) loop if not k = any(allowed) then raise exception 'Unknown setting %', k; end if; end loop;
  if coalesce(p->>'wallet_mode', 'off') <> 'off' then raise exception 'The customer wallet is retired (v1.20): customers pay on pickup or by card'; end if;
  if coalesce((p->>'gift_cards_enabled')::boolean, false) then raise exception 'Points cannot pay for vendor goods (v1.20): the Points Store shop gift cards are closed'; end if;
  update public.platform_flags set
    rewards_enabled = coalesce((p->>'rewards_enabled')::boolean, rewards_enabled),
    vendor_credit_enabled = coalesce((p->>'vendor_credit_enabled')::boolean, vendor_credit_enabled),
    fee_card_pct = coalesce((p->>'fee_card_pct')::numeric, fee_card_pct),
    fee_direct_pct = coalesce((p->>'fee_direct_pct')::numeric, fee_direct_pct),
    fee_refund_pct = coalesce((p->>'fee_refund_pct')::numeric, fee_refund_pct),
    points_per_ec = coalesce((p->>'points_per_ec')::int, points_per_ec),
    points_expiry_days = coalesce((p->>'points_expiry_days')::int, points_expiry_days),
    giftcard_tiers = coalesce(case when p ? 'giftcard_tiers' then array(select jsonb_array_elements_text(p->'giftcard_tiers')) end, giftcard_tiers),
    giftcard_cap_cents_month = coalesce((p->>'giftcard_cap_cents_month')::int, giftcard_cap_cents_month),
    giftcard_expiry_days = coalesce((p->>'giftcard_expiry_days')::int, giftcard_expiry_days),
    delivery_enabled = coalesce((p->>'delivery_enabled')::boolean, delivery_enabled),
    card_payments_enabled = coalesce((p->>'card_payments_enabled')::boolean, card_payments_enabled),
    updated_at = now(), updated_by = auth.uid()
  where id = 1;
  return public.platform_flags_get();
end $$;
revoke all on function public.admin_set_flags(jsonb) from public, anon;
grant execute on function public.admin_set_flags(jsonb) to authenticated;

-- ---------- 2. customer money wallet retired (no flag can bring it back) ----------
create or replace function public.transactions_wallet_parked() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.type in ('topup_test','transfer','order_payment') then
    raise exception 'WALLET_RETIRED: Carriacou Connect has no customer wallet. Pay the shop on pickup or online by card.';
  end if;
  return new;   -- refunds/adjustments of OLD test payments still allowed
end $$;
revoke all on function public.transactions_wallet_parked() from public, anon, authenticated;

create or replace function public.parked_wallet_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  raise exception 'WALLET_RETIRED: % are retired. Customers pay on pickup or online by card.', case tg_table_name when 'pay_requests' then 'POS wallet charge codes' else 'Wallet payment requests' end;
end $$;
revoke all on function public.parked_wallet_guard() from public, anon, authenticated;

-- belt and braces: customers can no longer call the wallet functions at all
do $$ declare s text; begin
  foreach s in array array['public.test_topup(bigint)','public.transfer_wallet(text,bigint,text,text)','public.pay_order(uuid,text)','public.pay_orders(uuid[],text)',
    'public.pay_charge(text,text)','public.create_charge(uuid,bigint,text,text)','public.customer_pay_balance(uuid,numeric,text)','public.vendor_request_payment(uuid,numeric,text)',
    'public.redeem_points_gift_card(uuid,uuid)','public.apply_gift_card(uuid,text)'] loop
    begin execute 'revoke execute on function ' || s || ' from public, anon, authenticated';
    exception when undefined_function then null; end;
  end loop;
  -- signatures differ between files: revoke every overload by name
  for s in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('test_topup','transfer_wallet','pay_order','pay_orders','pay_charge','create_charge','customer_pay_balance',
      'vendor_request_payment','redeem_points_gift_card','apply_gift_card') loop
    execute 'revoke execute on function ' || s || ' from public, anon, authenticated';
  end loop;
end $$;

-- ---------- 3. orders: pickup now, card online later; no wallet; delivery paused ----------
alter table public.orders drop constraint if exists orders_payment_check;
alter table public.orders add constraint orders_payment_check check (payment_method in ('pay_on_pickup','pay_on_delivery','pay_with_wallet','pay_card_online'));
alter table public.orders drop constraint if exists orders_payment_matches;
alter table public.orders add constraint orders_payment_matches check (
  payment_method in ('pay_with_wallet','pay_card_online')
  or (fulfilment = 'pickup' and payment_method = 'pay_on_pickup') or (fulfilment = 'delivery' and payment_method = 'pay_on_delivery'));
alter table public.orders drop constraint if exists orders_payment_consistent;
alter table public.orders add constraint orders_payment_consistent check (
  (payment_status = 'unpaid' and paid_at is null) or (payment_status in ('paid','refunded') and paid_at is not null and payment_method in ('pay_with_wallet','pay_card_online')));

create or replace function public.orders_fin2_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags(); pay text := coalesce(current_setting('cc.order_payment', true), '');
begin
  if tg_op = 'INSERT' then
    if new.fulfilment = 'delivery' and not f.delivery_enabled then
      raise exception 'DELIVERY_PAUSED: Delivery is not available yet (coming soon). Choose pickup.'; end if;
    if new.payment_method = 'pay_with_wallet' then raise exception 'WALLET_RETIRED: Pay on pickup or online by card.'; end if;
    if pay = 'card' then new.payment_method := 'pay_card_online'; end if;
    if new.payment_method = 'pay_card_online' and not f.card_payments_enabled then
      raise exception 'CARD_COMING_SOON: Paying online by card is coming soon. Choose pay on pickup for now.'; end if;
  else
    if new.payment_method is distinct from old.payment_method and new.payment_method = 'pay_with_wallet' then
      raise exception 'WALLET_RETIRED: Pay on pickup or online by card.'; end if;
  end if;
  return new;
end $$;
revoke all on function public.orders_fin2_guard() from public, anon, authenticated;
drop trigger if exists trg_orders_a_fin2 on public.orders;
create trigger trg_orders_a_fin2 before insert or update on public.orders for each row execute function public.orders_fin2_guard();

-- the one money calculation, now delivery-aware: while delivery is paused pickup is always allowed
create or replace function public._order_money(p_vendor uuid, p_sub numeric, p_disc numeric, p_ful text, p_area text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.vendor_checkout_settings; found_s boolean; vname text; net numeric; fee numeric := 0; area text; z jsonb; zones jsonb;
  reg boolean := false; rate numeric := 0; incl boolean := true; vat text; base numeric; tax numeric := 0; total numeric; del_on boolean := (public._flags()).delivery_enabled;
begin
  select * into s from public.vendor_checkout_settings where vendor_id = p_vendor; found_s := found;
  select name into vname from public.vendors where id = p_vendor;
  net := greatest(coalesce(p_sub, 0) - coalesce(p_disc, 0), 0);
  if p_ful = 'pickup' then
    if del_on and found_s and not s.pickup_enabled then raise exception '% does not offer pickup. Choose delivery.', vname; end if;
  elsif p_ful = 'delivery' then
    if not del_on then raise exception 'Delivery is not available yet (coming soon). Choose pickup.'; end if;
    if found_s and not s.delivery_enabled then raise exception '% does not offer delivery. Choose pickup.', vname; end if;
    zones := case when found_s then s.delivery_zones else '[]'::jsonb end;
    if found_s and s.delivery_model = 'zones' and jsonb_array_length(zones) > 0 then
      select e into z from jsonb_array_elements(zones) e where lower(e->>'name') = lower(btrim(coalesce(p_area, ''))) limit 1;
      if z is null then raise exception 'Choose a delivery area for %.', vname; end if;
      fee := (z->>'fee')::numeric; area := z->>'name';
    else
      fee := case when found_s then s.delivery_flat_fee else 0 end;
    end if;
    if found_s and s.free_over_xcd is not null and net >= s.free_over_xcd then fee := 0; end if;
  else
    raise exception 'Choose pickup';
  end if;
  fee := round(fee, 2);
  if found_s and s.vat_registered then
    reg := true; rate := coalesce(s.vat_rate_pct, public._vat_default()); incl := s.prices_include_tax; vat := s.vat_number;
  end if;
  base := net + fee;
  if rate > 0 then tax := case when incl then round(base * rate / (100 + rate), 2) else round(base * rate / 100, 2) end; end if;
  total := base + case when incl then 0 else tax end;
  return jsonb_build_object('delivery_fee_xcd', fee, 'delivery_area', area, 'tax_rate_pct', rate, 'tax_inclusive', incl, 'tax_xcd', tax,
                            'total_xcd', total, 'net_xcd', net, 'vat_number', vat, 'vat_registered', reg);
end $$;
revoke all on function public._order_money(uuid, numeric, numeric, text, text) from public, anon, authenticated;

-- what the checkout page may know: delivery off and pickup on while delivery is paused
create or replace function public.vendor_checkout_options(p_vendor_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags();
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_vendor_ids is null or cardinality(p_vendor_ids) > 20 then raise exception 'Too many businesses'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'vendor_id', v.id, 'vendor_name', v.name,
      'pickup_enabled', case when f.delivery_enabled then coalesce(s.pickup_enabled, true) else true end,
      'delivery_enabled', f.delivery_enabled and coalesce(s.delivery_enabled, true),
      'delivery_paused', not f.delivery_enabled, 'card_enabled', f.card_payments_enabled,
      'delivery_model', coalesce(s.delivery_model, 'flat'), 'delivery_flat_fee', coalesce(s.delivery_flat_fee, 0), 'free_over_xcd', s.free_over_xcd,
      'delivery_zones', case when f.delivery_enabled then coalesce(s.delivery_zones, '[]'::jsonb) else '[]'::jsonb end,
      'vat_registered', coalesce(s.vat_registered, false),
      'tax_rate_pct', case when coalesce(s.vat_registered, false) then coalesce(s.vat_rate_pct, public._vat_default()) else 0 end,
      'prices_include_tax', case when coalesce(s.vat_registered, false) then s.prices_include_tax else true end,
      'vat_number', case when coalesce(s.vat_registered, false) then s.vat_number end) order by v.name)
    from public.vendors v left join public.vendor_checkout_settings s on s.vendor_id = v.id where v.id = any(p_vendor_ids)), '[]'::jsonb);
end $$;
revoke all on function public.vendor_checkout_options(uuid[]) from public, anon;
grant execute on function public.vendor_checkout_options(uuid[]) to authenticated;

-- vendor settings: report the pause; while paused, saved delivery settings are frozen and pickup is always on
create or replace function public.vendor_get_checkout_settings(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.vendor_checkout_settings; has boolean; f public.platform_flags := public._flags();
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if p_vendor is null or not public._co_editor(p_vendor) then raise exception 'Only the owner or a sub-admin can see these settings'; end if;
  select * into s from public.vendor_checkout_settings where vendor_id = p_vendor; has := found;
  return jsonb_build_object('saved', has,
    'pickup_enabled', case when f.delivery_enabled then coalesce(s.pickup_enabled, true) else true end, 'delivery_enabled', coalesce(s.delivery_enabled, true),
    'delivery_paused', not f.delivery_enabled, 'card_enabled', f.card_payments_enabled,
    'delivery_model', coalesce(s.delivery_model, 'flat'), 'delivery_flat_fee', coalesce(s.delivery_flat_fee, 0), 'free_over_xcd', s.free_over_xcd,
    'delivery_zones', coalesce(s.delivery_zones, '[]'::jsonb), 'vat_registered', coalesce(s.vat_registered, false), 'vat_rate_pct', s.vat_rate_pct,
    'prices_include_tax', coalesce(s.prices_include_tax, true), 'vat_number', s.vat_number,
    'platform_default_vat_pct', public._vat_default(), 'updated_at', s.updated_at);
end $$;
revoke all on function public.vendor_get_checkout_settings(uuid) from public, anon;
grant execute on function public.vendor_get_checkout_settings(uuid) to authenticated;

create or replace function public.checkout_settings_fin2() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select delivery_enabled from public.platform_flags where id = 1) then return new; end if;
  new.pickup_enabled := true;                       -- pickup is the only way to receive orders while delivery is paused
  if tg_op = 'UPDATE' then                          -- keep the saved delivery setup exactly as it was (feature flag, not deleted)
    new.delivery_enabled := old.delivery_enabled; new.delivery_model := old.delivery_model; new.delivery_flat_fee := old.delivery_flat_fee;
    new.free_over_xcd := old.free_over_xcd; new.delivery_zones := old.delivery_zones;
  end if;
  return new;
end $$;
revoke all on function public.checkout_settings_fin2() from public, anon, authenticated;
drop trigger if exists trg_checkout_settings_fin2 on public.vendor_checkout_settings;
create trigger trg_checkout_settings_fin2 before insert or update on public.vendor_checkout_settings for each row execute function public.checkout_settings_fin2();

-- the checkout entry point for v1.20: per-vendor plan + how the customer pays ('pickup' | 'card')
drop function if exists public.place_order_v2(jsonb, jsonb, text, text, text, text, text);
create or replace function public.place_order_v2(p_cart jsonb, p_plan jsonb, p_contact_phone text, p_notes text default null,
  p_contact_name text default null, p_campaign_code text default null, p_payment text default 'pickup',
  p_delivery_address text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare res jsonb; f public.platform_flags := public._flags();
begin
  if auth.uid() is null then raise exception 'Please log in to place an order'; end if;
  if coalesce(p_payment, '') not in ('pickup','card') then raise exception 'Choose pay on pickup or pay online by card'; end if;
  if p_payment = 'card' and not f.card_payments_enabled then raise exception 'CARD_COMING_SOON: Paying online by card is coming soon. Choose pay on pickup for now.'; end if;
  if not f.delivery_enabled and exists (select 1 from jsonb_each(coalesce(p_plan, '{}'::jsonb)) e
      where coalesce(e.value->>'fulfilment', 'pickup') = 'delivery') then
    raise exception 'DELIVERY_PAUSED: Delivery is not available yet (coming soon). Please choose pickup.';
  end if;
  perform set_config('cc.order_payment', p_payment, true);
  begin
    res := public.place_order_plan(p_cart, p_plan, p_contact_phone, p_delivery_address, p_notes, p_contact_name, p_campaign_code);
  exception when others then perform set_config('cc.order_payment', '', true); raise; end;
  perform set_config('cc.order_payment', '', true);
  return res;
end $$;
revoke all on function public.place_order_v2(jsonb, jsonb, text, text, text, text, text, text) from public, anon;
grant execute on function public.place_order_v2(jsonb, jsonb, text, text, text, text, text, text) to authenticated;

-- ---------- 4. recorded payments: pay on pickup (cash / card / other at the counter) or card online ----------
alter table public.order_payments drop constraint if exists order_payments_method_check;
alter table public.order_payments add constraint order_payments_method_check check (method in ('cash','card','bank','other','wallet','gift_card','card_online'));
create or replace function public.order_payments_fin2() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.method not in ('cash','card','other','card_online') then
    raise exception 'PAYMENT_METHOD: Customers pay on pickup (cash, card or another in-person method) or online by card. % is not accepted.',
      case new.method when 'bank' then 'Bank transfer' when 'wallet' then 'The wallet' when 'gift_card' then 'A CC Points gift card' else new.method end;
  end if;
  if new.method = 'card_online' and coalesce(current_setting('cc.card_processor', true), '') <> '1' then
    raise exception 'PAYMENT_METHOD: Online card payments are recorded only by the card processor';
  end if;
  return new;
end $$;
revoke all on function public.order_payments_fin2() from public, anon, authenticated;
drop trigger if exists trg_order_payments_fin2 on public.order_payments;
create trigger trg_order_payments_fin2 before insert on public.order_payments for each row execute function public.order_payments_fin2();

-- ---------- 5. CC Points: earned only on platform orders paid by card or picked up, once completed ----------
alter table public.cc_points_ledger drop constraint if exists cc_points_ledger_kind_check;
alter table public.cc_points_ledger add constraint cc_points_ledger_kind_check check (kind in ('earn','reverse','redeem','expire','adjust','refund'));

create or replace function public._points_eligible(o public.orders) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select o.status = 'completed' and o.payment_status <> 'refunded'
     and ((o.fulfilment = 'pickup' and o.payment_method = 'pay_on_pickup')
       or (o.payment_method = 'pay_card_online' and o.payment_status = 'paid'))
     -- a shop's own owner or active team member buying from that shop earns nothing
     and not exists (select 1 from public.vendors v where v.id = o.vendor_id and v.owner_id = o.consumer_id)
     and not exists (select 1 from public.vendor_members m where m.vendor_id = o.vendor_id and m.user_id = o.consumer_id and m.status = 'active');
$$;
revoke all on function public._points_eligible(public.orders) from public, anon, authenticated;

-- partial refunds (payments_mock.sql) can take points back in more than one step
drop index if exists public.cc_points_one_reverse;
create or replace function public.orders_points_trg() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags(); pts int; earned int;
begin
  if not f.rewards_enabled then return new; end if;
  -- earn: the moment an eligible order is completed (or a completed card order becomes paid)
  if public._points_eligible(new) and ((old.status is distinct from 'completed') or (old.payment_status is distinct from new.payment_status)) then
    -- part-refunded card orders (payments_mock.sql) earn on what the customer actually paid
    pts := floor((new.total_xcd - coalesce((to_jsonb(new)->>'card_refunded_xcd')::numeric, 0)) * f.points_per_ec)::int;
    if pts > 0 and not exists (select 1 from public.cc_points_ledger where order_id = new.id and kind = 'earn') then
      perform public._points_expire(new.consumer_id);
      insert into public.cc_points_ledger(user_id, delta, kind, order_id, note) values (new.consumer_id, pts, 'earn', new.id, 'Order ' || new.order_number);
      begin perform public._rt_add(new.consumer_id, 'points', 'You earned ' || pts || ' CC Points', 'Order ' || new.order_number || ' is complete. Points are rewards, not money.',
        'rewards.html', 'order', new.id, new.vendor_id, false); exception when undefined_function then null; end;
    end if;
  end if;
  -- take back: cancelled or refunded after an earn
  if (new.status = 'cancelled' and old.status is distinct from 'cancelled') or (new.payment_status = 'refunded' and old.payment_status is distinct from 'refunded') then
    select delta into earned from public.cc_points_ledger where order_id = new.id and kind = 'earn';
    -- take back what is left after any partial-refund reversals
    earned := earned + coalesce((select sum(delta) from public.cc_points_ledger where order_id = new.id and kind = 'reverse'), 0);
    if earned is not null and earned > 0 then
      earned := least(earned, greatest(public._points_bal(new.consumer_id), 0));
      if earned > 0 then
        insert into public.cc_points_ledger(user_id, delta, kind, order_id, note) values (new.consumer_id, -earned, 'reverse', new.id, 'Order ' || new.order_number || ' cancelled/refunded');
      end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.orders_points_trg() from public, anon, authenticated;
-- the trigger trg_orders_points (wallet_repurpose.sql) already calls this function

-- the only writer of points from now on is the order trigger above (+ expiry/refund). No RPC can add points.
create or replace function public.cc_points_fin2() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.kind = 'earn' then
    if new.order_id is null or not exists (select 1 from public.orders o where o.id = new.order_id and public._points_eligible(o)) then
      raise exception 'POINTS_RULE: CC Points are earned only on completed platform orders paid on pickup or online by card'; end if;
  elsif new.kind = 'adjust' and new.delta > 0 then
    raise exception 'POINTS_RULE: points cannot be added by hand';
  elsif new.kind = 'redeem' then
    raise exception 'POINTS_RULE: points cannot pay for vendor goods';
  end if;
  return new;
end $$;
revoke all on function public.cc_points_fin2() from public, anon, authenticated;
drop trigger if exists trg_cc_points_fin2 on public.cc_points_ledger;
create trigger trg_cc_points_fin2 before insert on public.cc_points_ledger for each row execute function public.cc_points_fin2();

-- points no longer pay for vendor goods: close the Points Store shop gift cards; unused card value goes back as points
alter table public.gift_cards drop constraint if exists gift_cards_status_check;
alter table public.gift_cards add constraint gift_cards_status_check check (status in ('active','used','expired','refunded'));
do $$ declare g record; pts int; begin
  for g in select * from public.gift_cards where status = 'active' and balance_cents > 0 and expires_at >= now() for update loop
    pts := ceil(g.points_cost::numeric * g.balance_cents / g.value_cents)::int;
    if pts > 0 then
      insert into public.cc_points_ledger(user_id, delta, kind, gift_card_id, note)
        values (g.owner_id, pts, 'refund', g.id, 'Gift card ' || g.code || ' closed (v1.20): unused value returned as points');
    end if;
    update public.gift_cards set status = 'refunded', balance_cents = 0 where id = g.id;
  end loop;
end $$;

create or replace function public.points_store() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  return jsonb_build_object('enabled', false, 'shops', '[]'::jsonb, 'tiers', '[]'::jsonb, 'expiry_days', (public._flags()).giftcard_expiry_days,
    'cc_shop', jsonb_build_object('open', false, 'note', 'Spend points on Carriacou Connect''s own goods and services. Coming soon.'));
end $$;
grant execute on function public.points_store() to anon, authenticated;

create or replace function public.my_points() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); last_earn timestamptz; f public.platform_flags := public._flags();
begin
  if uid is null then raise exception 'Please sign in'; end if;
  perform public._points_expire(uid);
  select max(created_at) into last_earn from public.cc_points_ledger where user_id = uid and kind = 'earn';
  return jsonb_build_object('balance', public._points_bal(uid), 'last_earned_at', last_earn,
    'expires_at', case when last_earn is null then null else last_earn + make_interval(days => f.points_expiry_days) end,
    'points_per_ec', f.points_per_ec, 'expiry_days', f.points_expiry_days, 'enabled', f.rewards_enabled, 'earn_rule', 'pickup_or_card_completed',
    'history', coalesce((select jsonb_agg(h order by h.created_at desc) from (select l.id, l.delta, l.kind, l.note, l.created_at, o.order_number
        from public.cc_points_ledger l left join public.orders o on o.id = l.order_id where l.user_id = uid order by l.created_at desc, l.id desc limit 50) h), '[]'::jsonb));
end $$;
revoke all on function public.my_points() from public, anon;
grant execute on function public.my_points() to authenticated;

-- ---------- 6. CC Cash: vendor-only, spent only on Carriacou Connect services and goods ----------
alter table public.vendor_funds_ledger drop constraint if exists vendor_funds_ledger_kind_check;
alter table public.vendor_funds_ledger add constraint vendor_funds_ledger_kind_check check (kind in
  ('topup_card_test','topup_office','fees','fee_refund','subscription','featured','setup','layout','cc_goods','adjustment','exit_payout'));
alter table public.vendor_bills drop constraint if exists vendor_bills_kind_check;
alter table public.vendor_bills add constraint vendor_bills_kind_check check (kind in ('fees','subscription','featured','setup','layout','cc_goods'));

create or replace function public.vendor_funds_fin2() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from public.vendors where id = new.vendor_id) then raise exception 'CC_CASH: CC Cash belongs to a business only'; end if;
  if new.amount_cents > 0 and new.kind not in ('topup_card_test','topup_office','fee_refund','adjustment') then
    raise exception 'CC_CASH: CC Cash is added only by a top-up, a fee refund or a Carriacou Connect adjustment'; end if;
  if new.amount_cents < 0 and new.kind not in ('fees','subscription','featured','setup','layout','cc_goods','exit_payout','adjustment') then
    raise exception 'CC_CASH: CC Cash can only be spent on Carriacou Connect services and goods'; end if;
  return new;
end $$;
revoke all on function public.vendor_funds_fin2() from public, anon, authenticated;
drop trigger if exists trg_vendor_funds_fin2 on public.vendor_funds_ledger;
create trigger trg_vendor_funds_fin2 before insert on public.vendor_funds_ledger for each row execute function public.vendor_funds_fin2();

create or replace function public.admin_charge_service(p_vendor uuid, p_kind text, p_amount_cents bigint, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare bid uuid;
begin
  if not public.is_admin() then raise exception 'Only the platform admin can charge services'; end if;
  if p_kind not in ('subscription','featured','setup','layout','cc_goods') then
    raise exception 'CC Cash pays only for Carriacou Connect services and goods: subscription, featured listings/ads, setup, custom layout or Carriacou Connect goods'; end if;
  if not exists (select 1 from public.vendors where id = p_vendor) then raise exception 'Business not found'; end if;
  if coalesce(p_amount_cents, 0) <= 0 then raise exception 'Enter an amount'; end if;
  bid := public._settle(p_vendor, p_kind, p_amount_cents, nullif(btrim(coalesce(p_note, '')), ''));
  return (select to_jsonb(b) from public.vendor_bills b where id = bid);
end $$;
revoke all on function public.admin_charge_service(uuid,text,bigint,text) from public, anon;
grant execute on function public.admin_charge_service(uuid,text,bigint,text) to authenticated;

-- fee class: card = paid online by card through the processor; everything else = direct (pay on pickup)
create or replace function public.orders_fee_trg() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags(); cls text; rate numeric; fee record; base bigint; amt bigint;
begin
  if not f.vendor_credit_enabled then return new; end if;
  cls := case when new.payment_method in ('pay_card_online','pay_with_wallet') then 'card' else 'direct' end;
  rate := case when cls = 'card' then f.fee_card_pct else f.fee_direct_pct end;
  base := round(new.total_xcd * 100);
  select * into fee from public.order_fees where order_id = new.id;
  if (tg_op = 'UPDATE' and ((new.status = 'cancelled' and old.status is distinct from 'cancelled') or (new.payment_status = 'refunded' and old.payment_status is distinct from 'refunded'))) then
    if found and fee.status = 'charged' then
      amt := round(fee.fee_cents * f.fee_refund_pct / 100);
      update public.order_fees set status = 'refunded', refund_cents = amt, refunded_at = now() where order_id = new.id;
      if fee.billed_at is not null and amt > 0 then
        insert into public.vendor_funds_ledger(vendor_id, amount_cents, kind, note, created_by)
          values (new.vendor_id, amt, 'fee_refund', 'Fee refund, order ' || new.order_number, auth.uid());
      end if;
    end if;
    return new;
  end if;
  if new.status = 'cancelled' then return new; end if;
  if not found then
    if tg_op = 'UPDATE' then return new; end if;
    insert into public.order_fees(order_id, vendor_id, fee_class, rate_pct, base_cents, fee_cents)
      values (new.id, new.vendor_id, cls, rate, base, round(base * rate / 100));
  elsif fee.billed_at is null and fee.status = 'charged' and (fee.base_cents <> base or fee.fee_class <> cls) then
    update public.order_fees set fee_class = cls, rate_pct = rate, base_cents = base, fee_cents = round(base * rate / 100) where order_id = new.id;
  end if;
  return new;
end $$;
revoke all on function public.orders_fee_trg() from public, anon, authenticated;

-- vendor_funds(): same data + the CC Cash name and what it pays for (no Points Store gift cards any more)
create or replace function public.vendor_funds(p_vendor uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags();
begin
  if not (public.vendor_perm(p_vendor, 'refunds') or public.is_admin()) then raise exception 'Only the owner or a sub-admin of the business can see CC Cash'; end if;
  return jsonb_build_object(
    'vendor_id', p_vendor, 'currency', 'CC Cash', 'balance_cents', public._funds_bal(p_vendor), 'sub_credit_cents', public._subcred_bal(p_vendor),
    'test_mode', f.credit_test_mode, 'fee_card_pct', f.fee_card_pct, 'fee_direct_pct', f.fee_direct_pct, 'fee_refund_pct', f.fee_refund_pct,
    'next_cycle', public._next_cycle(), 'topup_max_cents', f.topup_test_max_cents,
    'spend_on', to_jsonb(array['subscription','fees','featured','setup','layout','cc_goods']),
    'unbilled_cents', (select coalesce(sum(fee_cents), 0) from public.order_fees where vendor_id = p_vendor and billed_at is null and status = 'charged'),
    'fees', coalesce((select jsonb_agg(x order by x->>'charged_at' desc) from (select jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'fee_class', fe.fee_class,
        'rate_pct', fe.rate_pct, 'base_cents', fe.base_cents, 'fee_cents', fe.fee_cents, 'status', fe.status, 'refund_cents', fe.refund_cents,
        'charged_at', fe.charged_at, 'billed_at', fe.billed_at) x from public.order_fees fe join public.orders o on o.id = fe.order_id
        where fe.vendor_id = p_vendor order by fe.charged_at desc limit 50) q), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(to_jsonb(l) - 'idempotency_key' order by l.created_at desc, l.id desc) from (select * from public.vendor_funds_ledger where vendor_id = p_vendor order by created_at desc, id desc limit 50) l), '[]'::jsonb),
    'sub_credit', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc, l.id desc) from (select * from public.vendor_sub_credit_ledger where vendor_id = p_vendor order by created_at desc, id desc limit 30) l), '[]'::jsonb),
    'bills', coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at desc) from (select * from public.vendor_bills where vendor_id = p_vendor order by created_at desc limit 20) b), '[]'::jsonb),
    'giftcards', jsonb_build_object('closed', true),
    'exit', (select to_jsonb(e) from public.vendor_exit_requests e where vendor_id = p_vendor order by created_at desc limit 1));
end $$;
revoke all on function public.vendor_funds(uuid) from public, anon;
grant execute on function public.vendor_funds(uuid) to authenticated;

-- opting a shop into the (closed) Points Store is no longer possible
create or replace function public.vendor_set_giftcards(p_vendor uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.vendor_perm(p_vendor, 'refunds') then raise exception 'Only the owner or a sub-admin can change this'; end if;
  if p_on then raise exception 'The Points Store shop gift cards are closed (v1.20): points cannot pay for vendor goods'; end if;
  update public.vendor_giftcard_settings set participating = false, opted_out_at = coalesce(opted_out_at, now()), updated_at = now() where vendor_id = p_vendor and participating;
  return jsonb_build_object('closed', true);
end $$;
revoke all on function public.vendor_set_giftcards(uuid, boolean) from public, anon;
grant execute on function public.vendor_set_giftcards(uuid, boolean) to authenticated;
update public.vendor_giftcard_settings set participating = false, opted_out_at = coalesce(opted_out_at, now()), updated_at = now() where participating;

-- ---------- 7. shop gift card tab: a status call that never fails with 400 for a locked plan ----------
create or replace function public.sgc_status(p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if public.vendor_role(p_vendor) is null and not public.is_admin() then raise exception 'Business not found'; end if;
  return jsonb_build_object('tier_ok', public._sgc_tier_ok(p_vendor),
    'has_cards', exists (select 1 from public.shop_gift_cards where vendor_id = p_vendor));
end $$;
revoke all on function public.sgc_status(uuid) from public, anon;
grant execute on function public.sgc_status(uuid) to authenticated;


-- ---------- 8. vendors pay their own plan (renewal or upgrade) with CC Cash ----------
-- One month at a time at the platform price (platform_tier_prices). The whole payment is one transaction under the
-- shop's funds lock: the balance is checked, the CC Cash is taken, the bill is written and the plan changes together,
-- or nothing happens. Too little CC Cash = refused (never invoiced, never partly paid).
create table if not exists public.vendor_subscriptions (
  vendor_id     uuid primary key references public.vendors(id) on delete cascade,
  tier          text not null references public.tier_limits(tier),
  paid_through  date not null,
  last_bill_id  uuid,
  last_paid_at  timestamptz not null default now(),
  updated_by    uuid
);
alter table public.vendor_subscriptions enable row level security;
revoke all on public.vendor_subscriptions from public, anon, authenticated;
drop policy if exists vendor_subscriptions_select on public.vendor_subscriptions;
create policy vendor_subscriptions_select on public.vendor_subscriptions for select
  using (public.vendor_perm(vendor_id, 'plan') or public.vendor_perm(vendor_id, 'refunds') or public.is_admin());
grant select on public.vendor_subscriptions to authenticated;

-- guard_vendor (schema.sql) silently keeps the old tier when a vendor updates their own row. A plan paid with CC Cash is the one
-- vendor-side tier change allowed: vendor_pay_subscription sets cc.plan_paid to the shop id for its own transaction only.
create or replace function public.guard_vendor() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if tg_op = 'INSERT' then
      if not exists (select 1 from public.profiles where id = auth.uid() and role = 'vendor') then
        raise exception 'Only vendor accounts can create a business profile';
      end if;
      new.tier := 'lite';
      new.owner_id := auth.uid();
      new.is_sample := false;
    else
      if coalesce(current_setting('cc.plan_paid', true), '') is distinct from old.id::text then new.tier := old.tier; end if;
      new.owner_id := old.owner_id;
      new.is_sample := old.is_sample;
    end if;
  end if;
  return new;
end $$;

create or replace function public.vendor_subscription_quote(p_vendor uuid, p_tier text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v record; cur record; want record; pr record; sub record; bal bigint; price bigint; start_d date;
begin
  if not (public.vendor_perm(p_vendor, 'plan') or public.vendor_perm(p_vendor, 'refunds') or public.is_admin()) then
    raise exception 'Only the business owner can see plan payments'; end if;
  select * into v from public.vendors where id = p_vendor;
  if not found then raise exception 'Business not found'; end if;
  select * into cur from public.tier_limits where tier = v.tier;
  select * into want from public.tier_limits where tier = coalesce(p_tier, v.tier);
  if not found then raise exception 'Unknown plan'; end if;
  select * into pr from public.platform_tier_prices where tier = want.tier;
  select * into sub from public.vendor_subscriptions where vendor_id = p_vendor;
  bal := public._funds_bal(p_vendor);
  price := round(coalesce(pr.monthly_price_xcd, 0) * 100)::bigint;
  start_d := case when want.tier = v.tier and sub.paid_through is not null and sub.paid_through >= (now() at time zone 'America/Grenada')::date
                  then sub.paid_through else (now() at time zone 'America/Grenada')::date end;
  return jsonb_build_object('tier', want.tier, 'label', want.label, 'current_tier', v.tier, 'current_label', cur.label,
    'kind', case when want.rank > cur.rank then 'upgrade' when want.rank = cur.rank then 'renewal' else 'downgrade' end,
    'price_cents', price, 'price_is_placeholder', coalesce(pr.is_placeholder, true),
    'balance_cents', bal, 'enough', bal >= price, 'short_cents', greatest(price - bal, 0),
    'paid_through', sub.paid_through, 'new_paid_through', (start_d + interval '1 month')::date,
    'can_pay', want.rank >= cur.rank and price > 0 and public.vendor_perm(p_vendor, 'plan'),
    'currency', 'CC Cash', 'test_mode', (public._flags()).credit_test_mode);
end $$;
revoke all on function public.vendor_subscription_quote(uuid, text) from public, anon;
grant execute on function public.vendor_subscription_quote(uuid, text) to authenticated;

create or replace function public.vendor_pay_subscription(p_vendor uuid, p_tier text, p_key text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.platform_flags := public._flags(); v record; cur record; want record; pr record; sub record;
  bal bigint; price bigint; bid uuid := gen_random_uuid(); start_d date; thru date; k text := left(nullif(btrim(coalesce(p_key, '')), ''), 60);
  kind text; today date := (now() at time zone 'America/Grenada')::date;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if not public.vendor_perm(p_vendor, 'plan') then raise exception 'Only the business owner can pay for the plan'; end if;
  if not f.vendor_credit_enabled then raise exception 'CC Cash is switched off'; end if;
  -- one payment at a time per shop (same lock as every other CC Cash movement)
  perform pg_advisory_xact_lock(hashtext('funds:' || p_vendor::text));
  if k is not null and exists (select 1 from public.vendor_funds_ledger where vendor_id = p_vendor and idempotency_key = k) then
    return jsonb_build_object('replay', true, 'balance_cents', public._funds_bal(p_vendor),
      'tier', (select tier from public.vendors where id = p_vendor),
      'paid_through', (select paid_through from public.vendor_subscriptions where vendor_id = p_vendor)); end if;
  select * into v from public.vendors where id = p_vendor for update;
  if not found then raise exception 'Business not found'; end if;
  if v.status in ('suspended','rejected') then raise exception 'This business cannot pay for a plan right now'; end if;
  select * into cur from public.tier_limits where tier = v.tier;
  select * into want from public.tier_limits where tier = p_tier;
  if not found then raise exception 'Unknown plan'; end if;
  if want.rank < cur.rank then raise exception 'To move to a smaller plan, contact Carriacou Connect. CC Cash pays for renewals and upgrades.'; end if;
  select * into pr from public.platform_tier_prices where tier = want.tier;
  price := round(coalesce(pr.monthly_price_xcd, 0) * 100)::bigint;
  if price <= 0 then raise exception 'The % plan is free: there is nothing to pay', want.label; end if;
  bal := public._funds_bal(p_vendor);
  if bal < price then
    raise exception 'CC_CASH_LOW: Not enough CC Cash. The % plan costs % and your balance is %. Top up % or more and try again.',
      want.label, public._rt_money(price / 100.0), public._rt_money(bal / 100.0), public._rt_money((price - bal) / 100.0);
  end if;
  kind := case when want.rank > cur.rank then 'upgrade' else 'renewal' end;
  select * into sub from public.vendor_subscriptions where vendor_id = p_vendor for update;
  -- renewal adds a month after the current paid-through date; an upgrade starts a new month today
  start_d := case when kind = 'renewal' and sub.paid_through is not null and sub.paid_through >= today then sub.paid_through else today end;
  thru := (start_d + interval '1 month')::date;
  insert into public.vendor_bills(id, vendor_id, kind, period_end, total_cents, from_sub_credit_cents, from_funds_cents, invoice_cents, status, note, created_by)
    values (bid, p_vendor, 'subscription', thru, price, 0, price, 0, 'settled',
            want.label || ' plan ' || kind || ', paid with CC Cash (to ' || to_char(thru, 'DD Mon YYYY') || ')', auth.uid());
  insert into public.vendor_funds_ledger(vendor_id, amount_cents, kind, note, ref, created_by, idempotency_key)
    values (p_vendor, -price, 'subscription', left(want.label || ' plan ' || kind, 200), bid::text, auth.uid(), k);
  if kind = 'upgrade' then
    perform set_config('cc.plan_paid', p_vendor::text, true);
    perform public._apply_tier(p_vendor, want.tier);
    perform set_config('cc.plan_paid', '', true);
    if (select tier from public.vendors where id = p_vendor) is distinct from want.tier then
      raise exception 'The plan could not be changed, so nothing was charged. Please contact Carriacou Connect.'; end if;
    update public.tier_requests set status = 'approved', decided_by = auth.uid(), decided_at = now(),
      decision_note = 'Paid with CC Cash' where vendor_id = p_vendor and status = 'pending' and to_tier = want.tier;
    update public.tier_requests set status = 'cancelled' where vendor_id = p_vendor and status = 'pending';
  end if;
  insert into public.vendor_subscriptions(vendor_id, tier, paid_through, last_bill_id, last_paid_at, updated_by)
    values (p_vendor, want.tier, thru, bid, now(), auth.uid())
    on conflict (vendor_id) do update set tier = excluded.tier, paid_through = excluded.paid_through,
      last_bill_id = excluded.last_bill_id, last_paid_at = excluded.last_paid_at, updated_by = excluded.updated_by;
  perform public._audit(p_vendor, 'plan_paid_cc_cash', null,
    jsonb_build_object('kind', kind, 'from', cur.tier, 'to', want.tier, 'cents', price, 'paid_through', thru, 'bill', bid));
  return jsonb_build_object('replay', false, 'ok', true, 'kind', kind, 'tier', want.tier, 'label', want.label, 'paid_cents', price,
    'balance_cents', public._funds_bal(p_vendor), 'paid_through', thru, 'bill_id', bid, 'test_mode', f.credit_test_mode);
end $$;
revoke all on function public.vendor_pay_subscription(uuid, text, text) from public, anon;
grant execute on function public.vendor_pay_subscription(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
