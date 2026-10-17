CARRIACOU CONNECT MARKETPLACE v0.3 (static preview + optional Supabase accounts)
===================================================
ALL VENDORS AND PRODUCTS ARE SAMPLE DATA. NO REAL PAYMENTS.

Run locally:   cd site && python3 -m http.server 8000   then open http://localhost:8000
(A server is needed because products.json is loaded with fetch().)
Deploy:        GitHub Pages, serve the site folder as-is. No build step. All links are relative,
               so it works under a project path (user.github.io/repo/). .nojekyll included.

Files
  index.html    home: category grid, featured products, vendors
  browse.html   all products with search, category, vendor filter, price sort (?cat=, ?q=)
  vendor.html   ?id=v1  vendor name, tier badge, products, slots used vs tier limit
  product.html  ?id=p1  placeholder image gallery, description, EC$ price, add to cart
  cart.html     cart in localStorage (key cconnect_cart_v1), qty edit, remove, subtotal,
                placeholder Checkout (says Carriacou Connect Pay is coming; nothing is sent)
  app.js        all logic; style.css  Caribbean theme, mobile-first
  products.json SAMPLE data: tiers (limits), categories, vendors, products

Architecture notes
  - Plain HTML/CSS/JS. Page chosen by <body data-page=...>. Data read once from products.json.
  - Images are SVGs generated in JS from the product colour/name. No external assets.
  - Prices are XCD. Tier limits in products.json: Lite 10, Standard 25, Plus+ 50, Pro/Enterprise unlimited.
    The 6 sample vendors (2 Lite, 2 Standard, 1 Plus+, 1 Pro) respect these limits. No Enterprise sample yet.
  - Cart stores {productId: qty}; prices are always looked up from the data, never stored.

Next steps
  1. Review design and sample content; add real vendors/photos when available.
  2. Add backend (see ../Architecture_Plan.txt): accounts, vendor product management, orders.
  3. Carriacou Connect Pay (wallets, POS). Needs licensing/compliance review first.
  4. Vendor Dashboard enforcing tier limits server-side.


=====================================================================
v0.2: ACCOUNTS, VENDOR DASHBOARD, LIVE DATA (Supabase, free tier)
=====================================================================
Two modes, chosen automatically by config.js:
  SAMPLE mode  (config.js has the placeholder values): the marketplace reads products.json,
               login/signup pages say accounts are not switched on. The live site never breaks.
  LIVE mode    (config.js filled in): marketplace reads vendors/products from Supabase;
               signup, login, account, vendor and consumer dashboards work. If Supabase is
               unreachable the pages fall back to products.json.

New files
  config.js / config.example.js  Supabase URL + ANON key (public). Placeholders by default.
  cc.js            shared: config check, lazy supabase-js (CDN), nav with login/logout state
  auth.js          signup, login, account, vendor dashboard, consumer dashboard logic
  signup.html login.html account.html dashboard-vendor.html dashboard-consumer.html
  supabase/schema.sql  tables, Row Level Security, tier-limit trigger, auto-profile on signup
  supabase/seed.sql    the 6 SAMPLE vendors / 20 SAMPLE products

SETUP, step by step
  1. Create a project: go to https://supabase.com, sign up (free), click New project, pick a name,
     a strong database password (save it somewhere safe; the website never needs it) and the
     nearest region (e.g. East US). Wait ~2 minutes.
  2. Run the schema: Dashboard > SQL Editor > New query. Paste the whole of supabase/schema.sql
     and click Run. You should see "Success". (Safe to run again.)
  3. Load the sample data (optional but recommended): new query, paste supabase/seed.sql, Run.
     Remove it later with:  delete from public.vendors where is_sample;
  4. Get your keys: Project Settings > API (or the Connect button). Copy the Project URL and the
     "anon" / publishable key.
  5. Edit config.js and paste both values between the quotes (copy of config.example.js).
     ONLY the anon/publishable key. NEVER paste the service_role / secret key or the database
     password anywhere in this site; config.js is public on GitHub Pages. The anon key is safe
     to publish because Row Level Security restricts what it can do.
  6. Enable email auth: Authentication > Sign In / Providers > Email must be ON. For quick testing
     you may turn OFF "Confirm email" (then signup logs in immediately); for real use leave it ON.
  7. Set URLs: Authentication > URL Configuration:
       Site URL:      https://williamsmasters-code.github.io/carriacou-connect/
       Redirect URLs: https://williamsmasters-code.github.io/carriacou-connect/**
                      http://localhost:8000/**     (for local testing)
     (Free tier built-in email is rate limited to a few emails per hour; fine for testing.
      Add custom SMTP later for launch.)
  8. Commit config.js and push to GitHub. Pages redeploys in a minute or two.
  9. Test: sign up as a Vendor (business starts on Lite), confirm email, log in, add products.
     The 11th product on Lite is rejected by the database. Sign up as a Consumer in another browser.
 10. Make an admin (optional): sign up, then in the SQL Editor run
       update public.profiles set role='admin' where id=(select id from auth.users where email='you@example.com');
     Change a vendor's tier (billing is not built yet), e.g.
       update public.vendors set tier='standard' where name='My Business';
       tiers: lite (10 products), standard (25), plus (50, shown as Plus+), pro and enterprise (unlimited).

Security notes
  - Row Level Security is ON for every table. Public can read vendors and ACTIVE products only.
    Owners can read/write only their own business and products. Users can't make themselves admin
    and can't change their own tier. The tier product limit is enforced in the database (trigger),
    not just in the browser.
  - Orders/order_items are read-only stubs in v0.2 (checkout and Carriacou Connect Pay come later).
  - Product images are uploaded to Supabase Storage (v0.3, see below).

Next steps (v0.3): checkout/orders without payment, order management, image uploads,
  tier upgrades, then Carriacou Connect Pay (test mode, after licensing review).


=====================================================================
v0.3: IMAGE UPLOADS + REDESIGN
=====================================================================
STORAGE SETUP (required once for image uploads)
  11. Dashboard > SQL Editor > New query. Paste the whole of supabase/storage.sql and Run.
      It creates the public bucket 'product-images' (2 MB limit, JPG/PNG/WebP only) and policies:
      anyone can read; a signed-in vendor can add/replace/delete files only inside the folder
      named with their own user id (<uid>/<file>). Safe to run again.
  Uploads: vendor dashboard > product form > Choose image. The browser resizes to max 1200px and
  compresses before uploading; preview, Replace and Remove are supported. The public URL is saved in
  products.image_url. Replacing/removing/deleting a product also deletes the old file.
  Without storage.sql the product save shows an upload error (the rest of the site still works).
  Fonts: Google Fonts (Fraunces, Plus Jakarta Sans) with Georgia/system fallbacks.
  Design: dark-sea and warm-sand palette, wave dividers, glass header, category tiles with inline SVG.
  Nav: "Log in" text link and "Sign up" pill button.
