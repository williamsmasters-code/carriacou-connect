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
const promos=async()=>{const pb=$('#promos');if(!pb||!DATA.live||!window.CC.configured)return;try{const sb=await window.CC.client();const r=await sb.rpc('public_featured_campaigns');if(r.error||!Array.isArray(r.data)||!r.data.length)return;
 pb.innerHTML='<div class="sec-head"><div><span class="kicker">On now</span><h2>Promotions</h2></div></div><div class="promos">'+r.data.map(c=>'<a class="promo" href="vendor.html?id='+encodeURIComponent(c.vendor_id)+'"><span class="promo-v">'+esc(c.vendor_name)+'</span><b>'+esc(c.name)+'</b>'+(c.headline?'<span>'+esc(c.headline)+'</span>':'')+'<small>Until '+esc(c.ends_on)+(c.has_discount?' · discount code at checkout':'')+'</small></a>').join('')+'</div>'}catch(e){}};
$('#cats').innerHTML=DATA.categories.map(c=>`<a class="cat" style="--c:${esc(c.color)}" href="browse.html?cat=${c.id}">${catIcon(c.id)}<span>${esc(c.name)}</span></a>`).join('');
$('#featured').innerHTML=DATA.products.filter(p=>p.featured).map(card).join('');
promos();
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
vendor(){const v=DATA.vendors.find(x=>x.id===qs.get('id'));if(!v){$('#v').innerHTML='<div class="empty"><h3>This business is not available right now</h3><p>It may not be open yet, or it may have paused its shop. <a href="browse.html">Browse the marketplace</a></p></div>';return}
document.title=v.name+' – Carriacou Connect';
const ps=DATA.products.filter(p=>p.vendorId===v.id);
$('#v').innerHTML=`<span class="kicker">Vendor</span><h1>${esc(v.name)} ${tierBadge(v.tier)}</h1><p>${esc(v.about)}<br><span class="muted">${esc(v.location)}${/,/.test(v.location||'')?'':', Carriacou'} · ${esc(v.tier)} plan · ${ps.length} of ${DATA.tiers[v.tier]??'unlimited'} product slots used</span></p><div class="grid">${ps.map(card).join('')}</div>`},
async product(){const p=DATA.products.find(x=>x.id===qs.get('id'));if(!p){$('#p').innerHTML='<p>Product not found.</p>';return}
document.title=p.name+' – Carriacou Connect';const v=vendor(p.vendorId),cat=DATA.categories.find(c=>c.id===p.category)||DATA.categories[0];
$('#p').innerHTML=`<div class="detail"><div id="gwrap"></div>
<div class="buy"><h1>${esc(p.name)}</h1><p class="price">${xcd(p.price)} XCD</p><p>${esc(p.description)}</p>
<p class="muted">Category: <a href="browse.html?cat=${cat.id}">${esc(cat.name)}</a><br>Sold by <a href="vendor.html?id=${v.id}">${esc(v.name)}</a> ${tierBadge(v.tier)}</p>
<label>Qty <input id="qty" type="number" min="1" max="99" value="1" style="width:5rem"></label> <button class="btn" id="add">Add to cart</button><p id="msg" role="status"></p></div></div>`;
// gallery: real photos (swipe / scroll-snap + thumbnails), else the three placeholder pictures
const gallery=urls=>{const real=urls.length>0,n=real?urls.length:3;
 const src=i=>real?urls[i]:svg(p,i),alt=i=>real?`${p.name}, photo ${i+1} of ${n}`:`${p.name} (placeholder image ${i+1})`;
 $('#gwrap').innerHTML=`<div class="gal"><div class="gal-track" id="gtrack" tabindex="0" role="group" aria-roledescription="carousel" aria-label="Product photos">${Array.from({length:n},(_,i)=>`<div class="gal-slide" role="group" aria-label="Photo ${i+1} of ${n}"><img class="main-img" alt="${esc(alt(i))}" src="${esc(src(i))}" data-fb="${esc(svg(p,i%3))}"${i?' loading="lazy"':''}></div>`).join('')}</div>
 ${n>1?`<button type="button" class="gal-nav prev" id="gprev" aria-label="Previous photo">‹</button><button type="button" class="gal-nav next" id="gnext" aria-label="Next photo">›</button><span class="gal-count" id="gcount" aria-live="polite">1 / ${n}</span>`:''}</div>
 ${n>1?`<div class="thumbs" role="group" aria-label="Choose photo">${Array.from({length:n},(_,i)=>`<button type="button" class="thumbbtn${i?'':' on'}" data-i="${i}" aria-label="Show photo ${i+1}"><img alt="" src="${esc(src(i))}" data-fb="${esc(svg(p,i%3))}"></button>`).join('')}</div>`:''}`;
 const tr=$('#gtrack');if(n<2)return;let cur=0;
 const mark=i=>{cur=i;document.querySelectorAll('.thumbbtn').forEach((x,j)=>x.classList.toggle('on',j===i));$('#gcount').textContent=(i+1)+' / '+n};
 const to=i=>{i=Math.max(0,Math.min(n-1,i));tr.scrollTo({left:i*tr.clientWidth,behavior:'smooth'});mark(i)};
 let raf=0;tr.addEventListener('scroll',()=>{cancelAnimationFrame(raf);raf=requestAnimationFrame(()=>{const i=Math.round(tr.scrollLeft/Math.max(1,tr.clientWidth));if(i!==cur)mark(i)})});
 document.querySelectorAll('.thumbbtn').forEach(b=>b.onclick=()=>to(+b.dataset.i));
 $('#gprev').onclick=()=>to(cur-1);$('#gnext').onclick=()=>to(cur+1);
 tr.addEventListener('keydown',e=>{if(e.key==='ArrowRight'){e.preventDefault();to(cur+1)}else if(e.key==='ArrowLeft'){e.preventDefault();to(cur-1)}})};
gallery(p.imageUrl?[p.imageUrl]:[]);
if(DATA.live){try{const sb=await window.CC.client();const r=await sb.from('product_images').select('url,position').eq('product_id',p.id).order('position',{ascending:true});
 if(!r.error&&r.data&&r.data.length){const urls=r.data.map(x=>x.url).filter(u=>/^https?:\/\//i.test(u));if(urls.length&&(urls.length!==1||urls[0]!==p.imageUrl))gallery(urls)}}catch(e){}}
$('#add').onclick=()=>{const q=Math.max(1,Math.min(99,parseInt($('#qty').value)||1));addCart(p.id,q);$('#msg').innerHTML='Added to cart. <a href="cart.html">View cart</a>'}},
cart(){const VC=['#0b7285','#7a2e8e','#e8590c','#2f9e44','#c2255c','#1c7ed6'];
const draw=()=>{const c=getCart(),ids=Object.keys(c).filter(i=>DATA.products.some(p=>p.id===i));const R=$('#cart');
if(!ids.length){R.innerHTML=`<section class="cartempty"><div class="ce-art" aria-hidden="true"><svg viewBox="0 0 120 90"><path d="M8 70q26-14 52 0t52 0" stroke="#9fe3dc" stroke-width="4" fill="none"/><path d="M30 26h66l-8 30H40z" fill="#f4b942"/><path d="M22 18h10l10 40h44" stroke="#04202c" stroke-width="5" fill="none" stroke-linecap="round" stroke-linejoin="round"/><circle cx="46" cy="66" r="5" fill="#04202c"/><circle cx="82" cy="66" r="5" fill="#04202c"/></svg></div><h2>Your cart is empty</h2><p class="muted">Spices, crafts, fresh catch and island services are waiting in the Marketplace.</p><a class="btn" href="browse.html">Browse the Marketplace</a></section>`;return}
const groups={};ids.forEach(i=>{const p=DATA.products.find(x=>x.id===i);(groups[p.vendorId]=groups[p.vendorId]||[]).push(p)});
let sum=0,count=0;const vids=Object.keys(groups);
const row=p=>{const q=c[p.id],t=p.price*q;sum+=t;count+=q;return `<li class="ci"><a class="ci-img" href="product.html?id=${p.id}" tabindex="-1" aria-hidden="true">${img(p,0,'ci-ph')}</a>
 <div class="ci-main"><a class="ci-name" href="product.html?id=${p.id}">${esc(p.name)}</a><span class="ci-unit">${xcd(p.price)} each</span></div>
 <div class="ci-qty" role="group" aria-label="Quantity of ${esc(p.name)}"><button type="button" data-dec="${p.id}" aria-label="One less"${q<=1?' disabled':''}>−</button><input type="number" min="1" max="99" value="${q}" data-id="${p.id}" aria-label="Quantity"><button type="button" data-inc="${p.id}" aria-label="One more"${q>=99?' disabled':''}>+</button></div>
 <b class="ci-tot">${xcd(t)}</b><button type="button" class="ci-rm" data-rm="${p.id}" aria-label="Remove ${esc(p.name)}" title="Remove">✕</button></li>`};
const body=vids.map((vid,k)=>{const v=vendor(vid);let vs=0;const items=groups[vid].map(p=>{const before=sum;const h=row(p);vs+=sum-before;return h}).join('');
 return `<section class="cgroup" style="--vc:${VC[k%VC.length]}"><div class="cg-head"><span class="cg-dot" aria-hidden="true">${esc((v.name||'?').slice(0,1))}</span><div><a href="vendor.html?id=${esc(vid)}">${esc(v.name)}</a><small>${groups[vid].length} item${groups[vid].length===1?'':'s'} · separate order</small></div><b>${xcd(vs)}</b></div><ul class="cilist">${items}</ul></section>`}).join('');
R.innerHTML=`<div class="cartlay"><div class="cartitems">${vids.length>1?`<p class="cg-info">Items from <b>${vids.length} businesses</b>: checkout places one order with each.</p>`:''}${body}</div>
<aside class="cartsum" aria-label="Order summary"><span class="kicker">Order summary</span><div class="cs-row"><span>Items</span><b>${count}</b></div><div class="cs-row"><span>Businesses</span><b>${vids.length}</b></div><div class="cs-row cs-sub"><span>Subtotal</span><b>${xcd(sum)} <small>XCD</small></b></div>
<p class="cs-note">🚚 Delivery fees and VAT (if the business charges them) are worked out at checkout.</p><p class="cs-note cs-test">🧪 Pay the vendor on pickup or delivery, or use your <b>TEST wallet</b> (play money only). No real payments.</p>
<button class="btn cs-go" id="co">Checkout →</button><a class="cs-more" href="browse.html">← Continue shopping in the Marketplace</a><div id="conote"></div></aside></div>`;
const set=(id,q)=>{const c=getCart();c[id]=Math.max(1,Math.min(99,q));saveCart(c);draw();const f=document.querySelector(`input[data-id="${id}"]`);if(f)f.focus()};
R.querySelectorAll('input[data-id]').forEach(e=>e.onchange=()=>set(e.dataset.id,parseInt(e.value)||1));
R.querySelectorAll('[data-inc]').forEach(b=>b.onclick=()=>set(b.dataset.inc,(getCart()[b.dataset.inc]||1)+1));
R.querySelectorAll('[data-dec]').forEach(b=>b.onclick=()=>set(b.dataset.dec,(getCart()[b.dataset.dec]||1)-1));
R.querySelectorAll('[data-rm]').forEach(b=>b.onclick=()=>{const c=getCart();delete c[b.dataset.rm];saveCart(c);draw()});
$('#co').onclick=()=>{if(DATA.live){location.href='checkout.html'}else $('#conote').innerHTML='<div class="notice"><strong>Ordering needs accounts, which are not switched on in this preview.</strong><br>In live mode you sign in, choose pickup or delivery and place your order. You pay the vendor on pickup or delivery. Online payment (Carriacou Connect Pay) is coming later.</div>'}};
draw();addEventListener('storage',e=>{if(e.key===KEY)draw()})},
async checkout(){
const root=$('#co');
const payNote='<div class="notice"><strong>No real payments.</strong> Choose to pay the vendor yourself on pickup or delivery, or try Carriacou Connect Pay with your <b>test wallet</b> (play money only).</div>';
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
let totalCents=Math.round(total*100),camp=null;
let wal=null;try{const wr=await sb.rpc('ensure_wallets');if(!wr.error&&Array.isArray(wr.data))wal=wr.data.find(x=>x.kind==='user')||null}catch(e){}
const payKey=window.CC.uuid();
let prof={};try{const r=await sb.from('profiles').select('full_name,phone,address').eq('id',user.id).maybeSingle();prof=r.data||{}}catch(e){}
// v1.5: per-vendor pickup/delivery + delivery fee + tax, all worked out by the server (checkout_quote). If tax_delivery.sql has not been run, opts stays null and the old single pickup/delivery choice is used.
let opts=null;try{const vr=await sb.rpc('vendor_checkout_options',{p_vendor_ids:Object.keys(byV)});if(!vr.error&&Array.isArray(vr.data)&&vr.data.length===Object.keys(byV).length)opts=Object.fromEntries(vr.data.map(x=>[x.vendor_id,x]))}catch(e){}
const plan={};if(opts)Object.keys(byV).forEach(v=>{plan[v]={fulfilment:opts[v].pickup_enabled?'pickup':'delivery',area:''}});
const feeText=o=>{const z=o.delivery_zones||[];let t=o.delivery_model==='zones'&&z.length?'Fee depends on your area (from '+xcd(Math.min(...z.map(a=>Number(a.fee))))+')':(Number(o.delivery_flat_fee)>0?'Delivery fee '+xcd(o.delivery_flat_fee):'No delivery fee set by the vendor');if(o.free_over_xcd!=null)t+=', free on orders of '+xcd(o.free_over_xcd)+' or more';return t};
const fulBlock=vid=>{const o=opts[vid],both=o.pickup_enabled&&o.delivery_enabled,zs=o.delivery_model==='zones'?(o.delivery_zones||[]):[];
 return `<div class="vful" data-v="${esc(vid)}"><h3>${esc(vendor(vid).name)}</h3>${both?`<label class="chk opt"><input type="radio" name="ful_${esc(vid)}" value="pickup" checked> <span><b>Pickup</b><small>Collect it yourself. Free. Pay on pickup.</small></span></label>
<label class="chk opt"><input type="radio" name="ful_${esc(vid)}" value="delivery"> <span><b>Delivery</b><small>${esc(feeText(o))}. Pay on delivery.</small></span></label>`:`<p class="muted">${o.pickup_enabled?'This vendor offers <b>pickup only</b> (free). Pay on pickup.':'This vendor offers <b>delivery only</b>. '+esc(feeText(o))+'. Pay on delivery.'}</p>`}
<label class="areal" data-area="${esc(vid)}" hidden>Delivery area *<select id="area_${esc(vid)}"><option value="">Choose your area…</option>${zs.map(z=>`<option value="${esc(z.name)}">${esc(z.name)} (${xcd(z.fee)})</option>`).join('')}</select></label></div>`};
root.innerHTML=`<div class="co-grid"><form id="cof" class="formcard" novalidate>
${opts?Object.keys(byV).map(fulBlock).join(''):`<fieldset><legend>How do you want it?</legend>
<label class="chk opt"><input type="radio" name="ful" value="pickup" checked> <span><b>Pickup</b><small>Collect from the vendor. Pay on pickup.</small></span></label>
<label class="chk opt"><input type="radio" name="ful" value="delivery"> <span><b>Delivery</b><small>The vendor brings it to you. Pay on delivery. Any delivery fee is agreed with the vendor.</small></span></label></fieldset>`}
 ${wal?`<fieldset id="payf"><legend>How do you want to pay?</legend>
<label class="chk opt"><input type="radio" name="pay" value="cash" checked> <span><b>Pay the vendor myself</b><small>Cash or as agreed, when you collect or receive your order.</small></span></label>
<label class="chk opt"><input type="radio" name="pay" value="wallet"> <span><b>Pay with wallet (test)</b><small>Test balance: <b id="wbal">${window.CC.cents(wal.balance_cents)}</b>. Order total <b id="wtot">${window.CC.cents(totalCents)}</b>.</small></span></label>
<div id="wnote" class="notice" hidden>${window.CC.TESTBANNER}<span id="wnt"></span></div></fieldset>`:''}
<div class="codebox"><label for="cpc">Promo code (optional)</label><div class="coderow"><input id="cpc" maxlength="20" autocapitalize="characters" autocomplete="off" placeholder="Enter a code"><button type="button" class="btn alt" id="cpa">Apply</button></div><div id="cpm" class="notice" role="status" hidden></div></div>
<label>Your name<input id="cn" maxlength="80" autocomplete="name" value="${esc(prof.full_name||'')}"></label>
<label>Contact phone *<input id="cp" type="tel" maxlength="30" autocomplete="tel" required value="${esc(prof.phone||'')}"></label>
<label id="adl" hidden>Delivery address *<textarea id="ca" rows="3" maxlength="300">${esc(prof.address||'')}</textarea></label>
<label>Notes for the vendor (optional)<textarea id="cnote" rows="2" maxlength="500"></textarea></label>
<div id="cm" class="notice" role="alert" hidden></div>
<button class="btn" id="cgo">Place order</button></form>
<aside class="ordsum"><h2>Order summary</h2><div id="sumbox">${summary}</div><div class="oline disc" id="discline" hidden><span id="disclbl">Promo discount</span><span id="discamt"></span></div><div class="oline total"><span>Total</span><span id="totamt">${xcd(total)} XCD</span></div>
${nv>1?`<p class="muted">Your cart has items from ${nv} vendors, so it becomes ${nv} separate orders, one per vendor.</p>`:''}
<p class="muted">${opts?'Delivery fees and tax are worked out by the server and shown above. They are re-checked when you place the order.':'Prices are re-checked by the server when you place the order.'}</p>${payNote}<p><a href="cart.html">Edit cart</a></p></aside></div>`;
const f=$('#cof'),m=$('#cm');
const susp=await window.CC.acctStatus(sb);if(susp.suspended){m.className='notice err';m.textContent=susp.message+' You cannot place orders right now.';m.hidden=false;$('#cgo').disabled=true}
const cleanErr=t=>String(t||'').replace(/^ACCOUNT_SUSPENDED:\s*/,'').replace(/^VENDOR_UNAVAILABLE:\s*/,'Sorry, one of the businesses in your cart is not taking orders right now. Remove its items and try again. ');
const payWallet=()=>!!wal&&f.pay&&f.pay.value==='wallet';
const planFrom=()=>{if(!opts)return;Object.keys(byV).forEach(v=>{const r=f.querySelector('input[name="ful_'+v+'"]:checked');plan[v].fulfilment=r?r.value:(opts[v].pickup_enabled?'pickup':'delivery');const sel=f.querySelector('#area_'+v);plan[v].area=sel?sel.value:''})};
const anyDel=()=>opts?Object.values(plan).some(p=>p.fulfilment==='delivery'):f.ful.value==='delivery';
const syncUI=()=>{planFrom();$('#adl').hidden=!anyDel();if(opts)Object.keys(byV).forEach(v=>{const a=f.querySelector('[data-area="'+v+'"]');if(a)a.hidden=!(plan[v].fulfilment==='delivery'&&opts[v].delivery_model==='zones'&&(opts[v].delivery_zones||[]).length>0)});
 if(wal){const w=$('#wnote');w.hidden=!payWallet();if(payWallet()){const short=Number(wal.balance_cents)<totalCents;$('#wnt').innerHTML=short?' Your test balance is too low for this order. <a href="wallet.html">Add play money in your wallet</a>, then come back.':' Your order is placed and paid straight away from your test wallet. No real money is used.'}$('#cgo').textContent=payWallet()?'Place order and pay with test wallet':'Place order';const wo=$('#wtot');if(wo)wo.textContent=window.CC.cents(totalCents)}};
let qseq=0;
let lastQ=null;const renderSummary=q=>{lastQ=q;totalCents=Math.round(Number(q.grand_total_xcd)*100);
 $('#sumbox').innerHTML=q.orders.map(x=>{const ls=lines.filter(l=>l.p.vendorId===x.vendor_id);
  return `<div class="osum"><h3>${esc(x.vendor_name)} <span class="ft">· ${x.fulfilment==='delivery'?'delivery':'pickup'}</span></h3>${ls.map(l=>`<div class="oline"><span>${l.q} × ${esc(l.p.name)}</span><span>${xcd(l.p.price*l.q)}</span></div>`).join('')}
  <div class="oline sub"><span>Subtotal</span><span>${xcd(x.subtotal_xcd)}</span></div>
  ${Number(x.discount_xcd)>0?`<div class="oline disc"><span>Promo ${esc(camp&&camp.code||'')}</span><span>- ${xcd(x.discount_xcd)}</span></div>`:''}
  ${x.fulfilment==='delivery'?`<div class="oline"><span>Delivery fee${x.delivery_area?' ('+esc(x.delivery_area)+')':''}</span><span>${Number(x.delivery_fee_xcd)?xcd(x.delivery_fee_xcd):'Free'}</span></div>`:''}
  ${Number(x.tax_rate_pct)>0?`<div class="oline${x.tax_inclusive?' info':''}"><span>${x.tax_inclusive?'Includes VAT':'VAT'} (${Number(x.tax_rate_pct)}%)</span><span>${xcd(x.tax_xcd)}</span></div>`:''}
  ${x.error?`<div class="qerr" role="status">${esc(x.error)}</div>`:''}
  <div class="oline vtot"><span>${q.orders.length>1?'Order total':'Total'}</span><span>${xcd(x.total_xcd)}</span></div></div>`}).join('');
 $('#totamt').textContent=xcd(q.grand_total_xcd)+' XCD';syncUI()};
const refreshQuote=async()=>{if(!opts)return;planFrom();const my=++qseq;$('#sumbox').classList.add('qwait');
 const r=await sb.rpc('checkout_quote',{p_cart:cartJson(),p_plan:plan,p_campaign_code:camp?camp.code:null});
 if(my!==qseq)return;$('#sumbox').classList.remove('qwait');
 if(r.error||!r.data){say('Could not work out the totals: '+cleanErr((r.error&&r.error.message)||'try again')+'.');return}
 if(r.data.code_error&&camp){camp=null;const pm=$('#cpm');pm.className='notice err';pm.textContent=r.data.code_error;pm.hidden=false}
 renderSummary(r.data)};
const sync=()=>{syncUI();refreshQuote()};
f.addEventListener('change',e=>{const t=e.target||{};if(opts&&((t.name||'').startsWith('ful_')||(t.id||'').startsWith('area_')))sync();else syncUI()});syncUI();
const say=t=>{m.className='notice err';m.textContent=t;m.hidden=!t};
const cartJson=()=>lines.map(l=>({product_id:l.p.id,quantity:l.q}));
const setCamp=(c,msg,bad)=>{camp=c;const pm=$('#cpm');pm.className='notice'+(bad?' err':c?' ok':'');pm.textContent=msg||'';pm.hidden=!msg;
 if(opts){refreshQuote();return}
 const disc=c?Number(c.discount_xcd)||0:0;totalCents=Math.round((total-disc)*100);
 $('#discline').hidden=!(c&&disc>0);if(c&&disc>0){$('#disclbl').textContent='Promo '+c.code+(c.discount_pct!=null?' ('+Number(c.discount_pct)+'% off '+c.vendor_name+')':'');$('#discamt').textContent='- '+xcd(disc)+' XCD'}
 $('#totamt').textContent=xcd(total-disc)+' XCD';document.querySelectorAll('.cotot').forEach(e=>{e.textContent=window.CC.cents(totalCents)});if(typeof syncUI==='function')syncUI()};
$('#cpc').oninput=()=>{if(camp)setCamp(null,'')};
$('#cpa').onclick=async()=>{const code=$('#cpc').value.trim();if(!code){setCamp(null,'Type a code first.',true);return}
 const b=$('#cpa');b.disabled=true;const r=await sb.rpc('check_campaign_code',{p_code:code,p_cart:cartJson()});b.disabled=false;
 if(r.error){setCamp(null,/Could not find the function|schema cache/.test(r.error.message||'')?'Promo codes are not switched on yet.':(r.error.message||'Could not check that code.'),true);return}
 if(!r.data||!r.data.ok){setCamp(null,(r.data&&r.data.error)||'That code is not valid.',true);return}
 const c=Object.assign({code:code.toUpperCase().replace(/\s+/g,'')},r.data);
 setCamp(c,Number(c.discount_xcd)>0?'Code '+c.code+' applied: you save '+xcd(c.discount_xcd)+' XCD on '+c.vendor_name+'.':'Code '+c.code+' accepted ('+c.name+'). No discount, it just tells the vendor which promotion you came from.')};

if(opts)refreshQuote();
f.onsubmit=async e=>{e.preventDefault();say('');planFrom();
 const ful=anyDel()?'delivery':'pickup',ph=$('#cp').value.trim(),ad=$('#ca').value.trim();
 if(opts){for(const v of Object.keys(byV)){if(plan[v].fulfilment==='delivery'&&opts[v].delivery_model==='zones'&&(opts[v].delivery_zones||[]).length&&!plan[v].area){say('Please choose a delivery area for '+vendor(v).name+'.');const sl=f.querySelector('#area_'+v);if(sl)sl.focus();return}}}
 if(ph.length<7){say('Please enter a contact phone number the vendor can reach.');$('#cp').focus();return}
 if(ful==='delivery'&&ad.length<5){say('Please enter your delivery address.');$('#ca').focus();return}
 if(payWallet()&&Number(wal.balance_cents)<totalCents){say('Your test wallet balance ('+window.CC.cents(wal.balance_cents)+') is lower than the order total ('+window.CC.cents(totalCents)+'). Add play money in your wallet first.');return}
 if(payWallet()){const qs=(lastQ&&lastQ.orders)||[];const vat=qs.reduce((t,x)=>t+(Number(x.tax_rate_pct)>0?Math.round(Number(x.tax_xcd)*100):0),0);
  const go=await window.CC.confirmPay({title:'Place order and pay',amountCents:totalCents,balanceCents:Number(wal.balance_cents),
   vat:vat>0?(qs.every(x=>x.tax_inclusive||!(Number(x.tax_rate_pct)>0))?'Includes VAT: ':'VAT: ')+window.CC.cents(vat):'',
   rows:[['Vendor'+(qs.length>1?'s':''),qs.length?qs.map(x=>x.vendor_name).join(', '):Object.keys(byV).map(id=>(DATA.vendors.find(v=>v.id===id)||{name:'Vendor'}).name).join(', ')],['Order number','Given when the order is placed'],['Paid from','Your test wallet']],confirmText:'Confirm pay'});
  if(!go)return}
 const btn=$('#cgo');btn.disabled=true;btn.textContent='Placing order…';
 const oargs={p_cart:cartJson(),p_fulfilment:ful,p_contact_phone:ph,p_delivery_address:ful==='delivery'?ad:null,p_notes:$('#cnote').value.trim()||null,p_contact_name:$('#cn').value.trim()||null};
 const typed=$('#cpc').value.trim();
 const r=opts?await sb.rpc('place_order_plan',{p_cart:oargs.p_cart,p_plan:plan,p_contact_phone:ph,p_delivery_address:ful==='delivery'?ad:null,p_notes:oargs.p_notes,p_contact_name:oargs.p_contact_name,p_campaign_code:typed||null}):typed?await sb.rpc('place_order_with_code',{...oargs,p_campaign_code:typed}):await sb.rpc('place_order',oargs);
 if(r.error){say(typed&&/Could not find the function|schema cache/.test(r.error.message||'')?'Promo codes are not switched on yet. Clear the code to place the order.':cleanErr(r.error.message||'Could not place the order.'));btn.disabled=false;if(/ACCOUNT_SUSPENDED/.test(r.error.message||''))btn.disabled=true;else sync();return}
 if(r.data&&!Array.isArray(r.data)&&r.data.error){say(r.data.error+' Fix or clear the promo code and try again.');btn.disabled=false;sync();return}
 saveCart({});
 try{const up={};if(!prof.phone)up.phone=ph;if(!prof.full_name&&$('#cn').value.trim())up.full_name=$('#cn').value.trim();if(ful==='delivery'&&!prof.address)up.address=ad;if(Object.keys(up).length)await sb.from('profiles').update(up).eq('id',user.id)}catch(e){}
 const os=r.data||[];
 let paidMsg='',payErr='';
 const fl=opts?os.map(o=>o.fulfilment):[ful];const payWhen=fl.every(x=>x==='delivery')?'delivery':fl.every(x=>x==='pickup')?'pickup':'pickup or delivery';
 if(payWallet()){const pr=await sb.rpc('pay_orders',{p_order_ids:os.map(o=>o.id),p_idempotency_key:payKey});if(pr.error)payErr=cleanErr(pr.error.message)||'The payment did not go through.';else paidMsg='Paid from your test wallet.'}
 root.innerHTML=`<div class="confirm"><div class="tick" aria-hidden="true">✓</div><h2>Thank you! Your order${os.length>1?'s are':' is'} placed.</h2>
 ${paidMsg?window.CC.TESTBANNER+'<p><b>'+paidMsg+'</b> This was play money, so no real funds moved.</p>':payErr?'<div class="notice err">Your order was placed but the test payment failed: '+esc(payErr)+'. You can pay it from your order page, or pay the vendor on '+payWhen+'.</div>':'<p>'+(payWhen==='delivery'?'Pay the vendor when your order is delivered.':payWhen==='pickup'?'Pay the vendor when you collect your order.':'Pay each vendor when you collect or receive your order.')+' No online payment is taken.</p>'}
 <div class="ordnums">${os.map(o=>`<a class="ordnum" href="dashboard-consumer.html?order=${esc(o.id)}"><b>${esc(o.order_number)}</b><span>${esc(o.vendor_name)} · ${xcd(o.total_xcd)}${Number(o.delivery_fee_xcd)>0?' · incl. delivery '+xcd(o.delivery_fee_xcd):''}${o.tax_xcd!=null&&Number(o.tax_xcd)>0?' · VAT '+xcd(o.tax_xcd):''}</span></a>`).join('')}</div>
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
const page=async from=>sb.from('products').select('id,vendor_id,name,description,price_xcd,category,image_url,featured,created_at').eq('active',true).order('created_at',{ascending:false}).order('id',{ascending:true}).range(from,from+999);
const vr=await sb.from('vendors').select('id,name,description,location,tier').order('name');let pr=await page(0);
if(vr.error||pr.error)throw (vr.error||pr.error);
// Supabase returns at most 1000 rows per request: read further pages (up to 10,000 products)
for(let from=1000;pr.data.length===from&&from<10000;from+=1000){const nx=await page(from);if(nx.error)break;pr={data:pr.data.concat(nx.data)}}
const cc=Object.fromEntries(d.categories.map(c=>[c.id,c.color]));
const L=window.CC.TIER_LABEL;
d.vendors=vr.data.map(v=>({id:v.id,name:v.name,tier:L[v.tier]||'Lite',location:v.location||'',about:v.description||''}));
d.products=pr.data.map(p=>({id:p.id,vendorId:p.vendor_id,category:p.category,name:p.name,price:Number(p.price_xcd),currency:'XCD',description:p.description||'',featured:!!p.featured,color:cc[p.category]||'#0e7490',imageUrl:/^https?:\/\//i.test(p.image_url||'')?p.image_url:null}));
d.live=true;
}catch(e){console.warn('Supabase unavailable, using sample data:',e&&e.message||e)}
return d}
loadData().then(d=>{DATA=d;pages[document.body.dataset.page]();document.querySelectorAll('.grid>.card,.cats>.cat').forEach(x=>x.classList.add('rv'));window.CC_REVEAL&&window.CC_REVEAL()}).catch(e=>{console.error(e);document.querySelector('main').innerHTML='<p>Could not load data.</p>'});
})();
