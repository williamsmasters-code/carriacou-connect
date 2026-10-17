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
const LOGO='<svg viewBox="0 0 48 48" aria-hidden="true"><defs><linearGradient id="lg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f4b942"/><stop offset="1" stop-color="#ff6b4a"/></linearGradient></defs><circle cx="24" cy="24" r="23" fill="#0b7285"/><circle cx="33" cy="15" r="6" fill="url(#lg)"/><path d="M24 9 L36 31 H24Z M22 13 L11 31 H22Z" fill="#fff"/><path d="M8 34h32l-4 6H12z" fill="#f4b942"/><path d="M4 41q5-3 10 0t10 0 10 0 10 0" stroke="#9fe3dc" stroke-width="2" fill="none"/></svg>';
const WAVE=(fill,flip)=>'<svg class="wave-sep" viewBox="0 0 1440 90" preserveAspectRatio="none" aria-hidden="true" style="height:clamp(34px,6vw,80px)'+(flip?';transform:scaleY(-1)':'')+'"><path fill="'+fill+'" d="M0 50 C180 100 320 0 540 40 S900 100 1100 40 1340 10 1440 50 V90 H0Z"/></svg>';
function authLinks(){return '<a href="login.html">Log in</a><a class="pill" href="signup.html">Sign up</a>'}
function layout(){
 const live=configured;
 const out=live?authLinks():'<a href="login.html">Log in</a>';
 const msg=live?'Preview v0.3 – products labeled SAMPLE are fictional. No real payments.':'Preview v0.3 – all vendors and products are SAMPLE data. Accounts are not switched on yet. No real payments.';
 if(!document.querySelector('link[data-cc-fonts]')){const l=document.createElement('link');l.rel='stylesheet';l.dataset.ccFonts='1';l.href='https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,600;0,9..144,800;1,9..144,600&family=Plus+Jakarta+Sans:wght@400;500;700;800&display=swap';document.head.appendChild(l)}
 const m=document.querySelector('main');if(m)m.id='main';
 const home=document.body.dataset.page==='home';
 document.body.insertAdjacentHTML('afterbegin','<a class="skip" href="#main">Skip to content</a><div class="banner">'+msg+'</div><header><div class="row"><a class="logo" href="index.html">'+LOGO+'<div>Carriacou <span>Connect</span><small>Marketplace</small></div></a><nav aria-label="Main"><a href="browse.html">Browse</a><a class="cartlink" href="cart.html">Cart<b id="cartCount">0</b></a><span id="authNav">'+out+'</span></nav></div></header>');
 const hasBand=document.querySelector('.band');
 document.body.insertAdjacentHTML('beforeend',(hasBand?'':WAVE('#04202c',false).replace('class="wave-sep"','class="wave-sep foot-wave"'))+'<footer><b>Carriacou Connect®</b><br>by Williams’ Tech · Marketplace v0.3 preview<br>Sea, reef, spice and sail: made on Carriacou.</footer>');
 if(live)authNav();
 if(!matchMedia('(prefers-reduced-motion: reduce)').matches&&'IntersectionObserver' in window){const io=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting){e.target.classList.add('in');io.unobserve(e.target)}}),{threshold:.08});window.CC_REVEAL=()=>document.querySelectorAll('.rv:not(.in)').forEach(x=>io.observe(x))}
 else window.CC_REVEAL=()=>document.querySelectorAll('.rv').forEach(x=>x.classList.add('in'));
}
async function authNav(){
 const sb=await client();if(!sb)return;
 const render=async user=>{const el=document.getElementById('authNav');if(!el)return;
  if(!user){el.innerHTML=authLinks();return}
  let role='consumer';try{const {data}=await sb.from('profiles').select('role').eq('id',user.id).maybeSingle();if(data)role=data.role}catch(e){}
  el.innerHTML=`<a href="${role==='vendor'?'dashboard-vendor.html':'dashboard-consumer.html'}">Dashboard</a><a href="account.html">Account</a><a class="pill" href="#" id="logoutLink">Log out</a>`;
  document.getElementById('logoutLink').onclick=async e=>{e.preventDefault();await sb.auth.signOut();location.href='index.html'}};
 render(await getUser());
 sb.auth.onAuthStateChange((ev)=>{if(ev==='SIGNED_OUT')render(null)});
}
window.CC={WAVE,configured,client,esc,getUser,layout,TIER_LABEL,TIER_LIMIT,
 xcd:n=>'EC$'+Number(n).toFixed(2)};
layout();
})();
