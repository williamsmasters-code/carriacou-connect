// Shared: config, Supabase client (lazy, CDN), nav/layout. Loaded on every page before app.js / auth.js.
(function(){
const cfg=window.CCONNECT_CONFIG||{};
const configured=/^https:\/\/[a-z0-9-]+\.supabase\.(co|in)\/?$/i.test(cfg.SUPABASE_URL||'')&&!/YOUR-/i.test(cfg.SUPABASE_URL||'')&&(cfg.SUPABASE_ANON_KEY||'').length>20&&!/YOUR-/i.test(cfg.SUPABASE_ANON_KEY||'');
const CDN='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js';
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let clientP=null;
// ---- v1.7 live updates: tiny event bus. realtime.js emits notification rows here; pages subscribe with CC.live.on(fn) (returns an unsubscribe function).
const liveFns=new Set();
const live={state:'idle',on(fn){liveFns.add(fn);return ()=>liveFns.delete(fn)},emit(n){[...liveFns].forEach(f=>{try{f(n)}catch(e){console.warn('live handler failed',e)}})}};
// Resolves to a Supabase client, or null when not configured / library failed to load.
function client(){
 if(!configured)return Promise.resolve(null);
 if(clientP)return clientP;
 clientP=new Promise(res=>{
  const make=()=>{try{res(window.supabase.createClient(cfg.SUPABASE_URL,cfg.SUPABASE_ANON_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}))}catch(e){console.warn('Supabase init failed',e);res(null)}};
  if(window.supabase)return make();
  const s=document.createElement('script');s.src=CDN;s.onload=make;s.onerror=()=>{console.warn('Could not load supabase-js; using sample mode');res(null)};document.head.appendChild(s);
 });
 return clientP;
}
const TIER_LABEL={lite:'Lite',standard:'Standard',plus:'Plus+',pro:'Pro',enterprise:'Enterprise'};
const TIER_LIMIT={lite:10,standard:25,plus:50,pro:null,enterprise:null};
// ---- plans (v0.9, TEST MODE: no billing). The database (tier_limits table) is the source of truth for limits; this is the display copy. null = unlimited.
const TIERS=[
 {k:'lite',photos:1,name:'Lite',tag:'Start small',staff:0,sub:0,products:10,pos:'Basic',bizAnalytics:false,multi:false,support:false,blurb:'For one person running a small shop or side business.'},
 {k:'standard',photos:1,name:'Standard',tag:'Add a helper',staff:2,sub:0,products:25,pos:'Basic',bizAnalytics:false,multi:false,support:false,blurb:'Owner plus two staff accounts for a growing shop.'},
 {k:'plus',photos:3,name:'Plus+',tag:'Busy counter',staff:5,sub:0,products:50,pos:'Enhanced',bizAnalytics:false,multi:false,support:false,blurb:'Owner plus five staff, with the enhanced point of sale.'},
 {k:'pro',photos:3,name:'Pro',tag:'Run a team',staff:5,sub:2,products:null,pos:'Professional',bizAnalytics:true,multi:false,support:false,blurb:'Two sub-admins, five staff, unlimited products and business analytics.'},
 {k:'enterprise',photos:5,name:'Enterprise',tag:'Island scale',staff:null,sub:null,products:null,pos:'Professional',bizAnalytics:true,multi:true,support:true,blurb:'Variable team size, multiple locations and dedicated support.'}];
const lim=n=>n==null?'Unlimited':String(n);
const ROLE_LABEL={admin:'Owner',subadmin:'Sub-admin',staff:'Staff'};
// what each business role may do (mirrors role_perms() in staff.sql; the database is the real gatekeeper)
const ROLE_PERMS={staff:['orders_view','orders_update','notes','pos','products_view'],subadmin:['orders_view','orders_update','notes','pos','products_view','products_edit','refunds','analytics'],admin:['orders_view','orders_update','notes','pos','products_view','products_edit','refunds','analytics','team','plan','vendor_edit']};
async function getUser(){const sb=await client();if(!sb)return null;try{const {data}=await sb.auth.getSession();return data.session?data.session.user:null}catch(e){return null}}

// ---- orders helpers (v0.4) ----
const SLABEL={placed:'Placed',confirmed:'Confirmed',ready:'Ready',out_for_delivery:'Out for delivery',completed:'Completed',cancelled:'Cancelled'};
const stPill=s=>'<span class="st st-'+esc(s)+'">'+esc(SLABEL[s]||s)+'</span>';
const fdate=d=>{try{return new Date(d).toLocaleString([], {dateStyle:'medium',timeStyle:'short'})}catch(e){return String(d)}};
const fnice=(o)=>o.fulfilment==='delivery'?'Delivery':'Pickup';
const payText=o=>o.payment_method==='pay_with_wallet'?'Pay with wallet (TEST, play money)':o.payment_method==='pay_on_delivery'?'Pay on delivery':'Pay on pickup';
// ---- Connect Pay (v0.6, TEST MODE: play money only) ----
const TESTBANNER='<div class="testbanner" role="note"><b>TEST MODE</b> - play money, not real funds</div>';
const cents=n=>{n=Number(n)||0;const neg=n<0;n=Math.abs(Math.round(n));return (neg?'-':'')+'EC$'+Math.floor(n/100).toLocaleString('en-US')+'.'+String(n%100).padStart(2,'0')};
const toCents=v=>{const m=String(v==null?'':v).trim().replace(/^EC?\$/i,'').replace(/,/g,'').match(/^(\d{1,7})(?:\.(\d{1,2}))?$/);return m?parseInt(m[1],10)*100+parseInt((m[2]||'0').padEnd(2,'0'),10):null};
const uuid=()=>(window.crypto&&crypto.randomUUID)?crypto.randomUUID():'k'+Date.now().toString(36)+Math.random().toString(36).slice(2,12);
const payPill=(o,always)=>!o.payment_status?'':o.payment_status==='paid'?'<span class="pp pp-paid">Paid (test)</span>':o.payment_status==='refunded'?'<span class="pp pp-ref">Refunded (test)</span>':always?'<span class="pp pp-unpaid">Unpaid</span>':'';
// where may a vendor move an order next? (mirrors the database trigger; the database is the real gatekeeper)
function nextSteps(o){
 const d=o.fulfilment==='delivery';
 return ({placed:[['confirmed','Accept order'],['cancelled','Decline']],confirmed:[['ready',d?'Ready for delivery':'Ready for pickup'],['cancelled','Cancel']],
  ready:[[d?'out_for_delivery':'completed',d?'Out for delivery':'Mark collected'],['cancelled','Cancel']],out_for_delivery:[['completed','Mark delivered'],['cancelled','Cancel']]})[o.status]||[];
}
function timeline(o){
 const hist=(o.order_status_history||[]).slice().sort((a,b)=>new Date(a.changed_at)-new Date(b.changed_at));
 const at={};hist.forEach(h=>{at[h.to_status]=h.changed_at});
 if(!at.placed)at.placed=o.created_at;
 const d=o.fulfilment==='delivery';
 const steps=d?['placed','confirmed','ready','out_for_delivery','completed']:['placed','confirmed','ready','completed'];
 const lab={placed:'Order placed',confirmed:'Confirmed by vendor',ready:d?'Packed and ready':'Ready for pickup',out_for_delivery:'Out for delivery',completed:d?'Delivered':'Collected'};
 const cancelled=o.status==='cancelled';
 const cur=steps.indexOf(o.status);
 let h='<ol class="tl" aria-label="Order progress">';
 steps.forEach((k,i)=>{const done=!!at[k]&&(cancelled||i<=cur);const now=!cancelled&&i===cur;
  h+='<li class="'+(done?'done':'')+(now?' now':'')+'"><b>'+esc(lab[k])+'</b><small>'+(done?esc(fdate(at[k])):'Waiting')+'</small></li>'});
 if(cancelled)h+='<li class="done cancel"><b>Cancelled</b><small>'+esc(fdate(at.cancelled||o.status_updated_at||o.created_at))+'</small></li>';
 return h+'</ol>';
}

// ---- order notes (v0.5): two-way thread between customer and vendor ----
const NOTE_MAX=1000,NOTE_POLL=20000;
async function noteSummary(sb){const m={};try{const r=await sb.rpc('order_note_summary');((r&&r.data)||[]).forEach(x=>{m[x.oid]=x})}catch(e){}return m}
const newBadge=n=>n>0?'<span class="newnote" title="'+esc(n)+' unread">'+(n>1?esc(n)+' new notes':'New note')+'</span>':'';
// role = 'consumer' | 'vendor' (which side the logged-in person is on). All text is escaped with esc().
function notesWidget(box,o,role,opts){
 opts=opts||{};const sb=opts.sb,user=opts.user,other=role==='vendor'?'consumer':'vendor';
 const RL={vendor:'Vendor',consumer:'Customer'};
 box.innerHTML='<div class="nthread" role="log" aria-live="polite" aria-label="Order notes"><p class="muted">Loading notes…</p></div>'+
  '<form class="nform" autocomplete="off"><label class="sr" for="nt-'+esc(o.id)+'">Write a note</label><textarea id="nt-'+esc(o.id)+'" rows="2" maxlength="'+NOTE_MAX+'" placeholder="'+(role==='vendor'?'Write a note to the customer…':'Write a note to the vendor…')+'"></textarea>'+
  '<div class="nrow"><small class="ncount muted">0 / '+NOTE_MAX+'</small><button class="btn" type="submit" disabled>Send note</button></div><div class="notice err" hidden role="alert"></div></form>';
 const th=box.querySelector('.nthread'),f=box.querySelector('form'),ta=f.querySelector('textarea'),btn=f.querySelector('button'),cnt=f.querySelector('.ncount'),er=f.querySelector('.notice');
 let notes=[],sig='',marked=0,busy=false,timer=null;
 const sync=()=>{const n=ta.value.length;cnt.textContent=n+' / '+NOTE_MAX;cnt.className='ncount '+(n>NOTE_MAX-100?'err-text':'muted');btn.disabled=busy||!ta.value.trim()};
 ta.addEventListener('input',sync);
 ta.addEventListener('keydown',e=>{if(e.key==='Enter'&&(e.ctrlKey||e.metaKey)){e.preventDefault();f.requestSubmit()}});
 const msg=(m)=>{const mine=m.author_role===role;const who=mine?'You':(m.author_name||RL[m.author_role]);
  return '<div class="nmsg '+(mine?'mine':'theirs')+(m.first?' first':'')+'"><div class="nmeta"><b>'+esc(who)+'</b> <span class="nrole r-'+esc(m.author_role)+'">'+esc(RL[m.author_role])+'</span> · '+esc(fdate(m.created_at))+(m.first?' · <i>with the order</i>':'')+'</div><div class="nbody">'+esc(m.body)+'</div></div>'};
 const draw=(stick)=>{const all=(o.notes?[{first:1,author_role:'consumer',author_name:o.contact_name||'',body:o.notes,created_at:o.created_at}]:[]).concat(notes);
  const atEnd=th.scrollHeight-th.scrollTop-th.clientHeight<40;
  th.innerHTML=all.length?all.map(msg).join(''):'<p class="muted nempty">No notes yet. Use this space for questions or updates about this order.</p>';
  if(stick||atEnd)th.scrollTop=th.scrollHeight};
 const fail=e=>{const m=(e&&e.message)||'Could not load notes.';
  return /order_notes|schema cache|does not exist|order_note_summary/i.test(m)?'Notes are not switched on yet (order_notes.sql has not been run in Supabase).':m};
 async function load(){
  if(!box.isConnected){clearInterval(timer);return}
  const r=await sb.from('order_notes').select('*').eq('order_id',o.id).order('created_at',{ascending:true});
  if(r.error){th.innerHTML='<div class="notice err">'+esc(fail(r.error))+'</div>';f.hidden=true;clearInterval(timer);return}
  notes=r.data||[];const s=notes.length+':'+(notes.length?notes[notes.length-1].id:'');
  if(s!==sig){const first=!sig;sig=s;draw(first)}
  const lastOther=notes.filter(n=>n.author_role===other).map(n=>new Date(n.created_at).getTime()).reduce((a,b)=>Math.max(a,b),0);
  if(lastOther>marked&&!document.hidden){marked=lastOther;try{await sb.rpc('mark_order_notes_read',{p_order_id:o.id});if(opts.onRead)opts.onRead(o.id)}catch(e){}}
 }
 f.onsubmit=async e=>{e.preventDefault();const body=ta.value.trim();if(!body||busy)return;
  busy=true;sync();er.hidden=true;
  const r=await sb.from('order_notes').insert({order_id:o.id,author_id:user.id,author_role:role,body}).select();
  busy=false;
  if(r.error){er.textContent=fail(r.error);er.hidden=false;sync();return}
  ta.value='';sync();sig='';await load();th.scrollTop=th.scrollHeight;if(opts.onSent)opts.onSent(o.id)};
  const offLive=live.on(n=>{if(!box.isConnected){offLive();return}if(n&&n.ref_id===o.id&&/^note_/.test(n.kind||''))load()});
 load();
 timer=setInterval(()=>{if(!box.isConnected)return clearInterval(timer);if(!document.hidden)load()},NOTE_POLL);
 return {reload:load,stop:()=>{clearInterval(timer);offLive()}};
}
// only allow same-site relative page names as a post-login destination
function safeNext(){const n=new URLSearchParams(location.search).get('next')||'';return /^[a-z0-9-]+\.html(\?[a-z0-9_=&.-]*)?$/i.test(n)?n:''}
const LOGO='<svg viewBox="0 0 48 48" aria-hidden="true"><defs><linearGradient id="lg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f4b942"/><stop offset="1" stop-color="#ff6b4a"/></linearGradient></defs><circle cx="24" cy="24" r="23" fill="#0b7285"/><circle cx="33" cy="15" r="6" fill="url(#lg)"/><path d="M24 9 L36 31 H24Z M22 13 L11 31 H22Z" fill="#fff"/><path d="M8 34h32l-4 6H12z" fill="#f4b942"/><path d="M4 41q5-3 10 0t10 0 10 0 10 0" stroke="#9fe3dc" stroke-width="2" fill="none"/></svg>';
const WAVE=(fill,flip)=>'<svg class="wave-sep" viewBox="0 0 1440 90" preserveAspectRatio="none" aria-hidden="true" style="height:clamp(34px,6vw,80px)'+(flip?';transform:scaleY(-1)':'')+'"><path fill="'+fill+'" d="M0 50 C180 100 320 0 540 40 S900 100 1100 40 1340 10 1440 50 V90 H0Z"/></svg>';
function authLinks(){return '<a href="login.html">Sign in</a><a class="pill" href="signup.html">Sign up</a>'}
// v1.7.1: every page's header shows the same cart count (cart lives in localStorage key cconnect_cart_v1, same for guests and logged-in users)
function cartBadge(){let n=0;try{const c=JSON.parse(localStorage.getItem('cconnect_cart_v1'))||{};n=Object.values(c).reduce((a,b)=>a+(Number(b)||0),0)}catch(e){}const el=document.getElementById('cartCount');if(el){el.textContent=n;el.setAttribute('aria-label',n+' item'+(n===1?'':'s')+' in cart')}}
// v1.8: role identity. body.role-* drives accent colours; header chip names the role; dashboards get a role hero.
const ROLEUI={guest:{t:'Guest',i:'👋'},customer:{t:'Customer',i:'🛍️'},vendor:{t:'Vendor',i:'🏪'},staff:{t:'Vendor team',i:'🧑‍🍳'},admin:{t:'Admin',i:'🛡️'}};
const HERO={consumer:{k:'Customer space',t:'My dashboard',s:'Your orders, receipts and wallet in one place.',i:'🛍️'},vendordash:{k:'Vendor studio',t:'Vendor dashboard',s:'Run your shop: products, orders, analytics and team.',i:'🏪'},admin:{k:'Platform control',t:'Platform admin',s:'Plans, vendors, customers and platform settings.',i:'🛡️'}};
function setRole(r,shop){const b=document.body;b.className=b.className.replace(/\brole-\w+/g,'').trim();b.classList.add('role-'+r);
 const c=document.getElementById('roleChip');if(c){const u=ROLEUI[r]||ROLEUI.guest;c.className='rolechip rc-'+r;c.innerHTML='<i aria-hidden="true">'+u.i+'</i>'+esc(u.t)+(shop?'<small>'+esc(shop)+'</small>':'');c.title='Signed in as '+u.t+(shop?' · '+shop:'')}
 const h=document.getElementById('roleHero');if(h&&shop&&b.dataset.page==='vendordash'){const s=h.querySelector('.rh-shop');if(s)s.textContent=shop}}
function roleHero(){const pg=document.body.dataset.page,H=HERO[pg];if(!H)return;const h1=document.querySelector('main>h1');if(!h1)return;
 h1.insertAdjacentHTML('beforebegin','<section class="rolehero rh-'+pg+'" id="roleHero"><div class="rh-ic" aria-hidden="true">'+H.i+'</div><div><span class="rh-k">'+H.k+'</span><h1>'+H.t+'</h1><p>'+H.s+' <b class="rh-shop"></b></p>'+(pg==='consumer'?'<a class="rh-sell" href="apply.html">Have something to sell? Become a vendor →</a>':'')+'</div></section>');h1.remove()}
function layout(){
 const live=configured;
 const out=live?authLinks():'<a href="login.html">Sign in</a>';
 const msg=live?'Preview v1.7 – products labeled SAMPLE are fictional. Wallet payments and plans are TEST MODE only. No real payments or billing.':'Preview v1.1 – all vendors and products are SAMPLE data. Accounts are not switched on yet. No real payments.';
 if(!document.querySelector('link[data-cc-fonts]')){const l=document.createElement('link');l.rel='stylesheet';l.dataset.ccFonts='1';l.href='https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,600;0,9..144,800;1,9..144,600&family=Plus+Jakarta+Sans:wght@400;500;700;800&display=swap';document.head.appendChild(l)}
 const m=document.querySelector('main');if(m)m.id='main';
 const home=document.body.dataset.page==='home';
 document.body.insertAdjacentHTML('afterbegin','<a class="skip" href="#main">Skip to content</a><div class="banner">'+msg+'</div><header><div class="row"><a class="logo" href="index.html">'+LOGO+'<div>Carriacou <span>Connect</span><small>Marketplace</small></div></a><span id="roleChip" class="rolechip rc-guest">Guest</span><nav aria-label="Main"><a class="mktbtn'+(/browse\.html$/.test(location.pathname)||document.body.dataset.page==='browse'?' on" aria-current="page':'')+'" href="browse.html"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 9l1.5-5h15L21 9M3 9h18M3 9v1a3 3 0 006 0 3 3 0 006 0 3 3 0 006 0V9M5 13v7h14v-7"/></svg>Marketplace</a><span id="roleNav"><a href="tiers.html">Plans</a><a href="apply.html">Sell</a></span><a class="cartlink" href="cart.html">Cart<b id="cartCount">0</b></a><span id="authNav">'+out+'</span></nav></div></header>');
 roleHero();setRole('guest');cartBadge();if(!window.CC_CART_WIRED){window.CC_CART_WIRED=1;addEventListener('storage',e=>{if(!e.key||e.key==='cconnect_cart_v1')cartBadge()});addEventListener('pageshow',cartBadge)}
 const hasBand=document.querySelector('.band');
 document.body.insertAdjacentHTML('beforeend',(hasBand?'':WAVE('#04202c',false).replace('class="wave-sep"','class="wave-sep foot-wave"'))+'<footer><b>Carriacou Connect®</b><br>by Williams’ Tech · Marketplace v1.7 preview<br><a href="apply.html">Sell on Carriacou Connect</a> · <a href="vendor-terms.html">Vendor terms (draft)</a><br>Sea, reef, spice and sail: made on Carriacou.</footer>');
 if(live)authNav();
 if(!matchMedia('(prefers-reduced-motion: reduce)').matches&&'IntersectionObserver' in window){const io=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting){e.target.classList.add('in');io.unobserve(e.target)}}),{threshold:.08});window.CC_REVEAL=()=>document.querySelectorAll('.rv:not(.in)').forEach(x=>io.observe(x))}
 else window.CC_REVEAL=()=>document.querySelectorAll('.rv').forEach(x=>x.classList.add('in'));
}
async function acctStatus(sb){ // the person's OWN suspension status (admin_customers.sql). Quietly "not suspended" if the function is not installed.
 try{const r=await sb.rpc('my_account_status');return r&&!r.error&&r.data&&r.data.suspended?{suspended:true,message:r.data.message||'Your account is suspended. Please contact Carriacou Connect support.'}:{suspended:false}}catch(e){return {suspended:false}}
}
async function suspBanner(sb){
 if(document.getElementById('suspBanner'))return;
 const st=await acctStatus(sb);window.CC.suspended=!!st.suspended;if(!st.suspended)return;
 const h=document.querySelector('header');if(!h||document.getElementById('suspBanner'))return;
 h.insertAdjacentHTML('afterend','<div class="notice err susp-banner" id="suspBanner" role="alert"><b>Account suspended.</b> '+esc(st.message)+'</div>');
}
// load realtime.js once per page after login and start it (bell, toasts, live refresh)
function startLive(sb,user){
 const go=()=>{if(window.CC.rt)window.CC.rt.start(sb,user)};
 if(window.CC.rt)return go();
 if(document.querySelector('script[data-cc-rt]'))return;
 const s=document.createElement('script');s.src='realtime.js';s.dataset.ccRt='1';s.onload=go;s.onerror=()=>console.warn('realtime.js did not load; live updates are off');document.head.appendChild(s);
 if(!startLive.susp){startLive.susp=1;live.on(n=>{if(n&&/^account_(suspended|reactivated)$/.test(n.kind||'')){const b=document.getElementById('suspBanner');if(b)b.remove();suspBanner(sb)}})}
}
// v1.8.1: role-specific nav. Last role cached (cc_role_v1) and painted at once to avoid a Guest flash, then verified.
const RKEY='cc_role_v1';
const DASH={customer:['dashboard-consumer.html','My orders'],vendor:['dashboard-vendor.html','Vendor studio'],staff:['dashboard-vendor.html','Team studio'],admin:['admin.html','Admin']};
function paintNav(r,shop){const el=document.getElementById('authNav'),rn=document.getElementById('roleNav');if(!el)return;
 setRole(r,shop);
 if(r==='guest'){if(rn)rn.innerHTML='<a href="tiers.html">Plans</a><a href="apply.html">Sell</a>';el.innerHTML=authLinks();return}
 if(rn)rn.innerHTML=r==='vendor'?'<a href="tiers.html">Plans</a>':'';
 const d=DASH[r],here=location.pathname.split('/').pop()===d[0];
 el.innerHTML='<span id="ccBell" class="bellslot"></span><a class="dashlink'+(here?' on':'')+'" href="'+d[0]+'">'+d[1]+'</a>'+(r==='admin'||r==='staff'?'<a href="dashboard-consumer.html">My orders</a>':'')+'<a href="wallet.html">Wallet</a><a href="account.html">Account</a><a class="pill" href="#" id="logoutLink">Log out</a>'}
