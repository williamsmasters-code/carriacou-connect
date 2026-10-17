// Shared: config, Supabase client (lazy, CDN), nav/layout. Loaded on every page before app.js / auth.js.
(function(){
const cfg=window.CCONNECT_CONFIG||{};
const configured=/^https:\/\/[a-z0-9-]+\.supabase\.(co|in)\/?$/i.test(cfg.SUPABASE_URL||'')&&!/YOUR-/i.test(cfg.SUPABASE_URL||'')&&(cfg.SUPABASE_ANON_KEY||'').length>20&&!/YOUR-/i.test(cfg.SUPABASE_ANON_KEY||'');
const CDN='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js';
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let clientP=null;
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
 load();
 timer=setInterval(()=>{if(!box.isConnected)return clearInterval(timer);if(!document.hidden)load()},NOTE_POLL);
 return {reload:load,stop:()=>clearInterval(timer)};
}
// only allow same-site relative page names as a post-login destination
function safeNext(){const n=new URLSearchParams(location.search).get('next')||'';return /^[a-z0-9-]+\.html(\?[a-z0-9_=&.-]*)?$/i.test(n)?n:''}
const LOGO='<svg viewBox="0 0 48 48" aria-hidden="true"><defs><linearGradient id="lg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f4b942"/><stop offset="1" stop-color="#ff6b4a"/></linearGradient></defs><circle cx="24" cy="24" r="23" fill="#0b7285"/><circle cx="33" cy="15" r="6" fill="url(#lg)"/><path d="M24 9 L36 31 H24Z M22 13 L11 31 H22Z" fill="#fff"/><path d="M8 34h32l-4 6H12z" fill="#f4b942"/><path d="M4 41q5-3 10 0t10 0 10 0 10 0" stroke="#9fe3dc" stroke-width="2" fill="none"/></svg>';
const WAVE=(fill,flip)=>'<svg class="wave-sep" viewBox="0 0 1440 90" preserveAspectRatio="none" aria-hidden="true" style="height:clamp(34px,6vw,80px)'+(flip?';transform:scaleY(-1)':'')+'"><path fill="'+fill+'" d="M0 50 C180 100 320 0 540 40 S900 100 1100 40 1340 10 1440 50 V90 H0Z"/></svg>';
function authLinks(){return '<a href="login.html">Log in</a><a class="pill" href="signup.html">Sign up</a>'}
function layout(){
 const live=configured;
 const out=live?authLinks():'<a href="login.html">Log in</a>';
 const msg=live?'Preview v0.8 – products labeled SAMPLE are fictional. Wallet payments are TEST MODE play money only. No real payments.':'Preview v0.8 – all vendors and products are SAMPLE data. Accounts are not switched on yet. No real payments.';
 if(!document.querySelector('link[data-cc-fonts]')){const l=document.createElement('link');l.rel='stylesheet';l.dataset.ccFonts='1';l.href='https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,600;0,9..144,800;1,9..144,600&family=Plus+Jakarta+Sans:wght@400;500;700;800&display=swap';document.head.appendChild(l)}
 const m=document.querySelector('main');if(m)m.id='main';
 const home=document.body.dataset.page==='home';
 document.body.insertAdjacentHTML('afterbegin','<a class="skip" href="#main">Skip to content</a><div class="banner">'+msg+'</div><header><div class="row"><a class="logo" href="index.html">'+LOGO+'<div>Carriacou <span>Connect</span><small>Marketplace</small></div></a><nav aria-label="Main"><a href="browse.html">Browse</a><a class="cartlink" href="cart.html">Cart<b id="cartCount">0</b></a><span id="authNav">'+out+'</span></nav></div></header>');
 const hasBand=document.querySelector('.band');
 document.body.insertAdjacentHTML('beforeend',(hasBand?'':WAVE('#04202c',false).replace('class="wave-sep"','class="wave-sep foot-wave"'))+'<footer><b>Carriacou Connect®</b><br>by Williams’ Tech · Marketplace v0.8 preview<br>Sea, reef, spice and sail: made on Carriacou.</footer>');
 if(live)authNav();
 if(!matchMedia('(prefers-reduced-motion: reduce)').matches&&'IntersectionObserver' in window){const io=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting){e.target.classList.add('in');io.unobserve(e.target)}}),{threshold:.08});window.CC_REVEAL=()=>document.querySelectorAll('.rv:not(.in)').forEach(x=>io.observe(x))}
 else window.CC_REVEAL=()=>document.querySelectorAll('.rv').forEach(x=>x.classList.add('in'));
}
async function authNav(){
 const sb=await client();if(!sb)return;
 const render=async user=>{const el=document.getElementById('authNav');if(!el)return;
  if(!user){el.innerHTML=authLinks();return}
  let role='consumer';try{const {data}=await sb.from('profiles').select('role').eq('id',user.id).maybeSingle();if(data)role=data.role}catch(e){}
  el.innerHTML=`<a href="${role==='vendor'?'dashboard-vendor.html':'dashboard-consumer.html'}">Dashboard</a><a href="wallet.html">Wallet</a><a href="account.html">Account</a><a class="pill" href="#" id="logoutLink">Log out</a>`;
  document.getElementById('logoutLink').onclick=async e=>{e.preventDefault();await sb.auth.signOut();location.href='index.html'}};
 render(await getUser());
 sb.auth.onAuthStateChange((ev)=>{if(ev==='SIGNED_OUT')render(null)});
}
window.CC={TESTBANNER,cents,toCents,uuid,payPill,noteSummary,newBadge,notesWidget,NOTE_POLL,SLABEL,stPill,fdate,fnice,payText,nextSteps,timeline,safeNext,WAVE,configured,client,esc,getUser,layout,TIER_LABEL,TIER_LIMIT,
 xcd:n=>'EC$'+Number(n).toFixed(2)};
layout();
})();
