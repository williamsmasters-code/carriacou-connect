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
const img=(p,v=0,cls='ph')=>p.imageUrl&&v===0?`<img class="${cls}" alt="${esc(p.name)}" src="${esc(p.imageUrl)}" data-fb="${esc(svg(p,0))}" loading="lazy">`:`<img class="${cls}" alt="${esc(p.name)} (placeholder image ${v+1})" src="${svg(p,v)}" loading="lazy">`;
const vendor=id=>DATA.vendors.find(v=>v.id===id)||{id:'',name:'Unknown vendor',tier:'Lite',location:'',about:''};
const tierBadge=t=>`<span class="badge t-${t.replace('+','')}">${esc(t)}</span>`;
document.addEventListener('error',e=>{const t=e.target;if(t&&t.tagName==='IMG'&&t.dataset.fb&&t.src!==t.dataset.fb)t.src=t.dataset.fb},true);
const ICON={food:'<path d="M6 40c0-14 10-26 30-30-2 18-14 30-30 30zM6 40 28 18"/>',crafts:'<path d="M24 6a18 18 0 1 0 0 36c4 0 4-5 1-7s-1-7 4-7h6c5 0 7-3 7-7 0-9-8-15-18-15zM15 22h.1M22 15h.1M32 17h.1"/>',fashion:'<path d="M17 6 6 13l5 9 5-3v23h16V19l5 3 5-9-11-7c-1 4-4 6-7 6s-6-2-7-6z"/>',beauty:'<path d="M24 6c3 7 8 10 14 10-4 6-4 12 0 18-6 0-11 3-14 10-3-7-8-10-14-10 4-6 4-12 0-18 6 0 11-3 14-10z"/>',sea:'<path d="M6 30h36l-6 10H12zM24 6v24M24 8l14 20H24M22 12 12 28h10"/>',home:'<path d="M24 42V22M24 28c-8 0-12-6-12-12 8 0 12 5 12 12zM24 24c0-8 5-12 12-12 0 8-4 12-12 12zM14 42h20"/>'};
const catIcon=id=>`<svg viewBox="0 0 48 48" aria-hidden="true">${ICON[id]||ICON.home}</svg>`;
const card=p=>`<a class="card" href="product.html?id=${p.id}"><div class="imgw">${img(p)}</div><div class="body"><h3>${esc(p.name)}</h3><div class="muted">${esc(vendor(p.vendorId).name)}</div><div class="price">${xcd(p.price)} XCD</div></div></a>`;
// ---- pages ----
const pages={
home(){
$('#cats').innerHTML=DATA.categories.map(c=>`<a class="cat" style="--c:${esc(c.color)}" href="browse.html?cat=${c.id}">${catIcon(c.id)}<span>${esc(c.name)}</span></a>`).join('');
$('#featured').innerHTML=DATA.products.filter(p=>p.featured).map(card).join('');
$('#vendors').innerHTML=DATA.vendors.map(v=>`<a class="card vcard" href="vendor.html?id=${v.id}"><div class="body"><h3>${esc(v.name)}</h3>${tierBadge(v.tier)}<div class="muted">${esc(v.location)}</div></div></a>`).join('')},
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
$('#v').innerHTML=`<span class="kicker">Vendor</span><h1>${esc(v.name)} ${tierBadge(v.tier)}</h1><p>${esc(v.about)}<br><span class="muted">${esc(v.location)}, Carriacou · ${esc(v.tier)} plan · ${ps.length} of ${DATA.tiers[v.tier]??'unlimited'} product slots used</span></p><div class="grid">${ps.map(card).join('')}</div>`},
product(){const p=DATA.products.find(x=>x.id===qs.get('id'));if(!p){$('#p').innerHTML='<p>Product not found.</p>';return}
document.title=p.name+' – Carriacou Connect';const v=vendor(p.vendorId),cat=DATA.categories.find(c=>c.id===p.category)||DATA.categories[0];
$('#p').innerHTML=`<div class="detail"><div><div id="big">${img(p,0,'main-img')}</div><div class="thumbs">${[0,1,2].map(i=>img(p,i,i?'':'on')).join('')}</div></div>
<div class="buy"><h1>${esc(p.name)}</h1><p class="price">${xcd(p.price)} XCD</p><p>${esc(p.description)}</p>
<p class="muted">Category: <a href="browse.html?cat=${cat.id}">${esc(cat.name)}</a><br>Sold by <a href="vendor.html?id=${v.id}">${esc(v.name)}</a> ${tierBadge(v.tier)}</p>
<label>Qty <input id="qty" type="number" min="1" max="99" value="1" style="width:5rem"></label> <button class="btn" id="add">Add to cart</button><p id="msg" role="status"></p></div></div>`;
document.querySelectorAll('.thumbs img').forEach((t,i)=>t.onclick=()=>{$('#big').innerHTML=img(p,i,'main-img');document.querySelectorAll('.thumbs img').forEach(x=>x.classList.remove('on'));t.classList.add('on')});
$('#add').onclick=()=>{const q=Math.max(1,Math.min(99,parseInt($('#qty').value)||1));addCart(p.id,q);$('#msg').innerHTML='Added to cart. <a href="cart.html">View cart</a>'}},
cart(){const draw=()=>{const c=getCart(),ids=Object.keys(c).filter(i=>DATA.products.some(p=>p.id===i));
if(!ids.length){$('#cart').innerHTML='<p>Your cart is empty. <a href="browse.html">Browse products</a></p>';return}
let sum=0;const rows=ids.map(i=>{const p=DATA.products.find(x=>x.id===i),t=p.price*c[i];sum+=t;return`<tr><td><a href="product.html?id=${i}">${esc(p.name)}</a><div class="muted">${esc(vendor(p.vendorId).name)}</div></td><td>${xcd(p.price)}</td><td><input type="number" min="1" max="99" value="${c[i]}" data-id="${i}"></td><td>${xcd(t)}</td><td><button class="btn alt" data-rm="${i}" aria-label="Remove">✕</button></td></tr>`}).join('');
$('#cart').innerHTML=`<table><tr><th>Item</th><th>Price</th><th>Qty</th><th>Total</th><th></th></tr>${rows}</table><h2>Subtotal: ${xcd(sum)} XCD</h2><p class="muted">No online payment yet: you pay the vendor when you collect or receive your order.</p><button class="btn" id="co">Checkout</button><div id="conote"></div>`;
document.querySelectorAll('input[data-id]').forEach(e=>e.onchange=()=>{const c=getCart();c[e.dataset.id]=Math.max(1,Math.min(99,parseInt(e.value)||1));saveCart(c);draw()});
document.querySelectorAll('[data-rm]').forEach(b=>b.onclick=()=>{const c=getCart();delete c[b.dataset.rm];saveCart(c);draw()});
$('#co').onclick=()=>{if(DATA.live){location.href='checkout.html'}else $('#conote').innerHTML='<div class="notice"><strong>Ordering needs accounts, which are not switched on in this preview.</strong><br>In live mode you log in, choose pickup or delivery and place your order. You pay the vendor on pickup or delivery. Online payment (Carriacou Connect Pay) is coming later.</div>'}};draw()},
async checkout(){
const root=$('#co');
const payNote='<div class="notice"><strong>No online payment yet.</strong> You pay the vendor in cash (or however they agree with you) when you collect or receive your order. Carriacou Connect Pay is coming later.</div>';
if(!window.CC.configured||!DATA.live){root.innerHTML='<div class="notice"><strong>Ordering is not switched on in this sample preview.</strong> Accounts and orders need the live Supabase database. <a href="browse.html">Back to browsing</a></div>'+payNote;return}
const user=await window.CC.getUser();
if(!user){location.href='login.html?next=checkout.html';return}
const sb=await window.CC.client();
const c=getCart(),ids=Object.keys(c).filter(i=>DATA.products.some(p=>p.id===i));
if(!ids.length){root.innerHTML='<div class="notice">Your cart is empty. <a href="browse.html">Browse products</a></div>';return}
const lines=ids.map(i=>({p:DATA.products.find(x=>x.id===i),q:c[i]}));
const byV={};lines.forEach(l=>{(byV[l.p.vendorId]=byV[l.p.vendorId]||[]).push(l)});
let total=0;
const summary=Object.entries(byV).map(([vid,ls])=>{const sub=ls.reduce((a,l)=>a+l.p.price*l.q,0);total+=sub;
return `<div class="osum"><h3>${esc(vendor(vid).name)}</h3>${ls.map(l=>`<div class="oline"><span>${l.q} × ${esc(l.p.name)}</span><span>${xcd(l.p.price*l.q)}</span></div>`).join('')}<div class="oline sub"><span>Subtotal</span><span>${xcd(sub)}</span></div></div>`}).join('');
const nv=Object.keys(byV).length;
let prof={};try{const r=await sb.from('profiles').select('full_name,phone,address').eq('id',user.id).maybeSingle();prof=r.data||{}}catch(e){}
root.innerHTML=`<div class="co-grid"><form id="cof" class="formcard" novalidate>
<fieldset><legend>How do you want it?</legend>
<label class="chk opt"><input type="radio" name="ful" value="pickup" checked> <span><b>Pickup</b><small>Collect from the vendor. Pay on pickup.</small></span></label>
<label class="chk opt"><input type="radio" name="ful" value="delivery"> <span><b>Delivery</b><small>The vendor brings it to you. Pay on delivery. Any delivery fee is agreed with the vendor.</small></span></label></fieldset>
<label>Your name<input id="cn" maxlength="80" autocomplete="name" value="${esc(prof.full_name||'')}"></label>
<label>Contact phone *<input id="cp" type="tel" maxlength="30" autocomplete="tel" required value="${esc(prof.phone||'')}"></label>
<label id="adl" hidden>Delivery address *<textarea id="ca" rows="3" maxlength="300">${esc(prof.address||'')}</textarea></label>
<label>Notes for the vendor (optional)<textarea id="cnote" rows="2" maxlength="500"></textarea></label>
<div id="cm" class="notice" role="alert" hidden></div>
<button class="btn" id="cgo">Place order</button></form>
<aside class="ordsum"><h2>Order summary</h2>${summary}<div class="oline total"><span>Total</span><span>${xcd(total)} XCD</span></div>
${nv>1?`<p class="muted">Your cart has items from ${nv} vendors, so it becomes ${nv} separate orders, one per vendor.</p>`:''}
<p class="muted">Prices are re-checked by the server when you place the order.</p>${payNote}<p><a href="cart.html">Edit cart</a></p></aside></div>`;
const f=$('#cof'),m=$('#cm');
const sync=()=>{$('#adl').hidden=f.ful.value!=='delivery'};f.addEventListener('change',sync);sync();
const say=t=>{m.className='notice err';m.textContent=t;m.hidden=!t};
f.onsubmit=async e=>{e.preventDefault();say('');
 const ful=f.ful.value,ph=$('#cp').value.trim(),ad=$('#ca').value.trim();
 if(ph.length<7){say('Please enter a contact phone number the vendor can reach.');$('#cp').focus();return}
 if(ful==='delivery'&&ad.length<5){say('Please enter your delivery address.');$('#ca').focus();return}
 const btn=$('#cgo');btn.disabled=true;btn.textContent='Placing order…';
 const r=await sb.rpc('place_order',{p_cart:lines.map(l=>({product_id:l.p.id,quantity:l.q})),p_fulfilment:ful,p_contact_phone:ph,p_delivery_address:ful==='delivery'?ad:null,p_notes:$('#cnote').value.trim()||null,p_contact_name:$('#cn').value.trim()||null});
 if(r.error){say(r.error.message||'Could not place the order.');btn.disabled=false;btn.textContent='Place order';return}
 saveCart({});
 try{const up={};if(!prof.phone)up.phone=ph;if(!prof.full_name&&$('#cn').value.trim())up.full_name=$('#cn').value.trim();if(ful==='delivery'&&!prof.address)up.address=ad;if(Object.keys(up).length)await sb.from('profiles').update(up).eq('id',user.id)}catch(e){}
 const os=r.data||[];
 root.innerHTML=`<div class="confirm"><div class="tick" aria-hidden="true">✓</div><h2>Thank you! Your order${os.length>1?'s are':' is'} placed.</h2>
 <p>${ful==='delivery'?'Pay the vendor when your order is delivered.':'Pay the vendor when you collect your order.'} No online payment is taken.</p>
 <div class="ordnums">${os.map(o=>`<a class="ordnum" href="dashboard-consumer.html?order=${esc(o.id)}"><b>${esc(o.order_number)}</b><span>${esc(o.vendor_name)} · ${xcd(o.total_xcd)}</span></a>`).join('')}</div>
 <p>The vendor will confirm your order soon. Follow its progress in your dashboard.</p>
 <a class="btn" href="dashboard-consumer.html">View my orders</a> <a class="btn ghost" href="browse.html">Keep shopping</a></div>`;
 window.scrollTo(0,0)};
}
};
badge();
const jsonP=fetch('products.json').then(r=>r.json());
async function loadData(){
const d=await jsonP;
if(!window.CC.configured)return d;
try{
const sb=await window.CC.client();if(!sb)return d;
const [vr,pr]=await Promise.all([sb.from('vendors').select('id,name,description,location,tier').order('name'),sb.from('products').select('id,vendor_id,name,description,price_xcd,category,image_url,featured,created_at').eq('active',true).order('created_at',{ascending:false})]);
if(vr.error||pr.error)throw (vr.error||pr.error);
const cc=Object.fromEntries(d.categories.map(c=>[c.id,c.color]));
const L=window.CC.TIER_LABEL;
d.vendors=vr.data.map(v=>({id:v.id,name:v.name,tier:L[v.tier]||'Lite',location:v.location||'',about:v.description||''}));
d.products=pr.data.map(p=>({id:p.id,vendorId:p.vendor_id,category:p.category,name:p.name,price:Number(p.price_xcd),currency:'XCD',description:p.description||'',featured:!!p.featured,color:cc[p.category]||'#0e7490',imageUrl:/^https?:\/\//i.test(p.image_url||'')?p.image_url:null}));
d.live=true;
}catch(e){console.warn('Supabase unavailable, using sample data:',e&&e.message||e)}
return d}
loadData().then(d=>{DATA=d;pages[document.body.dataset.page]();document.querySelectorAll('.grid>.card,.cats>.cat').forEach(x=>x.classList.add('rv'));window.CC_REVEAL&&window.CC_REVEAL()}).catch(e=>{console.error(e);document.querySelector('main').innerHTML='<p>Could not load data.</p>'});
})();
