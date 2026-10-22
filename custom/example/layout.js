// Example custom shop layout ("example"). Copy this folder to start a new bespoke layout.
// The shop page calls render(el, ctx) with:
//   ctx.shop      {id, name, tier, location, about}
//   ctx.products  [{id, name, price, description, category, imageUrl, featured}]
//   ctx.cart      {get(), add(productId, qty), count(), refreshBadge()}
//   ctx.helpers   {esc(text), xcd(number), card(product) -> default product card HTML, productUrl(id)}
//   ctx.renderDefault()  draws the normal shop layout (use it if you only want to add to it)
// Always escape shop/product text with ctx.helpers.esc. If this file throws, shoppers get the default layout.
CC.registerLayout('example', {
  render(el, ctx) {
    const { esc, xcd, productUrl } = ctx.helpers;
    const s = ctx.shop;
    const items = ctx.products.slice().sort((a, b) => (b.featured - a.featured) || a.name.localeCompare(b.name));
    el.innerHTML = `
      <section class="ex-hero">
        <span class="ex-kick">Carriacou Connect · bespoke shop</span>
        <h1>${esc(s.name)}</h1>
        <p>${esc(s.about || '')}</p>
        <p class="ex-loc">📍 ${esc(s.location || 'Carriacou')}</p>
      </section>
      <section class="ex-menu" aria-label="Menu">
        <h2>Menu</h2>
        ${items.length ? items.map(p => `
          <article class="ex-item">
            <div class="ex-txt"><h3><a href="${productUrl(p.id)}">${esc(p.name)}</a>${p.featured ? ' <span class="ex-star">★ Favourite</span>' : ''}</h3>
              <p>${esc(p.description || '')}</p></div>
            <div class="ex-buy"><b>${esc(xcd(p.price))}</b>
              <button type="button" class="btn ex-add" data-add="${esc(p.id)}">Add</button></div>
          </article>`).join('') : '<p>No items yet.</p>'}
      </section>
      <p class="ex-note" role="status" id="exmsg" hidden></p>`;
    el.querySelectorAll('[data-add]').forEach(b => b.onclick = () => {
      ctx.cart.add(b.dataset.add, 1);
      const m = el.querySelector('#exmsg'); m.hidden = false;
      m.innerHTML = 'Added to your cart (' + ctx.cart.count() + ' item(s)). <a href="cart.html">View cart</a>';
    });
  }
});
