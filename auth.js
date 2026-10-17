// Accounts + dashboards (Supabase). Page chosen by <body data-page=...>.
(function(){
const {esc,xcd,configured,TIER_LABEL,TIER_LIMIT}=window.CC;
const $=s=>document.querySelector(s);
const CATS={food:'Food & Spices',crafts:'Crafts & Art',fashion:'Fashion & Textiles',beauty:'Beauty & Wellness',sea:'Sea & Boating',home:'Home & Garden'};
const PENDING='cconnect_pending_vendor';
const say=(el,msg,ok)=>{el.className=ok?'notice ok':'notice err';el.textContent=msg;el.hidden=!msg};
const main=()=>document.querySelector('main');
function offline(){main().innerHTML='<h1>Accounts are not switched on yet</h1><div class="notice">This preview is running in sample mode because Supabase is not configured. See README.txt (Supabase setup) to enable sign-up, login and the dashboards. <a href="browse.html">Browse the sample marketplace</a></div>'}
async function ctx(){ // {sb,user,profile}
 const sb=await window.CC.client();if(!sb)return null;
 const user=await window.CC.getUser();let profile=null;
 if(user){const r=await sb.from('profiles').select('*').eq('id',user.id).maybeSingle();profile=r.data}
 return {sb,user,profile};
}
const NX=()=>window.CC.safeNext();
const home=p=>p&&p.role==='vendor'?'dashboard-vendor.html':'dashboard-consumer.html';
async function createVendor(sb,user,v){
 return sb.from('vendors').insert({owner_id:user.id,name:v.name,description:v.description||'',location:v.location||''}).select().single();
}
const vendorFields=`<label>Business name<input id="bname" maxlength="80" required></label><label>Location (e.g. Hillsborough)<input id="bloc" maxlength="80"></label><label>About your business<textarea id="bdesc" rows="3" maxlength="500"></textarea></label><p class="muted">New businesses start on the <strong>Lite</strong> plan (up to 10 products).</p>`;

// Resize to max 1200px and re-encode (keeps PNG transparency as PNG, otherwise JPEG ~0.82).
async function shrink(file){
 const url=URL.createObjectURL(file);
 try{const im=await new Promise((ok,no)=>{const i=new Image();i.onload=()=>ok(i);i.onerror=()=>no(new Error('Could not read that image.'));i.src=url});
  const M=1200,k=Math.min(1,M/Math.max(im.naturalWidth,im.naturalHeight)),w=Math.max(1,Math.round(im.naturalWidth*k)),h=Math.max(1,Math.round(im.naturalHeight*k));
  const cv=document.createElement('canvas');cv.width=w;cv.height=h;const cx=cv.getContext('2d');
  const png=file.type==='image/png';if(!png){cx.fillStyle='#fff';cx.fillRect(0,0,w,h)}
  cx.drawImage(im,0,0,w,h);
  let type=png?'image/png':'image/jpeg',blob=await new Promise(r=>cv.toBlob(r,type,.82));
  if(png&&blob&&blob.size>1.8*1024*1024){type='image/jpeg';cx.globalCompositeOperation='destination-over';cx.fillStyle='#fff';cx.fillRect(0,0,w,h);blob=await new Promise(r=>cv.toBlob(r,type,.82))}
  if(!blob)throw new Error('Could not process that image.');
  return {blob,type,w,h}}
 finally{URL.revokeObjectURL(url)}}
const pages={
async signup(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(c.user){location.href=NX()||home(c.profile);return}
 const f=$('#f'),msg=$('#msg'),vf=$('#vfields');vf.innerHTML=vendorFields;
 const sync=()=>{const v=f.role.value==='vendor';vf.hidden=!v;$('#bname').required=v};f.addEventListener('change',sync);sync();
 f.onsubmit=async e=>{e.preventDefault();say(msg,'');const btn=f.querySelector('button');btn.disabled=true;
  const role=f.role.value,biz={name:$('#bname').value.trim(),description:$('#bdesc').value.trim(),location:$('#bloc').value.trim()};
  const {data,error}=await c.sb.auth.signUp({email:f.email.value.trim(),password:f.password.value,options:{data:{role,full_name:f.fullname.value.trim()},emailRedirectTo:location.origin+location.pathname.replace(/[^/]*$/,'')+'login.html'+(NX()?'?next='+encodeURIComponent(NX()):'')}});
  if(error){say(msg,error.message);btn.disabled=false;return}
  if(role==='vendor')localStorage.setItem(PENDING,JSON.stringify(biz));
  if(data.session){location.href=NX()||home({role})}
  else{f.hidden=true;say(msg,'Almost done! Check your email and click the confirmation link, then log in. '+(role==='vendor'?'Your business profile will be created on first login.':''),true);msg.insertAdjacentHTML('beforeend',' <a href="login.html'+(NX()?'?next='+encodeURIComponent(NX()):'')+'">Go to login</a>')}}
},
async login(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(c.user){location.href=NX()||home(c.profile);return}
 const f=$('#f'),msg=$('#msg');
 if(NX()){const sl=document.querySelector('a[href="signup.html"]');if(sl)sl.href='signup.html?next='+encodeURIComponent(NX())}
 f.onsubmit=async e=>{e.preventDefault();say(msg,'');const btn=f.querySelector('button');btn.disabled=true;
  const {error}=await c.sb.auth.signInWithPassword({email:f.email.value.trim(),password:f.password.value});
  if(error){say(msg,error.message);btn.disabled=false;return}
  const c2=await ctx();location.href=NX()||home(c2.profile)};
 $('#forgot').onclick=async e=>{e.preventDefault();const em=f.email.value.trim();if(!em){say(msg,'Type your email above first.');return}
  const {error}=await c.sb.auth.resetPasswordForEmail(em,{redirectTo:location.origin+location.pathname.replace(/[^/]*$/,'')+'account.html'});
  say(msg,error?error.message:'Password reset email sent (if that address has an account).',!error)};
},
async account(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(!c.user){location.href='login.html';return}
 const p=c.profile||{role:'consumer'};
 $('#acct').innerHTML=`<p><strong>Email:</strong> ${esc(c.user.email)}<br><strong>Account type:</strong> ${esc(p.role)}<br><a href="${home(p)}">Go to my dashboard</a></p>
 <h2>Profile</h2><form id="pf"><label>Full name<input id="fn" value="${esc(p.full_name||'')}" maxlength="80"></label><label>Phone<input id="ph" value="${esc(p.phone||'')}" maxlength="30"></label><label>Delivery address<textarea id="ad" rows="2" maxlength="300">${esc(p.address||'')}</textarea></label><button class="btn">Save profile</button></form><div id="m1" class="notice" hidden></div>
 <h2>Change password</h2><form id="pw"><label>New password (min 8 characters)<input id="np" type="password" minlength="8" autocomplete="new-password" required></label><button class="btn alt">Update password</button></form><div id="m2" class="notice" hidden></div>
 <p><button class="btn alt" id="lo">Log out</button></p>`;
 $('#pf').onsubmit=async e=>{e.preventDefault();const {error}=await c.sb.from('profiles').update({full_name:$('#fn').value.trim()||null,phone:$('#ph').value.trim()||null,address:$('#ad').value.trim()||null}).eq('id',c.user.id);say($('#m1'),error?error.message:'Saved.',!error)};
 $('#pw').onsubmit=async e=>{e.preventDefault();const {error}=await c.sb.auth.updateUser({password:$('#np').value});say($('#m2'),error?error.message:'Password updated.',!error);if(!error)$('#np').value=''};
 $('#lo').onclick=async()=>{await c.sb.auth.signOut();location.href='index.html'};
},
async consumer(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(!c.user){location.href='login.html?next=dashboard-consumer.html';return}
 const {sb,user}=c,p=c.profile||{};
 const {stPill,fdate,fnice,payText,timeline}=window.CC;
 const SEL='*,vendors(name,location,is_sample),order_items(*),order_status_history(*)';
 const oid=new URLSearchParams(location.search).get('order');
 const D=$('#dash');
 const detail=async id=>{
  const r=await sb.from('orders').select(SEL).eq('id',id).eq('consumer_id',user.id).maybeSingle();
  if(r.error||!r.data){D.innerHTML='<p><a href="dashboard-consumer.html">&larr; All orders</a></p><div class="notice err">We could not find that order.</div>';return}
  const o=r.data,items=(o.order_items||[]);
  D.innerHTML=`<p><a href="dashboard-consumer.html">&larr; All orders</a></p>
  <div class="odetail"><div class="ohead"><div><span class="kicker">Order</span><h2>${esc(o.order_number)}</h2><div class="muted">${esc(o.vendors&&o.vendors.name||'Vendor')} · placed ${esc(fdate(o.created_at))}</div></div>${stPill(o.status)}</div>
  <p class="pdfrow"><button class="btn ghost" id="opdf" type="button">Download PDF</button></p><div id="opdfm" class="notice" hidden role="status"></div>
  <h3>Progress</h3>${timeline(o)}
  <h3>Items</h3><table><tr><th>Item</th><th>Price</th><th>Qty</th><th>Total</th></tr>${items.map(i=>`<tr><td>${esc(i.product_name)}</td><td>${xcd(i.unit_price_xcd)}</td><td>${i.quantity}</td><td>${xcd(i.line_total_xcd!=null?i.line_total_xcd:i.unit_price_xcd*i.quantity)}</td></tr>`).join('')}</table>
  <p class="otot">Subtotal ${xcd(o.subtotal_xcd)}${Number(o.delivery_fee_xcd)?` · Delivery ${xcd(o.delivery_fee_xcd)}`:''} · <b>Total ${xcd(o.total_xcd)} XCD</b></p>
  <div class="info-grid"><div><b>${fnice(o)}</b><br>${esc(payText(o))} ${window.CC.payPill(o,true)}</div><div><b>Contact</b><br>${esc(o.contact_name||'')} ${esc(o.contact_phone||'')}</div>${o.fulfilment==='delivery'?`<div><b>Deliver to</b><br>${esc(o.delivery_address||'')}</div>`:`<div><b>Collect from</b><br>${esc(o.vendors&&o.vendors.name||'')}${o.vendors&&o.vendors.location?', '+esc(o.vendors.location):''}</div>`}</div>
  ${o.payment_status==='unpaid'&&!['cancelled','completed'].includes(o.status)?`<div class="paybox">${window.CC.TESTBANNER}<p>Pay <b>${window.CC.cents(Math.round(o.total_xcd*100))}</b> now from your test wallet (play money), or pay the vendor on ${o.fulfilment==='delivery'?'delivery':'pickup'}.</p><button class="btn alt" id="opay">Pay with wallet (test)</button> <a class="btn ghost" href="wallet.html">Open wallet</a><div id="opm" class="notice" hidden role="alert"></div></div>`:o.payment_status==='paid'?`<div class="paybox ok">${window.CC.TESTBANNER}<p><b>Paid</b> ${window.CC.cents(Math.round(o.total_xcd*100))} from your test wallet${o.paid_at?' on '+esc(fdate(o.paid_at)):''}. Play money, no real funds.</p></div>`:o.payment_status==='refunded'?`<div class="paybox">${window.CC.TESTBANNER}<p><b>Refunded</b> to your test wallet. Play money, no real funds.</p></div>`:''}
  <h3>Notes with ${esc(o.vendors&&o.vendors.name||'the vendor')}</h3><div class="notes-box" id="nbox"></div>
  ${o.status==='placed'?'<p><button class="btn alt" id="ocancel">Cancel this order</button><br><small class="muted">You can cancel until the vendor confirms it.</small></p>':''}<div id="om" class="notice" hidden></div></div>`;
  window.CC.notesWidget($('#nbox'),o,'consumer',{sb,user});
  $('#opdf').onclick=()=>window.CC.orderPdf?window.CC.orderPdf.order(sb,o,{role:'consumer',vendorName:o.vendors&&o.vendors.name,vendorLocation:o.vendors&&o.vendors.location,sample:!!(o.vendors&&o.vendors.is_sample)},$('#opdf'),$('#opdfm')):say($('#opdfm'),'The PDF tool did not load. Refresh the page and try again.');
  const pb=$('#opay');if(pb)pb.onclick=async()=>{pb.disabled=true;const pr=await sb.rpc('pay_order',{p_order_id:o.id,p_idempotency_key:'ord-'+o.id});
   if(pr.error){say($('#opm'),/pay_order|schema cache|does not exist/i.test(pr.error.message)?'Wallets are not switched on yet (pay.sql has not been run in Supabase).':pr.error.message);pb.disabled=false;return}
   detail(o.id)};
  const cb=$('#ocancel');if(cb)cb.onclick=async()=>{if(!confirm('Cancel order '+o.order_number+'?'))return;cb.disabled=true;
   const u=await sb.from('orders').update({status:'cancelled'}).eq('id',o.id).select('id');
   if(u.error||!(u.data&&u.data.length)){say($('#om'),u.error?u.error.message:'The vendor has already confirmed this order, so it can no longer be cancelled.');cb.disabled=false;return}
   detail(o.id)};
 };
 if(oid){await detail(oid);return}
 const r=await sb.from('orders').select('id,order_number,status,total_xcd,created_at,fulfilment,payment_status,vendors(name),order_items(product_name,quantity)').eq('consumer_id',user.id).order('created_at',{ascending:false});
 const rows=r.data||[];
 let ns=await window.CC.noteSummary(sb);
 const act=rows.filter(o=>!['completed','cancelled'].includes(o.status)).length;
 D.innerHTML=`<div class="dtabs" role="tablist"><button class="on" data-t="orders" role="tab">Orders${act?` <b class="nbadge">${act}</b>`:''}</button><button data-t="profile" role="tab">Profile</button></div>
 <section id="t-orders"><h2>Order history</h2>${r.error?'<div class="notice err">Could not load orders: '+esc(r.error.message)+'. Has orders.sql been run in Supabase?</div>':rows.length?`<div class="olist">${rows.map(o=>`<a class="ocard" data-oid="${esc(o.id)}" href="dashboard-consumer.html?order=${esc(o.id)}"><div><b>${esc(o.order_number)}</b> ${stPill(o.status)} ${window.CC.payPill(o)}<span class="nbx">${window.CC.newBadge(ns[o.id]&&ns[o.id].unread||0)}</span><div class="muted">${esc(o.vendors&&o.vendors.name||'')} · ${esc(fdate(o.created_at))} · ${fnice(o)}</div><div class="muted">${esc((o.order_items||[]).map(i=>i.quantity+' × '+i.product_name).join(', '))}</div></div><div class="price">${xcd(o.total_xcd)}</div></a>`).join('')}</div>`:'<div class="empty"><div class="empty-ic" aria-hidden="true">🧺</div><h3>No orders yet</h3><p>When you place an order it shows up here, with live progress.</p><a class="btn" href="browse.html">Browse products</a></div>'}</section>
 <section id="t-profile" hidden><h2>My profile</h2><p class="muted">${esc(user.email)} · <a href="account.html">Change password</a></p>
 <form id="pf" class="formcard"><label>Full name<input id="fn" value="${esc(p.full_name||'')}" maxlength="80"></label><label>Phone<input id="ph" value="${esc(p.phone||'')}" maxlength="30"></label><label>Delivery address<textarea id="ad" rows="2" maxlength="300">${esc(p.address||'')}</textarea></label><button class="btn">Save profile</button></form><div id="m1" class="notice" hidden></div></section>`;
 setInterval(async()=>{if(document.hidden)return;ns=await window.CC.noteSummary(sb);document.querySelectorAll('.ocard[data-oid]').forEach(a=>{const e=a.querySelector('.nbx');if(e)e.innerHTML=window.CC.newBadge(ns[a.dataset.oid]&&ns[a.dataset.oid].unread||0)})},window.CC.NOTE_POLL);
 document.querySelectorAll('.dtabs button').forEach(b=>b.onclick=()=>{document.querySelectorAll('.dtabs button').forEach(x=>x.classList.toggle('on',x===b));$('#t-orders').hidden=b.dataset.t!=='orders';$('#t-profile').hidden=b.dataset.t!=='profile'});
 $('#pf').onsubmit=async e=>{e.preventDefault();const u=await sb.from('profiles').update({full_name:$('#fn').value.trim()||null,phone:$('#ph').value.trim()||null,address:$('#ad').value.trim()||null}).eq('id',user.id);say($('#m1'),u.error?u.error.message:'Profile saved.',!u.error)};
},
async vendordash(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(!c.user){location.href='login.html';return}
 const {sb,user,profile}=c;
 if(!profile||profile.role!=='vendor'){$('#dash').innerHTML='<div class="notice">This dashboard is for vendor accounts. <a href="dashboard-consumer.html">Go to your consumer dashboard</a>. To sell, create a new vendor account with a different email.</div>';return}
 let vr=await sb.from('vendors').select('*').eq('owner_id',user.id).limit(1).maybeSingle();
 let vendor=vr.data;
 if(!vendor){let pend=null;try{pend=JSON.parse(localStorage.getItem(PENDING))}catch(e){}
  if(pend&&pend.name){const r=await createVendor(sb,user,pend);if(!r.error){vendor=r.data;localStorage.removeItem(PENDING)}}}
 if(!vendor){
  $('#dash').innerHTML=`<h2>Create your business profile</h2><form id="bf">${vendorFields}<button class="btn">Create business (Lite plan)</button></form><div id="bm" class="notice" hidden></div>`;
  $('#bf').onsubmit=async e=>{e.preventDefault();const r=await createVendor(sb,user,{name:$('#bname').value.trim(),description:$('#bdesc').value.trim(),location:$('#bloc').value.trim()});if(r.error)say($('#bm'),r.error.message);else location.reload()};return}
 let tab=location.hash==='#orders'?'orders':location.hash==='#analytics'?'analytics':'products',ofilter='',nsum={},openN=new Set(),nTimer=null;
 const stockCell=p=>{if(p.stock_qty==null)return '<span class="muted">Not tracked</span>';const th=p.low_stock_threshold==null?5:p.low_stock_threshold;return p.stock_qty===0?'<span class="stk out">Out of stock</span>':p.stock_qty<=th?'<span class="stk low">'+p.stock_qty+' left (low)</span>':'<span class="stk">'+p.stock_qty+' in stock</span>'};
 const draw=async()=>{
  const pr=await sb.from('products').select('*').eq('vendor_id',vendor.id).order('created_at',{ascending:false});
  const prods=pr.data||[],lim=TIER_LIMIT[vendor.tier],used=prods.length,full=lim!=null&&used>=lim;
  const pct=lim?Math.min(100,Math.round(used/lim*100)):0;
  const ord=await sb.from('orders').select('*,order_items(*)').eq('vendor_id',vendor.id).order('created_at',{ascending:false}).limit(200);
  nsum=await window.CC.noteSummary(sb);
  const olist=ord.data||[],newN=olist.filter(o=>o.status==='placed').length;
  $('#dash').innerHTML=`<h2>${esc(vendor.name)} <span class="badge t-${esc(TIER_LABEL[vendor.tier].replace('+',''))}">${esc(TIER_LABEL[vendor.tier])}</span></h2>
  <p class="muted">${esc(vendor.location||'')} ${vendor.description?'· '+esc(vendor.description):''}</p>
  <p class="payquick"><a class="btn alt" href="wallet.html">Business wallet (test)</a> <a class="btn ghost" href="pos.html">POS: charge a customer (test)</a></p>
  <p><strong>Products: ${used} of ${lim==null?'unlimited':lim}</strong>${lim?`<span class="meter"><span style="width:${pct}%"></span></span>`:''}${full?'<br><span class="err-text">Limit reached. Delete a product or upgrade your plan (upgrades coming soon).</span>':''}</p>
  <div class="dtabs" role="tablist"><button data-t="products" role="tab">Products</button><button data-t="orders" role="tab">Orders${newN?` <b class="nbadge" title="New orders">${newN}</b>`:''}<span id="tnb"></span></button><button data-t="analytics" role="tab">Analytics</button></div>
  <div id="tab-products"><h3 id="ftitle">Add a product</h3>
  <form id="pf"><input type="hidden" id="pid"><label>Name<input id="pn" maxlength="120" required></label><label>Description<textarea id="pd" rows="3" maxlength="1000"></textarea></label>
  <label>Price (EC$)<input id="pp" type="number" min="0" step="0.01" required></label>
  <div class="stockrow"><label>Stock quantity <small>(optional, leave blank to not track)</small><input id="ps" type="number" min="0" max="1000000" step="1" inputmode="numeric" placeholder="e.g. 24"></label><label>Low-stock alert at or below<input id="pt" type="number" min="0" max="1000000" step="1" inputmode="numeric" value="5"></label></div>
  <label>Category<select id="pc">${Object.entries(CATS).map(([k,v])=>`<option value="${k}">${esc(v)}</option>`).join('')}</select></label>
  <div class="uploader"><span class="lbl">Product image <small>(JPG, PNG or WebP, up to 2 MB)</small></span>
   <div class="up-row"><div class="up-prev" id="upprev" aria-live="polite"><span class="muted">No image</span></div>
   <div class="up-btns"><label class="btn alt up-pick" for="pfile" id="uppicklbl" tabindex="0">Choose image</label><input type="file" id="pfile" accept="image/jpeg,image/png,image/webp" class="sr"><button type="button" class="btn ghost" id="upclear" hidden>Remove image</button></div></div>
   <div id="upmsg" class="muted" role="status"></div>
   <input type="hidden" id="pi"></div>
  <label class="chk"><input type="checkbox" id="pa" checked> Active (visible to shoppers)</label>
  <button class="btn" id="psave">Add product</button> <button type="button" class="btn alt" id="pcancel" hidden>Cancel edit</button></form><div id="pm" class="notice" hidden></div>
  <h3>Your products</h3>${prods.length?`<table><tr><th>Product</th><th>Price</th><th>Stock</th><th>Status</th><th></th></tr>${prods.map(p=>`<tr><td>${p.image_url?`<img class="thumb" src="${esc(p.image_url)}" alt="">`:''}${esc(p.name)}<div class="muted">${esc(CATS[p.category]||p.category)}</div></td><td>${xcd(p.price_xcd)}</td><td>${stockCell(p)}</td><td>${p.active?'Active':'Hidden'}</td><td><button class="btn alt" data-e="${p.id}">Edit</button> <button class="btn" data-d="${p.id}">Delete</button></td></tr>`).join('')}</table>`:'<p>No products yet.</p>'}
  </div><div id="tab-orders" hidden></div><div id="tab-analytics" hidden></div>`;
  const f=$('#pf'),m=$('#pm');
  const goEdit=id=>{showTab('products');const b=document.querySelector('[data-e="'+id+'"]');if(b)b.click()};
  let anDone=false;
  const showTab=t=>{tab=t;history.replaceState(null,'',t==='orders'?'#orders':t==='analytics'?'#analytics':location.pathname+location.search);document.querySelectorAll('.dtabs button').forEach(x=>x.classList.toggle('on',x.dataset.t===t));$('#tab-products').hidden=t!=='products';$('#tab-orders').hidden=t!=='orders';$('#tab-analytics').hidden=t!=='analytics';
   if(t==='analytics'&&!anDone){anDone=true;if(window.CC.analytics)window.CC.analytics.mount($('#tab-analytics'),{sb,vendor,onEdit:goEdit});else $('#tab-analytics').innerHTML='<div class="notice err">Analytics did not load. Refresh the page.</div>'}};
  document.querySelectorAll('.dtabs button').forEach(b=>b.onclick=()=>showTab(b.dataset.t));
  const {stPill,fdate,fnice,payText,nextSteps}=window.CC;
  const drawOrders=()=>{const T=$('#tab-orders');
   const list=olist.filter(o=>!ofilter||o.status===ofilter);
   const cnt=k=>olist.filter(o=>o.status===k).length;
   T.innerHTML=`<h3>Incoming orders</h3>${ord.error?'<div class="notice err">Could not load orders: '+esc(ord.error.message)+'. Has orders.sql been run in Supabase?</div>':''}
   <div class="ofilter" role="group" aria-label="Filter by status"><button data-f="" class="${ofilter===''?'on':''}">All (${olist.length})</button>${Object.keys(window.CC.SLABEL).map(k=>`<button data-f="${k}" class="${ofilter===k?'on':''}">${esc(window.CC.SLABEL[k])} (${cnt(k)})</button>`).join('')}</div>
   <div id="omsg" class="notice" hidden role="alert"></div>
   ${olist.length?`<p class="pdfrow"><button class="btn ghost" id="vsumpdf" type="button">Export these ${list.length} order${list.length===1?'':'s'} (PDF)</button></p>`:''}
   ${list.length?list.map(o=>`<article class="vorder${o.status==='placed'?' isnew':''}" data-oid="${esc(o.id)}"><div class="ohead"><div><b>${esc(o.order_number)}</b> ${stPill(o.status)} ${window.CC.payPill(o,true)}${o.status==='placed'?' <span class="newtag">NEW</span>':''}<div class="muted">${esc(fdate(o.created_at))} · ${fnice(o)} · ${esc(payText(o))}</div></div><div class="price">${xcd(o.total_xcd)}</div></div>
    <ul class="oitems">${(o.order_items||[]).map(i=>`<li>${i.quantity} × ${esc(i.product_name)} <span class="muted">@ ${xcd(i.unit_price_xcd)}</span></li>`).join('')}</ul>
    <div class="info-grid"><div><b>Customer</b><br>${esc(o.contact_name||'(no name)')}<br><a href="tel:${esc((o.contact_phone||'').replace(/[^0-9+]/g,''))}">${esc(o.contact_phone||'')}</a></div>${o.fulfilment==='delivery'?`<div><b>Deliver to</b><br>${esc(o.delivery_address||'')}</div>`:'<div><b>Pickup</b><br>Customer will collect</div>'}</div>
    <details class="notes" data-oid="${esc(o.id)}"><summary>💬 Notes <span class="ncnt"></span><span class="nbx"></span></summary><div class="notes-box"></div></details>
    <div class="oacts"><button class="btn ghost" data-pdf="${esc(o.id)}" type="button">Download PDF</button>${o.payment_status==='paid'?`<button class="btn ghost" data-refund="${esc(o.id)}">Refund (test)</button>`:''}${nextSteps(o).map(([to,lbl])=>`<button class="btn ${to==='cancelled'?'ghost':''}" data-o="${o.id}" data-to="${to}">${esc(lbl)}</button>`).join('')||'<span class="muted">No further actions.</span>'}</div></article>`).join(''):`<div class="empty"><div class="empty-ic" aria-hidden="true">📦</div><h3>${olist.length?'No orders with this status':'No orders yet'}</h3><p>${olist.length?'Try another filter.':'New orders from shoppers will appear here.'}</p></div>`}`;
   const badges=()=>{let tot=0;T.querySelectorAll('details.notes').forEach(d=>{const x=nsum[d.dataset.oid]||{total:0,unread:0};tot+=x.unread;
     d.querySelector('.ncnt').textContent=x.total?'('+x.total+')':'';d.querySelector('.nbx').innerHTML=window.CC.newBadge(x.unread);d.closest('.vorder').classList.toggle('hasnote',x.unread>0)});
    const all=Object.values(nsum).reduce((n,x)=>n+(x.unread||0),0);const tb=$('#tnb');if(tb)tb.innerHTML=all?' <b class="nbadge note" title="Orders with unread notes">💬'+all+'</b>':''};
   badges();
   T.querySelectorAll('details.notes').forEach(d=>{const oid=d.dataset.oid,o=olist.find(x=>x.id===oid);let w=null;
    const open=()=>{openN[d.open?'add':'delete'](oid);if(d.open&&!w){w=window.CC.notesWidget(d.querySelector('.notes-box'),o,'vendor',{sb,user,onRead:id=>{if(nsum[id])nsum[id].unread=0;badges()},onSent:()=>{nsum[oid]=nsum[oid]||{total:0,unread:0};nsum[oid].total++;badges()}})}};
    d.addEventListener('toggle',open);if(openN.has(oid))d.open=true});
   T.querySelectorAll('[data-refund]').forEach(b=>b.onclick=async()=>{const o=olist.find(x=>x.id===b.dataset.refund);
    if(!confirm('Refund '+window.CC.cents(Math.round(o.total_xcd*100))+' of TEST play money for order '+o.order_number+' back to the customer wallet?'))return;
    T.querySelectorAll('button').forEach(x=>x.disabled=true);
    const rr=await sb.rpc('refund_order',{p_order_id:o.id});await draw();tab='orders';showTab('orders');
    if(rr.error)say($('#omsg'),rr.error.message)});
   T.querySelectorAll('[data-f]').forEach(b=>b.onclick=()=>{ofilter=b.dataset.f;drawOrders()});
   const pdfMsg=T.querySelector('#omsg'),noPdf=()=>say(pdfMsg,'The PDF tool did not load. Refresh the page and try again.');
   T.querySelectorAll('[data-pdf]').forEach(b=>b.onclick=()=>{const o=olist.find(x=>x.id===b.dataset.pdf);if(!o)return;if(!window.CC.orderPdf)return noPdf();window.CC.orderPdf.order(sb,o,{role:'vendor',vendorName:vendor.name,vendorLocation:vendor.location,sample:!!vendor.is_sample},b,pdfMsg)});
   const vs=T.querySelector('#vsumpdf');if(vs)vs.onclick=()=>window.CC.orderPdf?window.CC.orderPdf.summary(list,{vendorName:vendor.name,sample:!!vendor.is_sample,filterLabel:ofilter?window.CC.SLABEL[ofilter]:''},vs,pdfMsg):noPdf();
   T.querySelectorAll('[data-to]').forEach(b=>b.onclick=async()=>{const to=b.dataset.to,o=olist.find(x=>x.id===b.dataset.o);
    if(to==='cancelled'&&!confirm('Cancel order '+o.order_number+'? The customer will see it as cancelled.'))return;
    T.querySelectorAll('button').forEach(x=>x.disabled=true);
    const u=await sb.from('orders').update({status:to}).eq('id',o.id).select('id,status');
    if(u.error||!(u.data&&u.data.length)){await draw();tab='orders';showTab('orders');say($('#omsg'),u.error?u.error.message:'That change was not allowed (the customer may have cancelled).');return}
    await draw()});
  };
  drawOrders();showTab(tab);
  clearInterval(nTimer);nTimer=setInterval(async()=>{if(document.hidden||!document.getElementById('tab-orders'))return;nsum=await window.CC.noteSummary(sb);
   const T=$('#tab-orders');if(!T)return;T.querySelectorAll('details.notes').forEach(d=>{const x=nsum[d.dataset.oid]||{total:0,unread:0};if(!d.open||!x.unread){d.querySelector('.ncnt').textContent=x.total?'('+x.total+')':'';d.querySelector('.nbx').innerHTML=d.open?'':window.CC.newBadge(x.unread);d.closest('.vorder').classList.toggle('hasnote',!d.open&&x.unread>0)}});
   const all=Object.entries(nsum).reduce((n,[k,x])=>n+(x.unread||0),0);const tb=$('#tnb');if(tb)tb.innerHTML=all?' <b class="nbadge note" title="Orders with unread notes">💬'+all+'</b>':''},window.CC.NOTE_POLL);
  let pending=null,oldUrl=null; // pending: {blob,url} resized file waiting for save; oldUrl: stored url when editing
  const prev=()=>{const u=pending?pending.url:$('#pi').value;$('#upprev').innerHTML=u?`<img src="${esc(u)}" alt="Product image preview">`:'<span class="muted">No image</span>';$('#upclear').hidden=!u;$('#uppicklbl').textContent=u?'Replace image':'Choose image'};
  $('#uppicklbl').onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();$('#pfile').click()}};
  $('#pfile').onchange=async e=>{const file=e.target.files[0];e.target.value='';if(!file)return;const um=$('#upmsg');um.className='muted';
   if(!/^image\/(jpeg|png|webp)$/.test(file.type)){um.className='err-text';um.textContent='Please choose a JPG, PNG or WebP image.';return}
   if(file.size>12*1024*1024){um.className='err-text';um.textContent='That file is too large. Choose one under 12 MB.';return}
   try{const r=await shrink(file);if(r.blob.size>2*1024*1024)throw new Error('Image is still over 2 MB after compression. Try a smaller picture.');
    if(pending)URL.revokeObjectURL(pending.url);pending={blob:r.blob,url:URL.createObjectURL(r.blob),type:r.type};um.textContent='Resized to '+r.w+'x'+r.h+', '+Math.round(r.blob.size/1024)+' KB. It uploads when you save.';prev()}
   catch(err){um.className='err-text';um.textContent=err.message||'Could not read that image.'}};
  $('#upclear').onclick=()=>{if(pending){URL.revokeObjectURL(pending.url);pending=null}$('#pi').value='';$('#upmsg').textContent='Image removed. Save to apply.';prev()};
  async function uploadPending(){const ext=pending.type==='image/png'?'png':pending.type==='image/webp'?'webp':'jpg';
   const path=user.id+'/'+Date.now()+'-'+Math.random().toString(36).slice(2,8)+'.'+ext;
   const r=await sb.storage.from('product-images').upload(path,pending.blob,{contentType:pending.type,cacheControl:'31536000',upsert:false});
   if(r.error)throw r.error;return sb.storage.from('product-images').getPublicUrl(path).data.publicUrl}
  const ourPath=u=>{const mk='/product-images/';const i=(u||'').indexOf(mk);return i>0&&u.indexOf('/storage/v1/object/public')>0?decodeURIComponent(u.slice(i+mk.length).split('?')[0]):null};
  async function dropOld(u){const p=ourPath(u);if(p&&p.startsWith(user.id+'/')){try{await sb.storage.from('product-images').remove([p])}catch(e){}}}
  const reset=()=>{f.reset();if(pending)URL.revokeObjectURL(pending.url);pending=null;oldUrl=null;$('#pi').value='';$('#ps').value='';$('#pt').value='5';$('#upmsg').textContent='';prev();$('#pid').value='';$('#ftitle').textContent='Add a product';$('#psave').textContent='Add product';$('#pcancel').hidden=true;$('#pa').checked=true};
  prev();
  if(full){$('#psave').disabled=true}
  $('#pcancel').onclick=()=>{reset();$('#psave').disabled=full};
  f.onsubmit=async e=>{e.preventDefault();say(m,'');const sv=$('#psave');sv.disabled=true;
   try{let url=$('#pi').value.trim()||null;
    if(pending){say(m,'Uploading image…',true);url=await uploadPending()}
    const row={name:$('#pn').value.trim(),description:$('#pd').value.trim(),price_xcd:parseFloat($('#pp').value),category:$('#pc').value,image_url:url,active:$('#pa').checked};
    const id=$('#pid').value,sv=$('#ps').value.trim(),editing=id?prods.find(x=>x.id===id):null;
    if(sv!==''){const n=Number(sv),th=$('#pt').value.trim()===''?5:Number($('#pt').value);
     if(!Number.isInteger(n)||n<0||n>1000000)throw new Error('Stock quantity must be a whole number, 0 or more.');
     if(!Number.isInteger(th)||th<0||th>1000000)throw new Error('The low-stock alert level must be a whole number, 0 or more.');
     row.stock_qty=n;row.low_stock_threshold=th}
    else if(editing&&editing.stock_qty!=null)row.stock_qty=null;
    const r=id?await sb.from('products').update(row).eq('id',id):await sb.from('products').insert({...row,vendor_id:vendor.id});
    if(r.error){if(pending&&url)await dropOld(url);if(/stock_qty|low_stock/.test(r.error.message||''))throw new Error('Stock tracking needs supabase/analytics.sql to be run in Supabase first (see README.txt). Clear the stock fields to save without it.');throw r.error}
    if(oldUrl&&oldUrl!==url)await dropOld(oldUrl);
    await draw()}
   catch(err){say(m,(err&&err.message)||'Could not save.');sv.disabled=false}};
  document.querySelectorAll('[data-e]').forEach(b=>b.onclick=()=>{const p=prods.find(x=>x.id===b.dataset.e);$('#pid').value=p.id;$('#pn').value=p.name;$('#pd').value=p.description;$('#pp').value=p.price_xcd;$('#pc').value=p.category;$('#ps').value=p.stock_qty==null?'':p.stock_qty;$('#pt').value=p.low_stock_threshold==null?5:p.low_stock_threshold;$('#pi').value=p.image_url||'';oldUrl=p.image_url||null;if(pending){URL.revokeObjectURL(pending.url);pending=null}$('#upmsg').textContent='';prev();$('#pa').checked=p.active;$('#ftitle').textContent='Edit product';$('#psave').textContent='Save changes';$('#psave').disabled=false;$('#pcancel').hidden=false;f.scrollIntoView()});
  document.querySelectorAll('[data-d]').forEach(b=>b.onclick=async()=>{if(!confirm('Delete this product?'))return;const r=await sb.from('products').delete().eq('id',b.dataset.d);if(r.error)say(m,r.error.message);else{await dropOld(prods.find(x=>x.id===b.dataset.d).image_url);draw()}});
 };
 await draw();
}
};
const k=document.body.dataset.page;
Promise.resolve(pages[k]()).catch(e=>{console.error(e);main().insertAdjacentHTML('beforeend','<div class="notice err">Something went wrong. Please refresh.</div>')});
})();
