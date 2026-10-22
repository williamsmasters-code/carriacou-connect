CARRIACOU CONNECT - CUSTOM SHOP LAYOUTS (v1.17)

What this is
Every shop uses the DEFAULT shop page layout. A CUSTOM layout is a bespoke design that Daniel builds for a special business (for example a pizza shop) as a paid service. There are no premade templates: each custom layout is built and refined in iterations with the shop owner.

How it works
1. Each custom layout lives in its own folder:  site/custom/<key>/
     layout.js   (required)  draws the shop page
     layout.css  (optional)  styles for that layout only
   <key> is lowercase letters, numbers and dashes, e.g. pizza-palace.
2. The platform admin turns it on for one shop: Admin > Vendors > open the shop > "Shop layout" > choose "Custom layout", type the key, Save.
   Only the admin can change this. The database (supabase/shop_layouts.sql) refuses changes from vendors.
3. When a shopper opens vendor.html?id=<shop>, the page loads /custom/<key>/layout.css and /custom/<key>/layout.js and calls the layout.
4. Safety: if the files are missing, have an error, take too long (6 seconds), or the layout throws while drawing, the shopper sees the normal default layout instead. Nothing breaks.

Creating a new custom layout
1. Copy the folder site/custom/example/ to site/custom/<new-key>/.
2. In layout.js change  CC.registerLayout('example', ...)  to  CC.registerLayout('<new-key>', ...).
3. In layout.css change every  .cl-example  to  .cl-<new-key>  (keeps the styles from leaking into other pages).
4. Build the design inside render(el, ctx). You get:
     ctx.shop       the shop: id, name, tier, location, about
     ctx.products   the shop's active products: id, name, price, description, category, imageUrl, featured
     ctx.cart       get(), add(productId, qty), count(), refreshBadge()  - the same cart as the rest of the site
     ctx.helpers    esc(text) for safe text, xcd(number) for EC$ prices, card(product) for the normal product card, productUrl(id)
     ctx.renderDefault()  draws the default layout (useful if you only want to add something on top)
   Always pass shop and product text through ctx.helpers.esc. Do not load scripts from other websites.
5. Test locally: set the shop to Custom with the new key in admin, open the shop page at phone and desktop widths, add items to the cart, and check checkout still works.
6. Commit the folder and publish the site. Then switch the shop to Custom in admin (or leave it on Default until the owner approves).
7. To undo at any time: switch the shop back to "Default layout" in admin. The key is kept for next time.

Charging for the service
Charging is manual. Use Admin > Funds & exits > "Charge a platform service" (Setup / photo service) and put the layout key and iteration in the note. Nothing is charged automatically.

Database
Run supabase/shop_layouts.sql once in Supabase, AFTER wallet_repurpose.sql. It is safe to run again.