document.addEventListener('click',async e=>{const a=e.target.closest&&e.target.closest('#logoutLink');if(!a)return;e.preventDefault();try{localStorage.removeItem(RKEY)}catch(x){}const sb=await client();if(sb)await sb.auth.signOut();location.href='index.html'});
async function authNav(){
 let cached=null;try{cached=JSON.parse(localStorage.getItem(RKEY))}catch(e){}
 if(cached&&DASH[cached.r])paintNav(cached.r,cached.shop||'');
 const sb=await client();if(!sb)return;
 const render=async user=>{
  if(!user){try{localStorage.removeItem(RKEY)}catch(e){}paintNav('guest');return}
  let role='consumer',team=false;try{const {data}=await sb.from('profiles').select('role').eq('id',user.id).maybeSingle();if(data)role=data.role}catch(e){}
  if(role!=='vendor'&&role!=='admin'){try{const r=await sb.rpc('my_vendor_access');team=!r.error&&Array.isArray(r.data)&&r.data.length>0}catch(e){}}
  suspBanner(sb);
  let shop='';if(role==='vendor'){try{const v=await sb.from('vendors').select('name').eq('owner_id',user.id).limit(1);if(v.data&&v.data[0])shop=v.data[0].name}catch(e){}}
  const r=role==='admin'?'admin':role==='vendor'?'vendor':team?'staff':'customer';
  if(!cached||cached.uid!==user.id||cached.r!==r||(cached.shop||'')!==shop||!document.getElementById('ccBell'))paintNav(r,shop);
  try{localStorage.setItem(RKEY,JSON.stringify({uid:user.id,r,shop}))}catch(e){}
  startLive(sb,user)};
 render(await getUser());
 sb.auth.onAuthStateChange((ev)=>{if(ev==='SIGNED_OUT')render(null)});
}
const PCOLS='id,vendor_id,name,description,price_xcd,category,image_url,active,featured,created_at,updated_at,stock_qty,low_stock_threshold,sku',PCOLS_BASE='id,vendor_id,name,description,price_xcd,category,image_url,active,featured,created_at,updated_at,stock_qty,low_stock_threshold'; // never '*': products.cost_price is private (standard_analytics.sql)
// Price breakdown of one order row (v1.5): [{k,v,kind}]. kind: 'neg' (discount), 'info' (tax already inside the total), 'total'.
// Old orders (before tax_delivery.sql) have no tax_xcd: no tax line is shown for them.
function orderLines(o){
 const L=[{k:'Subtotal',v:Number(o.subtotal_xcd)||0}];
 if(Number(o.discount_xcd)>0)L.push({k:'Promo discount',v:-Number(o.discount_xcd),kind:'neg'});
 if(o.fulfilment==='delivery'||Number(o.delivery_fee_xcd)>0)L.push({k:'Delivery fee'+(o.delivery_area?' ('+o.delivery_area+')':''),v:Number(o.delivery_fee_xcd)||0});
 if(o.tax_xcd!=null&&Number(o.tax_rate_pct)>0)L.push({k:(o.tax_inclusive?'Includes VAT':'VAT')+' ('+Number(o.tax_rate_pct)+'%)',v:Number(o.tax_xcd)||0,kind:o.tax_inclusive?'info':''});
 L.push({k:'Total',v:Number(o.total_xcd)||0,kind:'total'});return L}
window.CC={setRole,cartBadge,live,orderLines,acctStatus,PCOLS,PCOLS_BASE,TESTBANNER,cents,toCents,uuid,payPill,noteSummary,newBadge,notesWidget,NOTE_POLL,SLABEL,stPill,fdate,fnice,payText,nextSteps,timeline,safeNext,WAVE,configured,client,esc,getUser,layout,TIER_LABEL,TIER_LIMIT,TIERS,lim,ROLE_LABEL,ROLE_PERMS,
 xcd:n=>'EC$'+Number(n).toFixed(2)};
layout();
})();
