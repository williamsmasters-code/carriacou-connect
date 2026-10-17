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
function layout(){
 const live=configured;
 const out=live?'<a href="login.html">Log in</a><a href="signup.html">Sign up</a>':'<a href="login.html">Log in</a>';
 const msg=live?'Preview v0.2 – products labeled SAMPLE are fictional. No real payments.':'Preview v0.2 – all vendors and products are SAMPLE data. Accounts are not switched on yet. No real payments.';
 document.body.insertAdjacentHTML('afterbegin','<div class="banner">'+msg+'</div><header><div class="row"><a class="logo" href="index.html">Carriacou <span>Connect</span> Marketplace</a><nav><a href="browse.html">Browse</a><a href="cart.html">Cart (<span id="cartCount">0</span>)</a><span id="authNav">'+out+'</span></nav></div></header>');
 document.body.insertAdjacentHTML('beforeend',`<footer>Carriacou Connect® by Williams’ Tech · Marketplace v0.2 preview</footer>`);
 if(live)authNav();
}
async function authNav(){
 const sb=await client();if(!sb)return;
 const render=async user=>{const el=document.getElementById('authNav');if(!el)return;
  if(!user){el.innerHTML='<a href="login.html">Log in</a><a href="signup.html">Sign up</a>';return}
  let role='consumer';try{const {data}=await sb.from('profiles').select('role').eq('id',user.id).maybeSingle();if(data)role=data.role}catch(e){}
  el.innerHTML=`<a href="${role==='vendor'?'dashboard-vendor.html':'dashboard-consumer.html'}">Dashboard</a><a href="account.html">Account</a><a href="#" id="logoutLink">Log out</a>`;
  document.getElementById('logoutLink').onclick=async e=>{e.preventDefault();await sb.auth.signOut();location.href='index.html'}};
 render(await getUser());
 sb.auth.onAuthStateChange((ev)=>{if(ev==='SIGNED_OUT')render(null)});
}
window.CC={configured,client,esc,getUser,layout,TIER_LABEL,TIER_LIMIT,
 xcd:n=>'EC$'+Number(n).toFixed(2)};
layout();
})();
