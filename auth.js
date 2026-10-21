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
const vendorFields=`<p class="notice">After you sign up you will fill in a short <strong>Sell on Carriacou Connect</strong> application (business details, area, contact, delivery and tax). Carriacou Connect reviews it before your shop is shown to shoppers.</p>`;

const pages={
async signup(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(c.user){location.href=NX()||home(c.profile);return}
 const f=$('#f'),msg=$('#msg'),vf=$('#vfields');vf.innerHTML=vendorFields;
 const sync=()=>{const v=f.role.value==='vendor';vf.hidden=!v};f.addEventListener('change',sync);sync();
 f.onsubmit=async e=>{e.preventDefault();say(msg,'');const btn=f.querySelector('button');btn.disabled=true;
  const role=f.role.value;
  const {data,error}=await c.sb.auth.signUp({email:f.email.value.trim(),password:f.password.value,options:{data:{role,full_name:f.fullname.value.trim()},emailRedirectTo:location.origin+location.pathname.replace(/[^/]*$/,'')+'login.html'+(role==='vendor'&&!NX()?'?next=apply.html':NX()?'?next='+encodeURIComponent(NX()):'')}});
  if(error){say(msg,error.message);btn.disabled=false;return}
  if(data.session){location.href=NX()||(role==='vendor'?'apply.html':home({role}))}
  else{f.hidden=true;say(msg,'Almost done! Check your email and click the confirmation link, then sign in. '+(role==='vendor'?'After you sign in you will fill in the Sell application.':''),true);msg.insertAdjacentHTML('beforeend',' <a href="login.html'+(NX()?'?next='+encodeURIComponent(NX()):role==='vendor'?'?next=apply.html':'')+'">Go to login</a>')}}
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
  const st=await window.CC.acctStatus(c.sb);
  if(st.suspended){say(msg,st.message+' You are signed in, so you can still browse and manage your profile.');const go=document.createElement('a');go.className='btn alt';go.id='suspgo';go.textContent='Continue';go.href=NX()||'browse.html';msg.insertAdjacentElement('afterend',go);return}
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
  <div class="obreak">${window.CC.orderLines(o).map(l=>`<div class="oline${l.kind==='total'?' total2':''}${l.kind==='info'?' info':''}"><span>${esc(l.k)}</span><span>${l.v<0?'- ':''}${xcd(Math.abs(l.v))}${l.kind==='total'?' XCD':''}</span></div>`).join('')}${o.vendor_vat_number?`<div class="muted"><small>Vendor VAT number: ${esc(o.vendor_vat_number)}</small></div>`:''}</div>
  <div class="info-grid"><div><b>${fnice(o)}</b><br>${esc(payText(o))} ${window.CC.payPill(o,true)}</div><div><b>Contact</b><br>${esc(o.contact_name||'')} ${esc(o.contact_phone||'')}</div>${o.fulfilment==='delivery'?`<div><b>Deliver to</b><br>${esc(o.delivery_address||'')}</div>`:`<div><b>Collect from</b><br>${esc(o.vendors&&o.vendors.name||'')}${o.vendors&&o.vendors.location?', '+esc(o.vendors.location):''}</div>`}</div>
  <div id="offpay"></div>
  ${o.payment_status==='unpaid'&&!(Number(o.amount_paid_xcd)>0)&&!['cancelled','completed'].includes(o.status)?`<div class="paybox">${window.CC.TESTBANNER}<p>Pay <b>${window.CC.cents(Math.round(o.total_xcd*100))}</b> now from your test wallet (play money), or pay the vendor on ${o.fulfilment==='delivery'?'delivery':'pickup'}.</p><button class="btn alt" id="opay">Pay with wallet (test)</button> <a class="btn ghost" href="wallet.html">Open wallet</a><div id="opm" class="notice" hidden role="alert"></div></div>`:o.payment_status==='paid'?`<div class="paybox ok">${window.CC.TESTBANNER}<p><b>Paid</b> ${window.CC.cents(Math.round(o.total_xcd*100))} from your test wallet${o.paid_at?' on '+esc(fdate(o.paid_at)):''}. Play money, no real funds.</p></div>`:o.payment_status==='refunded'?`<div class="paybox">${window.CC.TESTBANNER}<p><b>Refunded</b> to your test wallet. Play money, no real funds.</p></div>`:''}
  <h3>Notes with ${esc(o.vendors&&o.vendors.name||'the vendor')}</h3><div class="notes-box" id="nbox"></div>
  ${o.status==='placed'?'<p><button class="btn alt" id="ocancel">Cancel this order</button><br><small class="muted">You can cancel until the vendor confirms it.</small></p>':''}<div id="om" class="notice" hidden></div></div>`;
  window.CC.notesWidget($('#nbox'),o,'consumer',{sb,user});
  if(window.CC.offpay)window.CC.offpay.customerBox($('#offpay'),o,{sb});
  // v1.7 live: re-read this order when a notification about it arrives (or on the 30 s fallback tick); keep any unsent note text
  if(window.CC._dOff)window.CC._dOff();
  const dsig=x=>[x.status,x.payment_status,x.status_updated_at,x.paid_at,x.amount_paid_xcd].join('|'),sig0=dsig(o);
  window.CC._dOff=window.CC.live.on(async n=>{
   if(!$('#opdf')||!n)return;
   if(!((n.ref_type==='order'&&n.ref_id===o.id&&!/^note_/.test(n.kind||''))||n.kind==='poll_tick'))return;
   const q=await sb.from('orders').select('*').eq('id',o.id).maybeSingle();
   if(!q.data||dsig(q.data)===sig0||!$('#opdf'))return;
   const ta=document.querySelector('#nbox textarea'),draft=ta?ta.value:'',foc=!!ta&&document.activeElement===ta;
   await detail(o.id);
   const t2=document.querySelector('#nbox textarea');if(t2&&draft){t2.value=draft;t2.dispatchEvent(new Event('input'));if(foc)t2.focus()}
   const h=document.querySelector('.odetail .ohead');if(h)h.classList.add('flash');
  });
  $('#opdf').onclick=()=>window.CC.orderPdf?window.CC.orderPdf.order(sb,o,{role:'consumer',vendorName:o.vendors&&o.vendors.name,vendorLocation:o.vendors&&o.vendors.location,sample:!!(o.vendors&&o.vendors.is_sample)},$('#opdf'),$('#opdfm')):say($('#opdfm'),'The PDF tool did not load. Refresh the page and try again.');
  const pb=$('#opay');if(pb)pb.onclick=async()=>{pb.disabled=true;let bal=null;try{const wr=await sb.rpc('ensure_wallets');const w=!wr.error&&Array.isArray(wr.data)&&wr.data.find(x=>x.kind==='user');if(w)bal=Number(w.balance_cents)}catch(e){}
   const amt=Math.round(Number(o.total_xcd)*100),tl=window.CC.orderLines(o).find(l=>/VAT/.test(l.k));
   const okp=await window.CC.confirmPay({title:'Pay order '+o.order_number,amountCents:amt,vat:tl?tl.k+': '+window.CC.cents(Math.round(tl.v*100)):'',balanceCents:bal,
    rows:[['Order',o.order_number],['Vendor',(o.vendors&&o.vendors.name)||'Vendor'],['Paid from','Your test wallet']],confirmText:'Confirm pay',
    onConfirm:async()=>{const pr=await sb.rpc('pay_order',{p_order_id:o.id,p_idempotency_key:'ord-'+o.id});if(pr.error)return /pay_order|schema cache|does not exist/i.test(pr.error.message)?'Wallets are not switched on yet (pay.sql has not been run in Supabase).':pr.error.message;return null}});
   pb.disabled=false;if(okp)detail(o.id)};
  const cb=$('#ocancel');if(cb)cb.onclick=async()=>{if(!confirm('Cancel order '+o.order_number+'?'))return;cb.disabled=true;
   const u=await sb.from('orders').update({status:'cancelled'}).eq('id',o.id).select('id');
   if(u.error||!(u.data&&u.data.length)){say($('#om'),u.error?u.error.message:'The vendor has already confirmed this order, so it can no longer be cancelled.');cb.disabled=false;return}
   detail(o.id)};
 };
 if(oid){await detail(oid);return}
 const LSEL0='id,order_number,status,total_xcd,created_at,fulfilment,payment_status,vendors(name),order_items(product_name,quantity)';
 const LSEL=LSEL0+',payment_method,offline_status,amount_paid_xcd';let r=await sb.from('orders').select(LSEL).eq('consumer_id',user.id).order('created_at',{ascending:false});window.CC._lsel=LSEL;if(r.error){window.CC._lsel=LSEL0;r=await sb.from('orders').select(LSEL0).eq('consumer_id',user.id).order('created_at',{ascending:false})}
 let rows=r.data||[];
 let ns=await window.CC.noteSummary(sb);
 const act=rows.filter(o=>!['completed','cancelled'].includes(o.status)).length;
 const actOf=l=>l.filter(o=>!['completed','cancelled'].includes(o.status)).length;
 const card=o=>`<a class="ocard" data-oid="${esc(o.id)}" href="dashboard-consumer.html?order=${esc(o.id)}"><div><b>${esc(o.order_number)}</b> ${stPill(o.status)} ${window.CC.payPill(o)}<span class="nbx">${window.CC.newBadge(ns[o.id]&&ns[o.id].unread||0)}</span><div class="muted">${esc(o.vendors&&o.vendors.name||'')} · ${esc(fdate(o.created_at))} · ${fnice(o)}</div><div class="muted">${esc((o.order_items||[]).map(i=>i.quantity+' × '+i.product_name).join(', '))}</div></div><div class="price">${xcd(o.total_xcd)}</div></a>`;
 D.innerHTML=`<div class="dtabs" role="tablist"><button class="on" data-t="orders" role="tab">Orders${act?` <b class="nbadge">${act}</b>`:''}</button><button data-t="profile" role="tab">Profile</button></div>
 <section id="t-orders"><h2>Order history</h2>${r.error?'<div class="notice err">Could not load orders: '+esc(r.error.message)+'. Has orders.sql been run in Supabase?</div>':rows.length?`<div class="olist">${rows.map(card).join('')}</div>`:'<div class="empty"><div class="empty-ic" aria-hidden="true">🧺</div><h3>No orders yet</h3><p>When you place an order it shows up here, with live progress.</p><a class="btn" href="browse.html">Browse products</a></div>'}</section>
 <section id="t-profile" hidden><h2>My profile</h2><p class="muted">${esc(user.email)} · <a href="account.html">Change password</a></p>
 <form id="pf" class="formcard"><label>Full name<input id="fn" value="${esc(p.full_name||'')}" maxlength="80"></label><label>Phone<input id="ph" value="${esc(p.phone||'')}" maxlength="30"></label><label>Delivery address<textarea id="ad" rows="2" maxlength="300">${esc(p.address||'')}</textarea></label><button class="btn">Save profile</button></form><div id="m1" class="notice" hidden></div></section>`;
 const noteBadges=async()=>{ns=await window.CC.noteSummary(sb);document.querySelectorAll('.ocard[data-oid]').forEach(a=>{const e=a.querySelector('.nbx');if(e)e.innerHTML=window.CC.newBadge(ns[a.dataset.oid]&&ns[a.dataset.oid].unread||0)})};
 setInterval(()=>{if(!document.hidden)noteBadges()},window.CC.NOTE_POLL);
 // v1.7 live: refresh the order list when one of my orders changes (status, payment, refund) or on the 30 s fallback tick
 const lsig=l=>l.map(o=>o.id+':'+o.status+':'+o.payment_status+':'+(o.amount_paid_xcd||0)).join(',');let lastSig=lsig(rows);
 window.CC.live.on(async n=>{const T=$('#t-orders');if(!T||!n||r.error)return;
  if(n.ref_type==='order'&&/^note_/.test(n.kind||'')){await noteBadges();return}
  if(n.ref_type!=='order'&&n.kind!=='poll_tick')return;
  const r2=await sb.from('orders').select(window.CC._lsel||LSEL0).eq('consumer_id',user.id).order('created_at',{ascending:false});
  if(r2.error||lsig(r2.data||[])===lastSig)return;lastSig=lsig(r2.data||[]);rows=r2.data||[];
  const box=T.querySelector('.olist');if(box)box.innerHTML=rows.map(card).join('');
  const tb=document.querySelector('.dtabs button[data-t=orders]');if(tb){const a=actOf(rows);tb.innerHTML='Orders'+(a?` <b class="nbadge">${a}</b>`:'')}
  const c=n.ref_id&&T.querySelector('.ocard[data-oid="'+(window.CSS&&CSS.escape?CSS.escape(n.ref_id):n.ref_id)+'"]');if(c)c.classList.add('flash')});
 document.querySelectorAll('.dtabs button').forEach(b=>b.onclick=()=>{document.querySelectorAll('.dtabs button').forEach(x=>x.classList.toggle('on',x===b));$('#t-orders').hidden=b.dataset.t!=='orders';$('#t-profile').hidden=b.dataset.t!=='profile'});
 $('#pf').onsubmit=async e=>{e.preventDefault();const u=await sb.from('profiles').update({full_name:$('#fn').value.trim()||null,phone:$('#ph').value.trim()||null,address:$('#ad').value.trim()||null}).eq('id',user.id);say($('#m1'),u.error?u.error.message:'Profile saved.',!u.error)};
},
async vendordash(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(!c.user){location.href='login.html';return}
 const {sb,user,profile}=c;let legacy=false;
 // v0.9: who am I for which business? Owner, sub-admin or staff. Without staff.sql the owner lookup below still works (v0.8 behaviour).
 let acc=[];try{const r=await sb.rpc('my_vendor_access');if(!r.error&&Array.isArray(r.data))acc=r.data}catch(e){}
 const isVendorP=!!(profile&&profile.role==='vendor');
 const wantV=new URLSearchParams(location.search).get('v');
 let me=acc.find(a=>a.vendor_id===wantV)||acc.find(a=>a.is_owner)||acc[0]||null;
 if(!me&&!isVendorP){$('#dash').innerHTML='<div class="notice">This dashboard is for vendor accounts and their team. <a href="dashboard-consumer.html">Go to your consumer dashboard</a>. To sell, create a new vendor account with a different email. If you were invited to a team, <a href="accept-invite.html">enter your invite code</a>.</div>';return}
 if(me&&me.status==='suspended'){$('#dash').innerHTML='<div class="notice err">Your access to <b>'+esc(me.vendor_name)+'</b> has been paused by the business owner. Ask them to switch it back on. <a href="dashboard-consumer.html">Go to my orders</a></div>';return}
 let vendor=null;
 if(me){const vr0=await sb.from('vendors').select('*').eq('id',me.vendor_id).maybeSingle();vendor=vr0.data}
 else{const vr=await sb.from('vendors').select('*').eq('owner_id',user.id).limit(1).maybeSingle();vendor=vr.data;legacy=!!vendor;
  if(vendor)me={vendor_id:vendor.id,vendor_name:vendor.name,tier:vendor.tier,role:'admin',is_owner:true,status:'active',perms:window.CC.ROLE_PERMS.admin.filter(p=>p!=='team'&&p!=='plan')}}
 if(!vendor&&me){$('#dash').innerHTML='<div class="notice err">We could not load that business.</div>';return}
 if(vendor&&!me){try{const r=await sb.rpc('my_vendor_access');if(!r.error&&Array.isArray(r.data))me=r.data.find(a=>a.vendor_id===vendor.id)||null}catch(e){}
  if(!me){legacy=true;me={vendor_id:vendor.id,vendor_name:vendor.name,tier:vendor.tier,role:'admin',is_owner:true,status:'active',perms:window.CC.ROLE_PERMS.admin.filter(p=>p!=='team'&&p!=='plan')}}}
 if(!vendor){
  $('#dash').innerHTML='<h2>Start selling</h2><div class="notice">You do not have a business yet. Send a short application and Carriacou Connect will review it before your shop goes live.</div><p><a class="btn" href="apply.html">Sell on Carriacou Connect: apply</a></p>';return}
 if(vendor.status&&!['approved','suspended'].includes(vendor.status)){$('#dash').innerHTML=window.CC.onboarding?window.CC.onboarding.pendingHtml(vendor,vendor.owner_id===user.id):'<div class="notice">This business is waiting for approval. <a href="apply.html">Application status</a></div>';
  const offP=window.CC.live.on(n=>{if(n&&n.kind==='application_decision'&&n.vendor_id===vendor.id){offP();pages.vendordash()}});return}
 const perms=new Set(me.perms||[]),can=p=>perms.has(p),isOwner=!!me.is_owner;
 const TABS=[['products',can('products_view')],['orders',can('orders_view')],['analytics',can('analytics')],['campaigns',can('products_edit')&&!legacy],['delivery',['admin','subadmin'].includes(me.role)&&!legacy],['team',can('team')&&!legacy]].filter(x=>x[1]).map(x=>x[0]);
 let liveOff=null;
 window.addEventListener('hashchange',()=>{const h=location.hash.slice(1);const b=document.querySelector('.dtabs button[data-t="'+h+'"]');if(b&&!b.classList.contains('on'))b.click()});
 let tab=TABS.includes(location.hash.slice(1))?location.hash.slice(1):(TABS[0]||'products'),ofilter='',pfilter='',nsum={},openN=new Set(),nTimer=null,plan=null;
 const stockCell=p=>{if(p.stock_qty==null)return '<span class="muted">Not tracked</span>';const th=p.low_stock_threshold==null?5:p.low_stock_threshold;return p.stock_qty===0?'<span class="stk out">Out of stock</span>':p.stock_qty<=th?'<span class="stk low">'+p.stock_qty+' left (low)</span>':'<span class="stk">'+p.stock_qty+' in stock</span>'};
 let photosOn=null,prods=[],pTotal=0,pPage=0,pQuery='';const PAGE=50;
 const loadProducts=async()=>{
  const build=emb=>{let q=sb.from('products').select(emb?window.CC.PCOLS+',product_images(id,url,position)':window.CC.PCOLS_BASE,{count:'exact'}).eq('vendor_id',vendor.id);
   const t=pQuery.replace(/[%_\\,()*"']/g,' ').replace(/\s+/g,' ').trim();
   if(t)q=emb?q.or('name.ilike.%'+t+'%,sku.ilike.%'+t+'%'):q.ilike('name','%'+t+'%');
   return q.order('created_at',{ascending:false}).order('id',{ascending:false}).range(pPage*PAGE,pPage*PAGE+PAGE-1)};
  let r=await build(photosOn!==false);
  if(r.error&&photosOn!==false&&/product_images|relationship|sku|schema cache|column/i.test(r.error.message||'')){photosOn=false;r=await build(false)}
  else if(!r.error&&photosOn===null)photosOn=true;
  if(!r.error&&!(r.data||[]).length&&pPage>0&&r.count>0){pPage=Math.max(0,Math.ceil(r.count/PAGE)-1);r=await build(photosOn!==false)}
  prods=(r.data||[]).map(p=>{if(p.product_images)p.product_images.sort((a,b)=>a.position-b.position);return p});pTotal=r.count!=null?r.count:prods.length};
 let costMap=null; // {productId: cost} from vendor_product_costs(); null = standard_analytics.sql not run (or no permission)
 const loadCosts=async()=>{costMap=null;if(!can('products_edit'))return;try{const r=await sb.rpc('vendor_product_costs',{p_vendor:vendor.id});if(!r.error&&Array.isArray(r.data)){costMap={};r.data.forEach(x=>{costMap[x.id]=x.cost_price})}}catch(e){}};
 const draw=async()=>{
  if(!legacy){try{const pl=await sb.rpc('vendor_plan',{p_vendor:vendor.id});if(!pl.error&&pl.data)plan=pl.data}catch(e){}}
  const cq=await sb.from('products').select('id',{count:'exact',head:true}).eq('vendor_id',vendor.id);
  await loadProducts();
  await loadCosts();
  let used;const lim=plan?plan.limits.max_products:TIER_LIMIT[vendor.tier];used=cq.count!=null?cq.count:(plan&&plan.usage?plan.usage.products:prods.length);const full=lim!=null&&used>=lim;
  const tierKey=plan?plan.tier:vendor.tier,canEdit=can('products_edit');
  const usedHtml=()=>{const pct=lim?Math.min(100,Math.round(used/lim*100)):0,full=lim!=null&&used>=lim;return `<strong>Products: ${used} of ${lim==null?'unlimited':lim}</strong>${lim?`<span class="meter"><span style="width:${pct}%"></span></span>`:''}${full?`<br><span class="err-text">Limit reached. Delete a product${isOwner&&!legacy?' or <a href="tiers.html">see plans</a>':''}.</span>`:''}`};
  const pct=lim?Math.min(100,Math.round(used/lim*100)):0;
  const maxPh=Math.max(1,(plan&&plan.limits&&plan.limits.max_photos)||window.CC.photos.TIER_PHOTOS[tierKey]||1);
  const overPh=plan&&plan.usage&&plan.usage.products_over_photo_limit!=null?plan.usage.products_over_photo_limit:prods.filter(p=>(p.product_images||[]).length>maxPh).length;
  let ord=can('orders_view')?await sb.from('orders').select('*,order_items(*)').eq('vendor_id',vendor.id).order('created_at',{ascending:false}).limit(200):{data:[]};
  nsum=can('orders_view')?await window.CC.noteSummary(sb):{};
  let olist=ord.data||[],newN=olist.filter(o=>o.status==='placed').length;
  $('#dash').innerHTML=`<h2>${esc(vendor.name)} <span class="badge t-${esc(TIER_LABEL[tierKey].replace('+',''))}">${esc(TIER_LABEL[tierKey])}</span> <span class="rolebadge r-${esc(me.role)}" title="Your role in this business">${esc(window.CC.ROLE_LABEL[me.role]||me.role)}</span></h2>
  ${acc.length>1?`<p class="vswitch"><label>Business <select id="vsel">${acc.map(a=>`<option value="${esc(a.vendor_id)}"${a.vendor_id===vendor.id?' selected':''}>${esc(a.vendor_name)} (${esc(window.CC.ROLE_LABEL[a.role]||a.role)})</option>`).join('')}</select></label></p>`:''}
  ${vendor.status==='suspended'?`<div class="notice err" role="alert"><b>This business is suspended.</b> Shoppers cannot see it or place new orders. You can still see and finish your existing orders.${vendor.status_reason?' Reason: '+esc(vendor.status_reason):''} Please contact Carriacou Connect support.</div>`:''}
  <p class="muted">${esc(vendor.location||'')} ${vendor.description?'· '+esc(vendor.description):''}</p>
  <p class="payquick">${isOwner?'<a class="btn alt" href="wallet.html">Business wallet (test)</a> ':''}${can('pos')?`<a class="btn ghost" href="pos.html${acc.length>1?'?v='+encodeURIComponent(vendor.id):''}">POS: charge a customer (test)</a>`:''}${isOwner&&!legacy?' <a class="btn ghost" href="tiers.html">Plans</a>':''}</p>
  ${!isOwner?`<p class="notice roleinfo">You are signed in as <b>${esc(window.CC.ROLE_LABEL[me.role]||me.role)}</b> for ${esc(vendor.name)}. ${me.role==='staff'?'You can manage orders, take POS payments and write order notes.':'You can also manage products, issue refunds and see analytics.'}</p>`:''}
  ${can('products_view')?`<p id="usedline">${usedHtml()}</p>`:''}
  ${can('products_view')&&photosOn?`<p class="muted phline">Photos per product: up to <b>${maxPh}</b> on your ${esc(TIER_LABEL[tierKey])} plan.${overPh>0?` <span class="err-text">${overPh} product${overPh===1?' has':'s have'} more photos than this plan allows. They are kept, but you can't add more to ${overPh===1?'it':'them'} until you remove some${isOwner&&!legacy?' or <a href="tiers.html">upgrade</a>':''}.</span>`:''}</p>`:''}
  ${plan&&can('team')?`<p class="seatline muted">Team seats: <b>${plan.usage.staff} of ${plan.limits.max_staff==null?'unlimited':plan.limits.max_staff}</b> staff${plan.limits.max_subadmins===0?'':` · <b>${plan.usage.subadmins} of ${plan.limits.max_subadmins==null?'unlimited':plan.limits.max_subadmins}</b> sub-admins`} · <a href="#team" data-goteam>Manage team</a></p>`:''}
  <div id="onbox"></div>
  <div class="dtabs" role="tablist">${TABS.includes('products')?'<button data-t="products" role="tab">Products</button>':''}${TABS.includes('orders')?`<button data-t="orders" role="tab">Orders${newN?` <b class="nbadge" title="New orders">${newN}</b>`:''}<span id="tnb"></span></button>`:''}${TABS.includes('analytics')?'<button data-t="analytics" role="tab">Analytics</button>':''}${TABS.includes('campaigns')?'<button data-t="campaigns" role="tab">Campaigns</button>':''}${TABS.includes('delivery')?'<button data-t="delivery" role="tab">Delivery &amp; tax</button>':''}${TABS.includes('team')?'<button data-t="team" role="tab">Team &amp; plan</button>':''}</div>
  <div id="tab-products"><div id="pform"${canEdit?'':' hidden'}><h3 id="ftitle">Add a product</h3>
  <form id="pf"><input type="hidden" id="pid"><label>Name<input id="pn" maxlength="120" required></label><label>Description<textarea id="pd" rows="3" maxlength="1000"></textarea></label>
  <label>Price (EC$)<input id="pp" type="number" min="0" step="0.01" required></label>
  <label id="pcostl">Cost price (EC$) <small>(optional, private: only you and your sub-admins see it. Used for profit reports.)</small><input id="pcost" type="number" min="0" max="1000000" step="0.01" inputmode="decimal" placeholder="what it costs you"></label>
  <div class="stockrow"><label>Stock quantity <small>(optional, leave blank to not track)</small><input id="ps" type="number" min="0" max="1000000" step="1" inputmode="numeric" placeholder="e.g. 24"></label><label>Low-stock alert at or below<input id="pt" type="number" min="0" max="1000000" step="1" inputmode="numeric" value="5"></label></div>
  <label>Category<select id="pc">${Object.entries(CATS).map(([k,v])=>`<option value="${k}">${esc(v)}</option>`).join('')}</select></label>
  <div class="uploader" id="upl"></div>
  <label class="chk"><input type="checkbox" id="pa" checked> Active (visible to shoppers)</label>
  <button class="btn" id="psave">Add product</button> <button type="button" class="btn alt" id="pcancel" hidden>Cancel edit</button></form><div id="pm" class="notice" hidden></div></div>
  <div id="bulkwrap"${canEdit?'':' hidden'}><details id="bulkbox" class="bulkbox"><summary>Bulk upload or export products (CSV / Excel)</summary><div id="bulkmount" class="bulkmount"></div></details></div>
  <h3>${canEdit?'Your products':'Products'}</h3>
  <div class="plist-tools"><label class="sr" for="psearch">Search products</label><input id="psearch" type="search" placeholder="Search by name or SKU" value="${esc(pQuery)}" autocomplete="off"><span id="pcount" class="muted"></span></div>
  <div id="plist"></div><div id="ppager" class="ppager"></div>
  </div><div id="tab-orders" hidden></div><div id="tab-analytics" hidden></div><div id="tab-campaigns" hidden></div><div id="tab-delivery" hidden></div><div id="tab-team" hidden></div>`;
  const vs0=$('#vsel');if(vs0)vs0.onchange=()=>{location.href='dashboard-vendor.html?v='+encodeURIComponent(vs0.value)};
  const gt=document.querySelector('[data-goteam]');if(gt)gt.onclick=e=>{e.preventDefault();showTab('team')};
  const f=$('#pf'),m=$('#pm');
  let goEditRef=null;const goEdit=id=>goEditRef&&goEditRef(id);
  let anDone=false,tmDone=false,cpDone=false,dlDone=false;
  const showTab=t=>{if(!TABS.includes(t))t=TABS[0]||'products';tab=t;history.replaceState(null,'',t==='products'?location.pathname+location.search:location.search+'#'+t);document.querySelectorAll('.dtabs button').forEach(x=>x.classList.toggle('on',x.dataset.t===t));$('#tab-products').hidden=t!=='products';$('#tab-orders').hidden=t!=='orders';$('#tab-analytics').hidden=t!=='analytics';$('#tab-campaigns').hidden=t!=='campaigns';$('#tab-team').hidden=t!=='team';$('#tab-delivery').hidden=t!=='delivery';
   if(t==='delivery'&&!dlDone){dlDone=true;if(window.CC.checkoutSettings)window.CC.checkoutSettings.mount($('#tab-delivery'),{sb,vendor,me});else $('#tab-delivery').innerHTML='<div class="notice err">The delivery and tax page did not load. Refresh the page.</div>'}
   if(t==='team'&&!tmDone){tmDone=true;if(window.CC.team)window.CC.team.mount($('#tab-team'),{sb,vendor,me,plan,onPlanChange:()=>{tmDone=false;draw().then(()=>showTab('team'))}});else $('#tab-team').innerHTML='<div class="notice err">The team page did not load. Refresh the page.</div>'}
   if(t==='campaigns'&&!cpDone){cpDone=true;if(window.CC.campaigns)window.CC.campaigns.mount($('#tab-campaigns'),{sb,vendor,plan,isOwner});else $('#tab-campaigns').innerHTML='<div class="notice err">Campaigns did not load. Refresh the page.</div>'}
   if(t==='analytics'&&!anDone){anDone=true;if(window.CC.analytics)window.CC.analytics.mount($('#tab-analytics'),{sb,vendor,plan,isOwner,perms:[...perms],onEdit:goEdit,onUpgrade:()=>{if(TABS.includes('team'))showTab('team');else location.href='tiers.html'}});else $('#tab-analytics').innerHTML='<div class="notice err">Analytics did not load. Refresh the page.</div>'}};
  if(window.CC.onboarding&&vendor.status==='approved')window.CC.onboarding.mount($('#onbox'),{sb,vendor,me,isOwner,can,TABS,goTab:t=>{showTab(t);const el=document.getElementById(t==='products'?'pform':'tab-'+t);if(el)el.scrollIntoView({block:'start'})},reload:()=>draw()});
  document.querySelectorAll('.dtabs button').forEach(b=>b.onclick=()=>showTab(b.dataset.t));
  const {stPill,fdate,fnice,payText,nextSteps}=window.CC;
  const drawOrders=()=>{const T=$('#tab-orders');
   const pst=o=>window.CC.offpay?window.CC.offpay.state(o):(o.payment_status||'unpaid');
   const list=olist.filter(o=>(!ofilter||o.status===ofilter)&&(!pfilter||pst(o)===pfilter));const pc=k=>olist.filter(o=>pst(o)===k).length;
   const cnt=k=>olist.filter(o=>o.status===k).length;
   T.innerHTML=`<h3>Incoming orders</h3>${ord.error?'<div class="notice err">Could not load orders: '+esc(ord.error.message)+'. Has orders.sql been run in Supabase?</div>':''}
   <div class="ofilter" role="group" aria-label="Filter by status"><button data-f="" class="${ofilter===''?'on':''}">All (${olist.length})</button>${Object.keys(window.CC.SLABEL).map(k=>`<button data-f="${k}" class="${ofilter===k?'on':''}">${esc(window.CC.SLABEL[k])} (${cnt(k)})</button>`).join('')}</div>
   <div class="ofilter pfilter" role="group" aria-label="Filter by payment"><span class="muted">Payment:</span><button data-pf="" class="${pfilter===''?'on':''}">Any</button>${[['unpaid','Unpaid'],['partial','Partial'],['paid','Paid']].map(([k,l])=>`<button data-pf="${k}" class="pf-${k} ${pfilter===k?'on':''}">${l} (${pc(k)})</button>`).join('')}</div>
   <div id="omsg" class="notice" hidden role="alert"></div>
   ${olist.length?`<p class="pdfrow"><button class="btn ghost" id="vsumpdf" type="button">Export these ${list.length} order${list.length===1?'':'s'} (PDF)</button></p>`:''}
   ${list.length?list.map(o=>`<article class="vorder${o.status==='placed'?' isnew':''}" data-oid="${esc(o.id)}"><div class="ohead"><div><b>${esc(o.order_number)}</b> ${stPill(o.status)} ${window.CC.payPill(o,true)}${o.status==='placed'?' <span class="newtag">NEW</span>':''}<div class="muted">${esc(fdate(o.created_at))} · ${fnice(o)} · ${esc(payText(o))}</div></div><div class="price">${xcd(o.total_xcd)}</div></div>
    <ul class="oitems">${(o.order_items||[]).map(i=>`<li>${i.quantity} × ${esc(i.product_name)} <span class="muted">@ ${xcd(i.unit_price_xcd)}</span></li>`).join('')}</ul>
    ${(Number(o.delivery_fee_xcd)>0||Number(o.discount_xcd)>0||(o.tax_xcd!=null&&Number(o.tax_rate_pct)>0))?`<div class="obreak vbreak">${window.CC.orderLines(o).filter(l=>l.kind!=='total').map(l=>`<div class="oline${l.kind==='info'?' info':''}"><span>${esc(l.k)}</span><span>${l.v<0?'- ':''}${xcd(Math.abs(l.v))}</span></div>`).join('')}</div>`:''}
    <div class="info-grid"><div><b>Customer</b><br>${esc(o.contact_name||'(no name)')}<br><a href="tel:${esc((o.contact_phone||'').replace(/[^0-9+]/g,''))}">${esc(o.contact_phone||'')}</a></div>${o.fulfilment==='delivery'?`<div><b>Deliver to</b><br>${esc(o.delivery_address||'')}</div>`:'<div><b>Pickup</b><br>Customer will collect</div>'}</div>
    ${window.CC.offpay&&window.CC.offpay.isOff(o)?`<div class="offpay" data-oid="${esc(o.id)}"></div>`:''}
    <details class="notes" data-oid="${esc(o.id)}"><summary>💬 Notes <span class="ncnt"></span><span class="nbx"></span></summary><div class="notes-box"></div></details>
    <div class="oacts"><button class="btn ghost" data-pdf="${esc(o.id)}" type="button">Download PDF</button>${o.payment_status==='paid'&&can('refunds')?`<button class="btn ghost" data-refund="${esc(o.id)}">Refund (test)</button>`:''}${(can('orders_update')?nextSteps(o).filter(([to])=>!(to==='cancelled'&&o.payment_status==='paid'&&!can('refunds'))):[]).map(([to,lbl])=>`<button class="btn ${to==='cancelled'?'ghost':''}" data-o="${o.id}" data-to="${to}">${esc(lbl)}</button>`).join('')||`<span class="muted">${o.payment_status==='paid'&&!can('refunds')&&nextSteps(o).length?'Cancelling a wallet-paid order refunds it: ask the owner or a sub-admin.':'No further actions.'}</span>`}</div></article>`).join(''):`<div class="empty"><div class="empty-ic" aria-hidden="true">📦</div><h3>${olist.length?'No orders with this status':'No orders yet'}</h3><p>${olist.length?'Try another filter.':'New orders from shoppers will appear here.'}</p></div>`}`;
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
   T.querySelectorAll('[data-pf]').forEach(b=>b.onclick=()=>{pfilter=b.dataset.pf;drawOrders()});
   if(window.CC.offpay)window.CC.offpay.vendorMount(T,list,{sb,can,onChange:async()=>{await draw();tab='orders';showTab('orders')}});
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
  const noteTick=async()=>{if(!document.getElementById('tab-orders'))return;nsum=await window.CC.noteSummary(sb);
   const T=$('#tab-orders');if(!T)return;T.querySelectorAll('details.notes').forEach(d=>{const x=nsum[d.dataset.oid]||{total:0,unread:0};if(!d.open||!x.unread){d.querySelector('.ncnt').textContent=x.total?'('+x.total+')':'';d.querySelector('.nbx').innerHTML=d.open?'':window.CC.newBadge(x.unread);d.closest('.vorder').classList.toggle('hasnote',!d.open&&x.unread>0)}});
   const all=Object.entries(nsum).reduce((n,[k,x])=>n+(x.unread||0),0);const tb=$('#tnb');if(tb)tb.innerHTML=all?' <b class="nbadge note" title="Orders with unread notes">💬'+all+'</b>':''};
  clearInterval(nTimer);nTimer=setInterval(()=>{if(!document.hidden)noteTick()},window.CC.NOTE_POLL);
  // ---- v1.7 live: new orders and order changes appear without a reload (notification + targeted refetch). Unsent note text is kept.
  const cssq=x=>window.CSS&&CSS.escape?CSS.escape(x):x;
  const osig=l=>l.map(o=>o.id+':'+o.status+':'+o.payment_status+':'+(o.amount_paid_xcd||0)).join(',');let lastO=osig(olist);
  const refreshOrders=async hl=>{
   if(!can('orders_view')||!document.getElementById('tab-orders'))return;
   const r=await sb.from('orders').select('*,order_items(*)').eq('vendor_id',vendor.id).order('created_at',{ascending:false}).limit(200);
   if(r.error||osig(r.data||[])===lastO){await noteTick();return}
   lastO=osig(r.data||[]);ord=r;olist=r.data||[];newN=olist.filter(o=>o.status==='placed').length;nsum=await window.CC.noteSummary(sb);
   const T=$('#tab-orders'),drafts={};T.querySelectorAll('details.notes').forEach(d=>{const ta=d.querySelector('textarea');if(ta&&ta.value)drafts[d.dataset.oid]=ta.value});
   const sy=window.scrollY;drawOrders();window.scrollTo(0,sy);
   const ob=document.querySelector('.dtabs button[data-t=orders]');if(ob){const nb=ob.querySelector('.nbadge:not(.note)');if(nb)nb.remove();const tnb=ob.querySelector('#tnb');if(newN&&tnb)tnb.insertAdjacentHTML('beforebegin',` <b class="nbadge" title="New orders">${newN}</b>`)}
   setTimeout(()=>{Object.entries(drafts).forEach(([id,v])=>{const d=T.querySelector('details.notes[data-oid="'+cssq(id)+'"] textarea');if(d){d.value=v;d.dispatchEvent(new Event('input'))}})},60);
   if(hl){const a=T.querySelector('.vorder[data-oid="'+cssq(hl)+'"]');if(a)a.classList.add('flash')}};
  if(liveOff)liveOff();
  liveOff=window.CC.live.on(n=>{if(!n)return;
   if(n.kind==='poll_tick'){refreshOrders(null);return}
   if(n.vendor_id!==vendor.id)return;
   if(n.kind==='vendor_status'){draw();return}
   if(n.ref_type!=='order')return;
   if(/^note_/.test(n.kind||''))noteTick();else refreshOrders(n.ref_id)});
  // ---- photos (v1.0): several per product, by plan ----
  const folder=vendor.owner_id||user.id;
  const up=window.CC.photos.uploader($('#upl'),{max:maxPh,tier:tierKey,upgradeHref:isOwner&&!legacy?'tiers.html':null});
  if(!photosOn)up.setMax(1);
  const BUCKET='product-images';
  async function uploadBlob(blob,type){const ext=type==='image/png'?'png':type==='image/webp'?'webp':'jpg';
   const path=folder+'/'+Date.now()+'-'+Math.random().toString(36).slice(2,8)+'.'+ext;
   const r=await sb.storage.from(BUCKET).upload(path,blob,{contentType:type,cacheControl:'31536000',upsert:false});
   if(r.error)throw r.error;return sb.storage.from(BUCKET).getPublicUrl(path).data.publicUrl}
  const ourPath=u=>{const mk='/product-images/';const i=(u||'').indexOf(mk);return i>0&&u.indexOf('/storage/v1/object/public')>0?decodeURIComponent(u.slice(i+mk.length).split('?')[0]):null};
  async function dropOld(u){const p=ourPath(u);if(p&&(p.startsWith(folder+'/')||p.startsWith(user.id+'/'))){try{await sb.storage.from(BUCKET).remove([p])}catch(e){}}}
  const reset=()=>{f.reset();$('#ps').value='';$('#pt').value='5';up.set([]);$('#pid').value='';$('#ftitle').textContent='Add a product';$('#psave').textContent='Add product';$('#pcancel').hidden=true;$('#pa').checked=true};
  if(full){$('#psave').disabled=true}
  $('#pcancel').onclick=()=>{reset();$('#psave').disabled=full};
  f.onsubmit=async e=>{e.preventDefault();say(m,'');const sv=$('#psave');sv.disabled=true;let uploaded=[];
   try{
    const row={name:$('#pn').value.trim(),description:$('#pd').value.trim(),price_xcd:parseFloat($('#pp').value),category:$('#pc').value,active:$('#pa').checked};
    const id=$('#pid').value,svv=$('#ps').value.trim(),editing=id?editCache[id]:null;
    const cv=$('#pcost').value.trim();
    if(cv!==''){const cn=Number(cv);if(!isFinite(cn)||cn<0||cn>1000000||Math.round(cn*100)/100!==cn)throw new Error('Cost price must be a number like 8.00 (up to 2 decimals).');row.cost_price=cn}
    else if(id&&costMap&&costMap[id]!=null)row.cost_price=null;
    if(svv!==''){const n=Number(svv),th=$('#pt').value.trim()===''?5:Number($('#pt').value);
     if(!Number.isInteger(n)||n<0||n>1000000)throw new Error('Stock quantity must be a whole number, 0 or more.');
     if(!Number.isInteger(th)||th<0||th>1000000)throw new Error('The low-stock alert level must be a whole number, 0 or more.');
     row.stock_qty=n;row.low_stock_threshold=th}
    else if(editing&&editing.stock_qty!=null)row.stock_qty=null;
    let urls=up.urls();
    if(up.hasNew()){const c=await up.commit(uploadBlob,async u=>dropOld(u),t=>say(m,t,true));urls=c.urls;uploaded=c.uploaded}
    if(!photosOn)row.image_url=urls[0]||null;
    const r=id?await sb.from('products').update(row).eq('id',id):await sb.from('products').insert({...row,vendor_id:vendor.id}).select('id').maybeSingle();
    if(r.error){for(const u of uploaded)await dropOld(u);if(/cost_price/.test(r.error.message||''))throw new Error('Cost prices need supabase/standard_analytics.sql to be run in Supabase first (see README.txt). Clear the cost field to save without it.');if(/stock_qty|low_stock/.test(r.error.message||''))throw new Error('Stock tracking needs supabase/analytics.sql to be run in Supabase first (see README.txt). Clear the stock fields to save without it.');throw r.error}
    const pid=id||(r.data&&r.data.id);
    if(photosOn&&pid&&(up.dirty()||(!id&&urls.length))){
     const pr=await sb.rpc('set_product_photos',{p_product:pid,p_urls:urls});
     if(pr.error){for(const u of uploaded)await dropOld(u);await draw();say($('#pm'),'Your product was saved, but its photos were not: '+(pr.error.message||'unknown error')+'. Open it with Edit and try again.');return}}
    for(const u of up.removed())await dropOld(u);
    await draw()}
   catch(err){say(m,(err&&err.message)||'Could not save.');sv.disabled=false}};
  function startEdit(p){editCache[p.id]=p;$('#pid').value=p.id;$('#pn').value=p.name;$('#pd').value=p.description;$('#pp').value=p.price_xcd;$('#pc').value=p.category;$('#ps').value=p.stock_qty==null?'':p.stock_qty;$('#pt').value=p.low_stock_threshold==null?5:p.low_stock_threshold;$('#pcost').value=costMap&&costMap[p.id]!=null?costMap[p.id]:'';
   up.set(photosOn?(p.product_images||[]).map(i=>i.url):(p.image_url?[p.image_url]:[]));
   $('#pa').checked=p.active;$('#ftitle').textContent='Edit product';$('#psave').textContent='Save changes';$('#psave').disabled=false;$('#pcancel').hidden=false;f.scrollIntoView()}
  const editCache={};
  {const cl=$('#pcostl');if(cl&&!costMap)cl.hidden=true}
  const goEditImpl=async id=>{if(!canEdit)return;showTab('products');let p=prods.find(x=>x.id===id);
   if(!p){const r=await sb.from('products').select(photosOn?window.CC.PCOLS+',product_images(id,url,position)':window.CC.PCOLS_BASE).eq('id',id).maybeSingle();p=r.data;if(p&&p.product_images)p.product_images.sort((a,b)=>a.position-b.position)}
   if(p)startEdit(p)};
  goEditRef=goEditImpl;
  // ---- product list: server-side paging + search (works for thousands of products) ----
  const renderList=()=>{const L=$('#plist'),pages_=Math.max(1,Math.ceil(pTotal/PAGE));
   $('#pcount').textContent=pTotal?(pQuery?pTotal+' match'+(pTotal===1?'':'es'):''):'';
   L.innerHTML=prods.length?`<table><tr><th>Product</th><th>Price</th><th>Stock</th><th>Status</th><th></th></tr>${prods.map(p=>{const n=(p.product_images||[]).length;return `<tr><td>${p.image_url?`<img class="thumb" src="${esc(p.image_url)}" alt="">`:''}${esc(p.name)}${n>1?` <span class="pcnt${n>maxPh?' over':''}" title="${n} photos">📷 ${n}</span>`:''}<div class="muted">${esc(CATS[p.category]||p.category)}${p.sku?' · SKU '+esc(p.sku):''}</div></td><td>${xcd(p.price_xcd)}</td><td>${stockCell(p)}</td><td>${p.active?'Active':'Hidden'}</td><td>${canEdit?`<button class="btn alt" data-e="${p.id}">Edit</button> <button class="btn" data-d="${p.id}">Delete</button>`:'<span class="muted">View only</span>'}</td></tr>`}).join('')}</table>`:`<p>${pQuery?'No products match your search.':'No products yet.'}</p>`;
   $('#ppager').innerHTML=pTotal>PAGE?`<button class="btn ghost" id="pprev" ${pPage===0?'disabled':''}>&larr; Previous</button><span>Page ${pPage+1} of ${pages_} · showing ${pPage*PAGE+1}–${pPage*PAGE+prods.length} of ${pTotal}</span><button class="btn ghost" id="pnext" ${pPage>=pages_-1?'disabled':''}>Next &rarr;</button>`:'';
   const go=async d=>{pPage=Math.max(0,pPage+d);await loadProducts();renderList()};
   const pv=$('#pprev'),nx=$('#pnext');if(pv)pv.onclick=()=>go(-1);if(nx)nx.onclick=()=>go(1);
   document.querySelectorAll('[data-e]').forEach(b=>b.onclick=()=>startEdit(prods.find(x=>x.id===b.dataset.e)));
   document.querySelectorAll('[data-d]').forEach(b=>b.onclick=async()=>{const p=prods.find(x=>x.id===b.dataset.d);if(!confirm('Delete "'+p.name+'"?'))return;const r=await sb.from('products').delete().eq('id',p.id);if(r.error)say(m,r.error.message);else{const us=new Set((p.product_images||[]).map(i=>i.url));if(p.image_url)us.add(p.image_url);for(const u of us)await dropOld(u);draw()}})};
  renderList();
  let st=null;const ps=$('#psearch');ps.oninput=()=>{clearTimeout(st);st=setTimeout(async()=>{pQuery=ps.value;pPage=0;await loadProducts();renderList()},250)};
  // ---- bulk upload ----
  if(canEdit&&window.CC.bulk){let bm=false;const bb=$('#bulkbox');bb.addEventListener('toggle',()=>{if(bb.open&&!bm){bm=true;
    window.CC.bulk.mount($('#bulkmount'),{sb,vendor,hasCost:!!costMap,getCosts:async()=>{const r=await sb.rpc('vendor_product_costs',{p_vendor:vendor.id});return r.error?{}:Object.fromEntries((r.data||[]).map(x=>[x.id,x.cost_price]))},upgradeHref:isOwner&&!legacy?'tiers.html':null,
     getUsage:()=>({used,limit:lim==null?null:lim,tierLabel:TIER_LABEL[tierKey]}),
     onDone:async()=>{const r=await sb.from('products').select('id',{count:'exact',head:true}).eq('vendor_id',vendor.id);if(r.count!=null)used=r.count;const ul=document.getElementById('usedline');if(ul)ul.innerHTML=usedHtml();await loadProducts();renderList()}})}})}
  else if(canEdit){$('#bulkwrap').hidden=true}
 };
 await draw();
}
};
const k=document.body.dataset.page;
Promise.resolve(pages[k]()).catch(e=>{console.error(e);main().insertAdjacentHTML('beforeend','<div class="notice err">Something went wrong. Please refresh.</div>')});
})();
