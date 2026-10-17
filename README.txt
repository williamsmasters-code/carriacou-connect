CARRIACOU CONNECT MARKETPLACE v0.6 (static preview + optional Supabase accounts + TEST-MODE wallets)
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


=====================================================================
v0.4: CONSUMER DASHBOARD + ORDERS / CHECKOUT (NO ONLINE PAYMENT)
=====================================================================
ORDERS SETUP (required once, after schema.sql)
  12. Dashboard > SQL Editor > New query. Paste the whole of supabase/orders.sql and Run. Expect "Success".
      Safe to run again. It: adds order columns (order_number CC-001001..., fulfilment, payment_method,
      contact + delivery details, subtotal/total in XCD), replaces the old status list with
      placed / confirmed / ready / out_for_delivery / completed / cancelled, creates order_status_history,
      locks down Row Level Security, and creates the place_order() function.
  Without orders.sql, checkout shows an error and the dashboards say orders.sql has not been run.

How ordering works
  - cart.html > Checkout (live mode only) > checkout.html. Not logged in? You are sent to login and brought back.
  - Choose Pickup (pay on pickup) or Delivery (pay on delivery, address required), phone, notes, then Place order.
    NO online payment. Carriacou Connect Pay comes later.
  - The browser calls the database function place_order(). It re-reads every price from the products table
    (the browser never sends prices), rejects the whole cart if any item is missing/inactive, and creates ONE
    order per vendor, each with an item snapshot (name, unit price, qty, line total) and a history row.
  - Consumers cannot insert orders directly; only place_order() creates them.

Security / rules (all enforced in the database, not just the browser)
  - Consumers read only their own orders; vendors read only orders for their own business; nobody can delete.
  - Clients can update ONLY the status column. A trigger enforces who may move where:
      consumer:  placed -> cancelled
      vendor:    placed -> confirmed | cancelled;  confirmed -> ready | cancelled;
                 ready -> completed (pickup) or out_for_delivery (delivery) | cancelled;
                 out_for_delivery -> completed | cancelled.  completed / cancelled are final.
  - Every status change is recorded in order_status_history (who, when) and updates status_updated_at.
  - Vendors cannot change totals, items, customer details.  Admin / SQL editor changes are unrestricted.

New / changed files
  checkout.html      new checkout page + confirmation (logic in app.js)
  dashboard-consumer.html (auth.js)  Orders tab (list, detail, timeline, cancel while placed), Profile tab
  dashboard-vendor.html   (auth.js)  Products tab + Orders tab (filter by status, NEW badge, status buttons)
  account.html       profile now includes delivery address
  cc.js              order helpers (status pills, timeline, safe "next" redirect); version text v0.4
  supabase/orders.sql  see above;  style.css  v0.4 additions (same look)
Sample mode (no Supabase): checkout / dashboards show a "not switched on" notice; nothing breaks.
Note: the 6 SAMPLE vendors have no owner account, so orders placed with them cannot be processed by anyone.
  Test with a real vendor account's products. Delivery fees are not calculated yet (always EC$0.00).
Testing done (outside the repo, /workspace/cconnect/test): orders.sql run twice against a local Postgres with
  the full permission matrix checked; headless Chrome flows at 390 and 1280 against a mocked Supabase.


=====================================================================
v0.5: TWO-WAY ORDER NOTES (VENDOR <-> CUSTOMER)
=====================================================================
NEW SQL STEP (required once, after orders.sql)
  13. Dashboard > SQL Editor > New query. Paste the whole of supabase/order_notes.sql and Run. Expect "Success".
      Safe to run again. It creates:
        order_notes        id, order_id, author_id, author_role (consumer|vendor), author_name, body (1-1000 chars), created_at
        order_note_reads   who last read the notes of which order (drives the "New note" badge)
        functions          is_order_party(), mark_order_notes_read(order), order_note_summary()
      Without it, the Notes box shows "Notes are not switched on yet" (nothing else breaks).

