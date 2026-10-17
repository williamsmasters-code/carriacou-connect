-- Carriacou Connect SAMPLE data (fictional). Run AFTER schema.sql. Safe to re-run.
-- Sample vendors have no owner (owner_id null) so nobody can edit them; delete them any time with:
--   delete from public.vendors where is_sample;
insert into public.vendors (id, owner_id, name, description, location, tier, is_sample) values
  ('00000000-0000-4000-8000-000000000001', null, 'SAMPLE Windward Spice Co.', 'Small-batch spices and sauces (sample vendor).', 'Hillsborough', 'lite', true),
  ('00000000-0000-4000-8000-000000000002', null, 'SAMPLE Paradise Bay Crafts', 'Handmade gifts and art (sample vendor).', 'Paradise Beach', 'lite', true),
  ('00000000-0000-4000-8000-000000000003', null, 'SAMPLE Tyrrel Bay Chandlery', 'Supplies for sailors and boaters (sample vendor).', 'Tyrrel Bay', 'standard', true),
  ('00000000-0000-4000-8000-000000000004', null, 'SAMPLE Island Threads', 'Island-inspired clothing and textiles (sample vendor).', 'L''Esterre', 'standard', true),
  ('00000000-0000-4000-8000-000000000005', null, 'SAMPLE Carriacou Fresh Market', 'Local produce, pantry and home goods (sample vendor).', 'Hillsborough', 'plus', true),
  ('00000000-0000-4000-8000-000000000006', null, 'SAMPLE Grand Anse Wellness', 'Natural body care and wellness (sample vendor).', 'Harvey Vale', 'pro', true)
on conflict (id) do update set name=excluded.name, description=excluded.description, location=excluded.location, tier=excluded.tier;

insert into public.products (id, vendor_id, name, description, price_xcd, category, image_url, active, featured) values
  ('00000000-0000-4000-9000-000000000001', '00000000-0000-4000-8000-000000000001', 'SAMPLE Nutmeg Hot Sauce', 'Medium-heat sauce with island nutmeg. This is a SAMPLE product for demonstration only.', 18, 'food', null, true, false),
  ('00000000-0000-4000-9000-000000000002', '00000000-0000-4000-8000-000000000001', 'SAMPLE Cinnamon Sticks 100g', 'Fragrant whole cinnamon sticks. This is a SAMPLE product for demonstration only.', 12, 'food', null, true, false),
  ('00000000-0000-4000-9000-000000000003', '00000000-0000-4000-8000-000000000001', 'SAMPLE Spice Sampler Box', 'Six jars: nutmeg, mace, clove, cinnamon, ginger, allspice. This is a SAMPLE product for demonstration only.', 45, 'food', null, true, true),
  ('00000000-0000-4000-9000-000000000004', '00000000-0000-4000-8000-000000000001', 'SAMPLE Cocoa Tea Balls (6)', 'Traditional cocoa tea, ready to grate. This is a SAMPLE product for demonstration only.', 20, 'food', null, true, false),
  ('00000000-0000-4000-9000-000000000005', '00000000-0000-4000-8000-000000000002', 'SAMPLE Driftwood Wall Art', 'Hand-assembled driftwood piece. This is a SAMPLE product for demonstration only.', 85, 'crafts', null, true, true),
  ('00000000-0000-4000-9000-000000000006', '00000000-0000-4000-8000-000000000002', 'SAMPLE Shell Wind Chime', 'Chime made from beach-collected shells. This is a SAMPLE product for demonstration only.', 40, 'crafts', null, true, false),
  ('00000000-0000-4000-9000-000000000007', '00000000-0000-4000-8000-000000000002', 'SAMPLE Woven Palm Basket', 'Palm-leaf basket, sturdy and light. This is a SAMPLE product for demonstration only.', 55, 'crafts', null, true, false),
  ('00000000-0000-4000-9000-000000000008', '00000000-0000-4000-8000-000000000003', 'SAMPLE Braided Dock Line 10m', 'Marine-grade line for small boats. This is a SAMPLE product for demonstration only.', 65, 'sea', null, true, false),
  ('00000000-0000-4000-9000-000000000009', '00000000-0000-4000-8000-000000000003', 'SAMPLE Reef-Safe Sunscreen', 'SPF 50, reef-friendly formula. This is a SAMPLE product for demonstration only.', 38, 'sea', null, true, false),
  ('00000000-0000-4000-9000-000000000010', '00000000-0000-4000-8000-000000000003', 'SAMPLE Dry Bag 20L', 'Waterproof roll-top bag. This is a SAMPLE product for demonstration only.', 70, 'sea', null, true, false),
  ('00000000-0000-4000-9000-000000000011', '00000000-0000-4000-8000-000000000003', 'SAMPLE Snorkel Set', 'Mask, snorkel and travel bag. This is a SAMPLE product for demonstration only.', 120, 'sea', null, true, true),
  ('00000000-0000-4000-9000-000000000012', '00000000-0000-4000-8000-000000000004', 'SAMPLE Madras Print Shirt', 'Light cotton shirt, madras-inspired print. This is a SAMPLE product for demonstration only.', 95, 'fashion', null, true, true),
  ('00000000-0000-4000-9000-000000000013', '00000000-0000-4000-8000-000000000004', 'SAMPLE Beach Sarong', 'Quick-dry sarong in bold colours. This is a SAMPLE product for demonstration only.', 50, 'fashion', null, true, false),
  ('00000000-0000-4000-9000-000000000014', '00000000-0000-4000-8000-000000000004', 'SAMPLE Straw Sun Hat', 'Wide-brim hat for sunny days. This is a SAMPLE product for demonstration only.', 45, 'fashion', null, true, false),
  ('00000000-0000-4000-9000-000000000015', '00000000-0000-4000-8000-000000000005', 'SAMPLE Fresh Mango Box 2kg', 'Seasonal local mangoes. This is a SAMPLE product for demonstration only.', 30, 'food', null, true, true),
  ('00000000-0000-4000-9000-000000000016', '00000000-0000-4000-8000-000000000005', 'SAMPLE Aloe Plant in Pot', 'Hardy potted aloe vera. This is a SAMPLE product for demonstration only.', 25, 'home', null, true, false),
  ('00000000-0000-4000-9000-000000000017', '00000000-0000-4000-8000-000000000005', 'SAMPLE Local Honey 350ml', 'Raw island honey. This is a SAMPLE product for demonstration only.', 35, 'food', null, true, false),
  ('00000000-0000-4000-9000-000000000018', '00000000-0000-4000-8000-000000000005', 'SAMPLE Coconut Bowl Set (4)', 'Polished coconut-shell bowls. This is a SAMPLE product for demonstration only.', 48, 'home', null, true, false),
  ('00000000-0000-4000-9000-000000000019', '00000000-0000-4000-8000-000000000006', 'SAMPLE Coconut Body Butter', 'Rich, hand-whipped body butter. This is a SAMPLE product for demonstration only.', 42, 'beauty', null, true, true),
  ('00000000-0000-4000-9000-000000000020', '00000000-0000-4000-8000-000000000006', 'SAMPLE Sea Moss Gel 8oz', 'Prepared sea moss gel. This is a SAMPLE product for demonstration only.', 55, 'beauty', null, true, false)
on conflict (id) do update set name=excluded.name, description=excluded.description, price_xcd=excluded.price_xcd, category=excluded.category, featured=excluded.featured;
