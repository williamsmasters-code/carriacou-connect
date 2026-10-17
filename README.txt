CARRIACOU CONNECT MARKETPLACE v0.1 (static preview)
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
