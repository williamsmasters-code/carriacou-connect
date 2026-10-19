// v1.7 LIVE UPDATES: notification bell, toasts and live page refresh. Loaded by cc.js after login (one instance per page).
// Source of truth: public.notifications (supabase/realtime.sql). Supabase Realtime pushes INSERT/UPDATE events for the person's
// OWN rows only (RLS). Pages listen with CC.live.on(fn) and re-read the affected record through their normal queries.
// Fallbacks: if Realtime cannot connect -> notif_since() every 30 s (and reconnect with backoff);
//            if realtime.sql is not installed -> no bell, and a synthetic {kind:'poll_tick'} every 30 s so pages still refresh.
(function(){
const CC=window.CC;if(!CC||CC.rt)return;
const esc=CC.esc,POLL=window.CC_RT_POLL_MS||30000,SOUND='cc_notif_sound';
const S={sb:null,user:null,mode:'idle',lastId:0,unread:0,items:[],seen:new Set(),ch:null,pollT:null,retryT:null,retryDue:false,backoff:2000,started:false,stopped:false};
const missing=m=>/Could not find the function|schema cache|PGRST202|does not exist/i.test(m||'');
const rpc=async(n,a)=>{try{return await S.sb.rpc(n,a)}catch(e){return {error:{message:(e&&e.message)||'Network error'}}}};
const ICON={order_new:'🛒',order_status:'📦',order_cancelled:'✖',order_paid:'💳',note_new:'💬',wallet_received:'🪙',refund:'↩',pos_paid:'✅',admin_application:'📝',application_decision:'🏪',vendor_status:'🏪',vendor_owner:'🔑',admin_upgrade_request:'⬆',upgrade_decision:'⬆',staff_joined:'👋',account_suspended:'⚠',account_reactivated:'✔',account_updated:'👤'};
const ago=t=>{const s=Math.max(0,(Date.now()-new Date(t).getTime())/1000);return s<60?'just now':s<3600?Math.floor(s/60)+' min ago':s<86400?Math.floor(s/3600)+' h ago':CC.fdate(t)};
const safeLink=l=>/^[a-z0-9-]+\.html([?#][A-Za-z0-9_=&.#%-]*)?$/.test(l||'')?l:'';
const BELL='<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M12 22a2.5 2.5 0 0 0 2.45-2h-4.9A2.5 2.5 0 0 0 12 22Zm7-6V11a7 7 0 0 0-5.5-6.84V3.5a1.5 1.5 0 0 0-3 0v.66A7 7 0 0 0 5 11v5l-2 2v1h18v-1Z"/></svg>';
let baseTitle=document.title;
// ---------- UI ----------
function mountUi(){
 const slot=document.getElementById('ccBell');if(!slot||slot.dataset.on)return;slot.dataset.on='1';
 slot.innerHTML='<button type="button" class="bell" id="bellBtn" aria-haspopup="true" aria-expanded="false" aria-controls="bellPanel" aria-label="Notifications">'+BELL+'<b class="bellcount" id="bellCount" hidden>0</b></button>'+
  '<div class="bellpanel" id="bellPanel" role="region" aria-label="Notifications" hidden><div class="bphead"><b>Notifications</b><button type="button" class="linkbtn" id="bellAll">Mark all read</button></div>'+
  '<ul class="bplist" id="bellList"></ul><div class="bpfoot"><label class="bpsnd"><input type="checkbox" id="bellSound"> Sound</label><small id="bellState" class="bpstate"></small></div></div>';
 const btn=slot.querySelector('#bellBtn'),pn=slot.querySelector('#bellPanel');
 const close=()=>{pn.hidden=true;btn.setAttribute('aria-expanded','false')};
 btn.onclick=e=>{e.stopPropagation();const open=pn.hidden;pn.hidden=!open;btn.setAttribute('aria-expanded',String(open));if(open){pn.style.top=matchMedia('(max-width:640px)').matches?Math.round(btn.getBoundingClientRect().bottom+8)+'px':'';renderList();const f=pn.querySelector('a,button');if(f)f.focus()}};
 document.addEventListener('click',e=>{if(!pn.hidden&&!slot.contains(e.target))close()});
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!pn.hidden){close();btn.focus()}});
 slot.querySelector('#bellAll').onclick=async()=>{const r=await rpc('notif_mark_all_read',{});if(!r.error){S.items.forEach(i=>{i.read_at=i.read_at||new Date().toISOString()});S.unread=0;renderBell();renderList()}};
 const snd=slot.querySelector('#bellSound');snd.checked=localStorage.getItem(SOUND)==='1';snd.onchange=()=>{localStorage.setItem(SOUND,snd.checked?'1':'0');if(snd.checked)beep()};
 slot.querySelector('#bellList').addEventListener('click',async e=>{
  const mk=e.target.closest('[data-mark]');if(mk){e.preventDefault();await markRead(+mk.dataset.mark);return}
  const a=e.target.closest('a[data-id]');if(a){const id=+a.dataset.id;const it=S.items.find(i=>i.id===id);if(it&&!it.read_at)markRead(id);close();sameTarget(a,e)}});
 renderBell();
}
function sameTarget(a,e){ // a link to the page we are already on: no reload, just switch tab (pages refresh themselves live)
 try{const u=new URL(a.href,location.href);if(u.pathname===location.pathname&&u.search===location.search){e.preventDefault();if(u.hash&&u.hash!==location.hash)location.hash=u.hash}}catch(_){}}
async function markRead(id){const it=S.items.find(i=>i.id===id);const r=await rpc('notif_mark_read',{p_ids:[id]});if(r.error)return;if(it)it.read_at=new Date().toISOString();if(r.data&&typeof r.data.unread==='number')S.unread=r.data.unread;renderBell();renderList()}
function renderBell(){
 const c=document.getElementById('bellCount'),b=document.getElementById('bellBtn');
 if(c){c.hidden=!S.unread;c.textContent=S.unread>99?'99+':String(S.unread)}
 if(b)b.setAttribute('aria-label','Notifications'+(S.unread?', '+S.unread+' unread':''));
 document.title=(S.unread?'('+(S.unread>99?'99+':S.unread)+') ':'')+baseTitle;
 const st=document.getElementById('bellState');if(st)st.textContent=S.mode==='live'?'● Live':S.mode==='poll'?'Checking every '+Math.round(POLL/1000)+' s':'';
}
function renderList(){
 const L=document.getElementById('bellList');if(!L)return;
 L.innerHTML=S.items.length?S.items.map(n=>{const l=safeLink(n.link);return '<li class="bpi'+(n.read_at?'':' unread')+'"><a href="'+esc(l||'#')+'" data-id="'+n.id+'"><span class="bpic" aria-hidden="true">'+(ICON[n.kind]||'🔔')+'</span><span class="bptx"><b>'+esc(n.title)+'</b>'+(n.body?'<small>'+esc(n.body)+'</small>':'')+'<small class="bpt">'+esc(ago(n.created_at))+(n.read_at?'':'<span class="sr"> · unread</span>')+'</small></span></a>'+(n.read_at?'':'<button type="button" class="bpmark" data-mark="'+n.id+'" aria-label="Mark as read" title="Mark as read">✓</button>')+'</li>'}).join(''):'<li class="bpempty">No notifications yet. Order updates, notes and payments will show up here.</li>';
}
function toastBox(){let t=document.getElementById('ccToasts');if(!t){t=document.createElement('div');t.id='ccToasts';t.className='toasts';t.setAttribute('role','status');t.setAttribute('aria-live','polite');document.body.appendChild(t)}return t}
function toast(n){
 const box=toastBox(),l=safeLink(n.link);while(box.children.length>=3)box.firstChild.remove();
 const d=document.createElement('div');d.className='toast';
 d.innerHTML='<a href="'+esc(l||'#')+'"><span class="bpic" aria-hidden="true">'+(ICON[n.kind]||'🔔')+'</span><span><b>'+esc(n.title)+'</b>'+(n.body?'<small>'+esc(n.body)+'</small>':'')+'</span></a><button type="button" aria-label="Dismiss notification">×</button>';
 d.querySelector('button').onclick=()=>d.remove();
 d.querySelector('a').onclick=e=>{if(!S.items.find(i=>i.id===n.id&&i.read_at))markRead(n.id);if(!l)e.preventDefault();else sameTarget(e.currentTarget,e);d.remove()};
 box.appendChild(d);setTimeout(()=>d.remove(),8000);
}
let actx=null;
function beep(){if(localStorage.getItem(SOUND)!=='1')return;try{actx=actx||new (window.AudioContext||window.webkitAudioContext)();const o=actx.createOscillator(),g=actx.createGain();o.type='sine';o.frequency.value=880;g.gain.setValueAtTime(.0001,actx.currentTime);g.gain.exponentialRampToValueAtTime(.15,actx.currentTime+.02);g.gain.exponentialRampToValueAtTime(.0001,actx.currentTime+.35);o.connect(g);g.connect(actx.destination);o.start();o.stop(actx.currentTime+.4)}catch(e){}}
// ---------- data ----------
function onRow(n,quiet){
 if(!n||n.id==null||S.seen.has(n.id))return;S.seen.add(n.id);
 if(n.user_id&&S.user&&n.user_id!==S.user.id)return;   // never expected (RLS + filter), but never show someone else's row
 S.lastId=Math.max(S.lastId,n.id);
 if(!n.silent){S.items.unshift(n);S.items=S.items.slice(0,30);if(!n.read_at)S.unread++;renderBell();{const pn=document.getElementById('bellPanel');if(pn&&!pn.hidden)renderList()}if(!quiet){toast(n);beep()}}
 CC.live.emit(n);
}
function onUpdate(n){const it=S.items.find(i=>i.id===n.id);if(n.read_at&&it&&!it.read_at){it.read_at=n.read_at;S.unread=Math.max(0,S.unread-1);renderBell();renderList()}}
async function catchUp(){
 if(S.mode==='off'){CC.live.emit({kind:'poll_tick',synthetic:true});return}
 const r=await rpc('notif_since',{p_after:S.lastId});if(r.error||!r.data)return;
 (r.data.items||[]).forEach(n=>onRow(n,false));if(typeof r.data.unread==='number'){S.unread=r.data.unread;renderBell()}
}
function startPoll(){if(S.pollT)return;S.pollT=setInterval(()=>{if(!document.hidden)catchUp()},POLL)}
function stopPoll(){clearInterval(S.pollT);S.pollT=null}
function setMode(m){S.mode=m;CC.live.state=m;renderBell()}
function schedule(){clearTimeout(S.retryT);const wait=S.backoff;S.backoff=Math.min(S.backoff*2,120000);S.retryT=setTimeout(()=>{if(document.hidden){S.retryDue=true;return}connect()},wait)}
async function connect(){
 if(S.stopped)return;S.retryDue=false;
 if(typeof S.sb.channel!=='function'){setMode('poll');startPoll();return}
 try{const ss=await S.sb.auth.getSession();const tok=ss&&ss.data&&ss.data.session&&ss.data.session.access_token;if(tok&&S.sb.realtime&&S.sb.realtime.setAuth)S.sb.realtime.setAuth(tok)}catch(e){}
 if(S.ch){const old=S.ch;S.ch=null;try{S.sb.removeChannel(old)}catch(e){}}
 const f='user_id=eq.'+S.user.id;let ch;
 try{ch=S.sb.channel('cc-notif-'+S.user.id+'-'+Date.now().toString(36))
  .on('postgres_changes',{event:'INSERT',schema:'public',table:'notifications',filter:f},p=>onRow(p&&p.new,false))
  .on('postgres_changes',{event:'UPDATE',schema:'public',table:'notifications',filter:f},p=>onUpdate((p&&p.new)||{}))}
 catch(e){setMode('poll');startPoll();schedule();return}
 S.ch=ch;
 ch.subscribe(status=>{if(ch!==S.ch)return;
  if(status==='SUBSCRIBED'){setMode('live');S.backoff=2000;stopPoll();catchUp()}
  else if(status==='CHANNEL_ERROR'||status==='TIMED_OUT'||status==='CLOSED'){if(S.stopped)return;setMode('poll');startPoll();schedule()}});
}
function stop(){S.stopped=true;stopPoll();clearTimeout(S.retryT);if(S.ch){try{S.sb.removeChannel(S.ch)}catch(e){}S.ch=null}const s=document.getElementById('ccBell');if(s){s.innerHTML='';delete s.dataset.on}S.unread=0;document.title=baseTitle}
async function start(sb,user){
 if(S.started||!sb||!user)return;S.started=true;S.sb=sb;S.user=user;baseTitle=document.title.replace(/^\(\d+\+?\) /,'');
 const r=await rpc('notif_list',{p_limit:20,p_before:null});
 if(r.error){
  if(missing(r.error.message)){setMode('off');startPoll();return}   // realtime.sql not run yet: pages keep their own refresh + 30 s ticks
  setMode('poll');mountUi();startPoll();schedule();return}
 S.items=(r.data.items||[]);S.items.forEach(i=>S.seen.add(i.id));S.unread=r.data.unread||0;S.lastId=r.data.last_id||0;
 mountUi();connect();
 document.addEventListener('visibilitychange',()=>{if(document.hidden||S.stopped)return;if(S.retryDue)connect();else catchUp()});
 window.addEventListener('online',()=>{if(S.mode!=='live'&&!S.stopped){S.backoff=2000;connect()}});
 try{sb.auth.onAuthStateChange((ev,session)=>{if(ev==='SIGNED_OUT')stop();else if(session&&session.access_token&&sb.realtime&&sb.realtime.setAuth)sb.realtime.setAuth(session.access_token)})}catch(e){}
}
CC.rt={start,stop,state:()=>S.mode,_s:S,_toast:toast};
})();
