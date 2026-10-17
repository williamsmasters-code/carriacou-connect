(function(){
const $=s=>document.querySelector(s);
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const xcd=n=>'EC$'+Number(n).toFixed(2);
const qs=new URLSearchParams(location.search);
let DATA;
// ---- cart (localStorage) ----
const KEY='cconnect_cart_v1';
const getCart=()=>{try{return JSON.parse(localStorage.getItem(KEY))||{}}catch(e){return{}}};
const saveCart=c=>{localStorage.setItem(KEY,JSON.stringify(c));badge()};
function addCart(id,q){const c=getCart();c[id]=Math.min(99,(c[id]||0)+q);saveCart(c)}
function badge(){const n=Object.values(getCart()).reduce((a,b)=>a+b,0);const e=$('#cartCount');if(e)e.textContent=n}
// ---- placeholder SVG images ----
function shade(hex,p){const n=parseInt(hex.slice(1),16);const f=v=>Math.max(0,Math.min(255,Math.round(v+(p>0?(255-v):v)*p)));return'#'+[n>>16,(n>>8)&255,n&255].map(f).map(v=>v.toString(16).padStart(2,'0')).join('')}
function svg(p,v){const c=p.color,l=shade(c,.45),d=shade(c,-.3);
const art=[
`<circle cx="200" cy="130" r="70" fill="${l}"/><path d="M0 220 Q100 180 200 220 T400 220 V300 H0Z" fill="${d}"/>`,
`<rect x="110" y="80" width="180" height="140" rx="20" fill="${l}"/><circle cx="200" cy="150" r="40" fill="${d}"/>`,
`<path d="M200 60 L300 230 H100Z" fill="${l}"/><circle cx="90" cy="70" r="30" fill="#f4b942"/><rect y="250" width="400" height="50" fill="${d}"/>`][v%3];
const t=p.name.replace('SAMPLE ','');
const s=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300"><rect width="400" height="300" fill="${c}"/>${art}<text x="200" y="280" font-family="sans-serif" font-size="20" font-weight="700" fill="#fff" text-anchor="middle">${esc(t).slice(0,28)}</text><text x="10" y="20" font-family="sans-serif" font-size="12" fill="#fff">SAMPLE</text></svg>`;
return'data:image/svg+xml;utf8,'+encodeURIComponent(s)}
const img=(p,v=0,cls='ph')=>`<img class="${cls}" alt="${esc(p.name)} (placeholder image ${v+1})" src="${svg(p,v)}" loading="lazy">`;
const vendor=id=>DATA.vendors.find(v=>v.id===id);
const tierBadge=t=>`<span class="badge t-${t.replace('+','')}">${esc(t)}</span>`;
const card=p=>`<a class="card" href="product.html?id=${p.id}">${img(p)}<div class="body"><h3>${esc(p.name)}</h3><div class="muted">${esc(vendor(p.vendorId).name)}</div><div class="price">${xcd(p.price)} XCD</div></div></a>`;
// ---- pages ----
const pages={
home(){
$('#cats').innerHTML=DATA.categories.map(c=>`<a class="cat" style="background:${c.color}" href="browse.html?cat=${c.id}">${esc(c.name)}</a>`).join('');
$('#featured').innerHTML=DATA.products.filter(p=>p.featured).map(card).join('');
$('#vendors').innerHTML=DATA.vendors.map(v=>`<a class="card" href="vendor.html?id=${v.id}"><div class="body"><h3>${esc(v.name)}</h3>${tierBadge(v.tier)}<div class="muted">${esc(v.location)}</div></div></a>`).join('')},
browse(){
const cs=$('#cat'),vs=$('#vend');
cs.innerHTML='<option value="">All categories</option>'+DATA.categories.map(c=>`<option value="${c.id}">${esc(c.name)}</option>`).join('');
vs.innerHTML='<option value="">All vendors</option>'+DATA.vendors.map(c=>`<option value="${c.id}">${esc(c.name)}</option>`).join('');
cs.value=qs.get('cat')||'';$('#q').value=qs.get('q')||'';
const run=()=>{const q=$('#q').value.toLowerCase(),sort=$('#sort').value;
let r=DATA.products.filter(p=>(!cs.value||p.category===cs.value)&&(!vs.value||p.vendorId===vs.value)&&(!q||(p.name+p.description+vendor(p.vendorId).name).toLowerCase().includes(q)));
if(sort==='lo')r.sort((a,b)=>a.price-b.price);if(sort==='hi')r.sort((a,b)=>b.price-a.price);
$('#count').textContent=r.length+' product(s)';$('#list').innerHTML=r.map(card).join('')||'<p>No products match.</p>'};
['input','change'].forEach(e=>document.querySelector('.filters').addEventListener(e,run));run()},
vendor(){const v=vendor(qs.get('id'));if(!v){$('#v').innerHTML='<p>Vendor not found.</p>';return}
document.title=v.name+' – Carriacou Connect';
const ps=DATA.products.filter(p=>p.vendorId===v.id);
$('#v').innerHTML=`<h1>${esc(v.name)} ${tierBadge(v.tier)}</h1><p>${esc(v.about)}<br><span class="muted">${esc(v.location)}, Carriacou · ${esc(v.tier)} plan · ${ps.length} of ${DATA.tiers[v.tier]??'unlimited'} product slots used</span></p><div class="grid">${ps.map(card).join('')}</div>`},
product(){const p=DATA.products.find(x=>x.id===qs.get('id'));if(!p){$('#p').innerHTML='<p>Product not found.</p>';return}
document.title=p.name+' – Carriacou Connect';const v=vendor(p.vendorId),cat=DATA.categories.find(c=>c.id===p.category);
$('#p').innerHTML=`<div class="detail"><div><div id="big">${img(p,0,'main-img')}</div><div class="thumbs">${[0,1,2].map(i=>img(p,i,i?'':'on')).join('')}</div></div>
<div><h1>${esc(p.name)}</h1><p class="price" style="font-size:1.5rem">${xcd(p.price)} XCD</p><p>${esc(p.description)}</p>
<p class="muted">Category: <a href="browse.html?cat=${cat.id}">${esc(cat.name)}</a><br>Sold by <a href="vendor.html?id=${v.id}">${esc(v.name)}</a> ${tierBadge(v.tier)}</p>
<label>Qty <input id="qty" type="number" min="1" max="99" value="1" style="width:4rem;padding:.4rem"></label> <button class="btn" id="add">Add to cart</button><p id="msg" role="status"></p></div></div>`;
document.querySelectorAll('.thumbs img').forEach((t,i)=>t.onclick=()=>{$('#big').innerHTML=img(p,i,'main-img');document.querySelectorAll('.thumbs img').forEach(x=>x.classList.remove('on'));t.classList.add('on')});
$('#add').onclick=()=>{const q=Math.max(1,Math.min(99,parseInt($('#qty').value)||1));addCart(p.id,q);$('#msg').innerHTML='Added to cart. <a href="cart.html">View cart</a>'}},
cart(){const draw=()=>{const c=getCart(),ids=Object.keys(c).filter(i=>DATA.products.some(p=>p.id===i));
if(!ids.length){$('#cart').innerHTML='<p>Your cart is empty. <a href="browse.html">Browse products</a></p>';return}
let sum=0;const rows=ids.map(i=>{const p=DATA.products.find(x=>x.id===i),t=p.price*c[i];sum+=t;return`<tr><td><a href="product.html?id=${i}">${esc(p.name)}</a><div class="muted">${esc(vendor(p.vendorId).name)}</div></td><td>${xcd(p.price)}</td><td><input type="number" min="1" max="99" value="${c[i]}" data-id="${i}"></td><td>${xcd(t)}</td><td><button class="btn alt" data-rm="${i}" aria-label="Remove">✕</button></td></tr>`}).join('');
$('#cart').innerHTML=`<table><tr><th>Item</th><th>Price</th><th>Qty</th><th>Total</th><th></th></tr>${rows}</table><h2>Subtotal: ${xcd(sum)} XCD</h2><button class="btn" id="co">Checkout</button><div id="conote"></div>`;
document.querySelectorAll('input[data-id]').forEach(e=>e.onchange=()=>{const c=getCart();c[e.dataset.id]=Math.max(1,Math.min(99,parseInt(e.value)||1));saveCart(c);draw()});
document.querySelectorAll('[data-rm]').forEach(b=>b.onclick=()=>{const c=getCart();delete c[b.dataset.rm];saveCart(c);draw()});
$('#co').onclick=()=>{$('#conote').innerHTML='<div class="notice"><strong>Carriacou Connect Pay is coming soon.</strong><br>Checkout is a placeholder in this preview. No payment is taken and no order is placed.</div>'}};draw()}
};
function layout(){document.body.insertAdjacentHTML('afterbegin',`<div class="banner">Preview v0.1 – all vendors and products are SAMPLE data. No real payments.</div><header><div class="row"><a class="logo" href="index.html">Carriacou <span>Connect</span> Marketplace</a><nav><a href="browse.html">Browse</a><a href="cart.html">Cart (<span id="cartCount">0</span>)</a></nav></div></header>`);
document.body.insertAdjacentHTML('beforeend','<footer>Carriacou Connect® by Williams’ Tech · Marketplace v0.1 preview</footer>');badge()}
layout();
fetch('products.json').then(r=>r.json()).then(d=>{DATA=d;pages[document.body.dataset.page]()}).catch(e=>{console.error(e);document.querySelector('main').innerHTML='<p>Could not load data.</p>'});
})();