How it works
  - Vendor dashboard > Orders tab: each order has a "Notes" section (click to open). Customer order page: a
    "Notes with <vendor>" section. Chat style, oldest first / newest at the bottom, shows name, role and time.
  - The note the customer typed at checkout is shown as the first message, marked "with the order".
  - Text box with a 0/1000 counter; Ctrl+Enter sends. The open thread refreshes every ~20 seconds and the
    badges refresh on the same timer. All text is HTML-escaped, so pasted markup shows as plain text.
  - A coral "New note" badge appears on an order (and a gold badge on the vendor's Orders tab) when the OTHER side
    wrote something you have not opened yet. Opening the thread marks it read.
  - Notes are allowed on every order status, including cancelled and completed.

Rules enforced in the database (not just the browser)
  - Only the order's customer and the owner of the order's vendor business can read or write its notes.
  - author_id must be you and author_role must match your side of that order. Name and time are set by the server.
  - Notes cannot be edited or deleted (no UPDATE / DELETE grant or policy).
  - Limits: 30 notes per order in total, and 10 notes per person per minute.
  - pg-safeupdate (Supabase): every UPDATE / DELETE in order_notes.sql has a WHERE clause.

Changed files: supabase/order_notes.sql (new), cc.js (notes widget, version text v0.5), auth.js (vendor + customer
  UI, badges), style.css (v0.5 notes styles), README.txt.
Testing (outside the repo, /workspace/cconnect/test): order_notes.sql run twice on a local Postgres 17 with a
  permission/limit test matrix (pgnotes.mjs); lint_safeupdate.js checks every UPDATE/DELETE has a WHERE;
  notes_flow.js + flows.js headless Chrome at 390 and 1280 against a mocked Supabase.


=====================================================================
v0.6: CARRIACOU CONNECT PAY, *** TEST MODE ONLY (PLAY MONEY) ***
=====================================================================
There is NO payment processor, NO card or bank details and NO real money anywhere in this version. Balances are
fake XCD "play money" created by a Test top-up button. Every Pay screen shows "TEST MODE - play money, not real funds".
Going live with real funds needs legal advice, licensing and Daniel's explicit approval: read ../Pay_Design_Notes.txt.

NEW SQL STEP (required once, after schema.sql, orders.sql and order_notes.sql)
  14. Dashboard > SQL Editor > New query. Paste the whole of supabase/pay.sql and Run. Expect "Success". Safe to run again.
      (orders.sql was also touched in v0.6: it now allows payment_method 'pay_with_wallet' and has the payment guard. You do NOT
       need to re-run it, pay.sql installs the same pieces. If you ever re-run orders.sql, re-run pay.sql after it.)
      Without pay.sql: the wallet page says "pay.sql has not been run", checkout hides the wallet option, nothing else breaks.
  To undo test data in the SQL editor: the ledger is append-only on purpose (see Pay_Design_Notes.txt, "Resetting test data").

What you get
  wallet.html  (logged-in consumers and vendors; nav "Wallet")  balance, wallet code CC-XXXX-XXXX with Copy, QR code of the code,
               Add test money (max EC$500 per top-up and per rolling 24h), Send to another wallet (by code or email, with a
               "send EC$x to <name>?" confirm step), Pay a shop charge (enter a PAY-XXXX-XXXX code), transaction history.
               Vendors also get a business wallet (tab), separate from their personal wallet.
  pos.html     (vendors; linked from the vendor dashboard)  pick products and/or a custom amount, create a charge: shows a code and
               QR that expire after 15 minutes; the screen flips to PAID when the customer pays; cancel anytime; recent charges.
               v1 flow: customer opens Wallet > "Pay a shop charge", enters the code (or scans the QR, which opens wallet.html?pay=CODE).
  pay.js       logic for wallet.html and pos.html;  vendor/qrcode.js  QR generator (qrcode-generator 2.0.4, MIT, runs in the browser)
  checkout     new "How do you want to pay?": pay the vendor yourself (as before) OR "Pay with wallet (test)": places the order(s) and
               pays them in one all-or-nothing database call. Orders show Paid / Unpaid / Refunded. An unpaid order can be paid later
               from its order page. Vendors see a Paid badge and a "Refund (test)" button. Cancelling a PAID order refunds it automatically.

Database (supabase/pay.sql)
  wallets        one per user, one per vendor business, plus one hidden system "test mint". balance_cents integer, never negative.
  transactions   APPEND-ONLY double-entry ledger (type topup_test | transfer | order_payment | refund | adjustment; from_wallet, to_wallet,
                 amount_cents > 0, status, order_id, test_mode must be true). Updates, deletes and truncate are blocked for EVERYONE.
                 Test top-ups are mint -> wallet, so SUM(user+vendor balances) = SUM(test top-ups) always.
  pay_requests   POS charge requests.   pay_attempts  failed lookups, for rate limiting.
  orders         + payment_status (unpaid | paid | refunded), paid_at; payment_method may now be pay_with_wallet. place_order() is unchanged.
  Functions (all SECURITY DEFINER, logged-in only): ensure_wallets, test_topup(cents,key,wallet), transfer_wallet(to,cents,note,key,from),
    wallet_preview(code), wallet_history(wallet,limit,before), pay_orders(ids,key), pay_order(id,key), refund_order(id),
    create_charge(cents,note,items), cancel_charge(id), charge_preview(code), pay_charge(code,key,from), pay_limits(), pay_reconcile() (admin).
  Reconciliation (SQL editor):  select public.pay_reconcile();   or   select * from public.pay_reconciliation;
    "ok": true means every wallet equals its ledger credits minus debits, none is negative and total balances = total test top-ups.

Rules enforced in the database (not just the browser)
  - Clients cannot INSERT/UPDATE/DELETE wallets, transactions or charges, and cannot change an order's payment columns. Money moves only inside the functions.
  - Each move locks both wallets in id order (no deadlocks, no double spend), refuses overdrafts, amounts < EC$0.01, over EC$2,000 per transfer / charge,
    balances over EC$100,000, and sending to your own wallet. Amounts are integer cents.
  - Idempotency: pass a key (the web pages do) and a repeated request returns the first result instead of moving money twice. Same key with a different
    request is refused. An order can only ever be paid once and refunded once (unique indexes), even under concurrent taps.
  - Privacy: Row Level Security shows you only your own wallets and transactions. Recipients are shown as a masked label ("Bob G." or the business name).
    Unknown recipient (code or email) always gives the same "not found" answer and is rate limited (10 misses per 10 minutes). Email lookup is accepted
    for sending but the preview step refuses email probing. 20 transfers per 10 minutes per user.
  - A refund comes out of the vendor wallet. If the vendor has moved the money away, the refund (and cancelling that paid order) is refused with a clear message.
  - pg-safeupdate: every UPDATE / DELETE in pay.sql has a WHERE clause.

Testing done (outside the repo, /workspace/cconnect/test)
  pgpay.mjs  (126 checks): pay.sql run twice on local Postgres 17, then balances/ledger invariants, 30 concurrent transfers, opposing transfers (deadlock),
             concurrent idempotent requests, concurrent top-up cap, concurrent pay_order and pay_charge, overdraft, zero/negative/null/huge amounts, self transfer,
             idempotency, RLS leak checks, refunds, auto-refund on cancel, POS charges (expiry, cancel, double pay), ledger immutability, reconciliation + tamper detection,
             re-running orders.sql then pay.sql.   pgupgrade.mjs: v0.5 database upgraded to v0.6 with an existing order.   lint_safeupdate.js: PASS.
  pay_flow.js (96 checks) + flows.js + notes_flow.js: headless Chrome at 390 and 1280 against a mocked Supabase, no JS errors. Screenshots in ../shots/.
  NOT tested against the real Supabase project yet (as with every earlier step): expect small fixes once pay.sql has been run there.

Changed files: supabase/pay.sql (new), supabase/orders.sql (payment constraint + guard), wallet.html, pos.html, pay.js, vendor/qrcode.js (new),
  cc.js (nav Wallet link, test banner, money helpers, v0.6 text), app.js (checkout), auth.js (order pages, vendor refund + POS link), style.css, README.txt.


=== v0.7: Order PDF export (no SQL changes, nothing to run in Supabase) ===
  Customers: "Download PDF" on the order detail page.  Vendors: "Download PDF" on each order in the Orders tab, plus
  "Export these N orders (PDF)" which makes a one-table summary of the orders currently shown (respects the status filter).
  File names: CC-001001.pdf (order number); summary = CC-orders-YYYY-MM-DD.pdf.
  PDF contents: header/logo text, order number, date, status, vendor, customer/contact, fulfilment, delivery address (or pickup place),
    order instructions, items table (qty, unit price, line total), subtotal, delivery fee, total in XCD, payment method + status
    (marked TEST MODE for wallet payments), status history, order notes thread, footer with generated time and page numbers, and a
    "Sample/Test data" note for wallet-paid orders or SAMPLE vendors. Long item lists and notes continue across pages.
  How: generated in the browser by jsPDF 4.2.1 (MIT) vendored in vendor/jspdf.umd.min.js (licence: vendor/jspdf-LICENSE.txt), loaded only when
    a PDF is requested. No CDN, no server, nothing uploaded. orderpdf.js holds the layout; buttons are wired in auth.js.
  Privacy: uses only rows the signed-in user can already read (orders, items, history, notes via Row Level Security). A vendor PDF includes
    the customer's order contact name/phone and delivery address (as the Orders tab already shows); a customer PDF has their own.
  Text is sanitized: control characters removed, characters outside the standard PDF font set (e.g. emoji, CJK) print as "?". No HTML is
    ever interpreted.
  Tests: test/pdf_flow.js (headless Chrome 390 and 1280, mocked Supabase: downloads, pdftotext checks, 6-page long order, no JS errors).
  Changed files: orderpdf.js (new), vendor/jspdf.umd.min.js + jspdf-LICENSE.txt (new), auth.js, dashboard-consumer.html, dashboard-vendor.html, style.css, README.txt.
