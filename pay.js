// Carriacou Connect Pay v0.6 - TEST MODE ONLY (play money). Wallet page + vendor POS page. No real payments, no card or bank details.
(function(){
const {esc,configured,cents,toCents,uuid,TESTBANNER,fdate}=window.CC;
const $=s=>document.querySelector(s);
const main=()=>document.querySelector('main');
const say=(el,msg,ok)=>{if(!el)return;el.className=ok?'notice ok':'notice err';el.textContent=msg||'';el.hidden=!msg};
const NOPAY='Wallets are not switched on yet: supabase/pay.sql has not been run in your Supabase project.';
const fixErr=e=>{const m=(e&&e.message)||'Something went wrong.';return /schema cache|does not exist|Could not find the function/i.test(m)?NOPAY:m};
const base=f=>new URL(f,location.href).href.split('?')[0].split('#')[0];
// ---- QR (vendor/qrcode.js, MIT, generated in the browser; nothing is sent anywhere) ----
function qrSvg(text,px){
 try{const q=qrcode(0,'M');q.addData(text);q.make();const n=q.getModuleCount(),m=4;let d='';
  for(let r=0;r<n;r++)for(let c=0;c<n;c++)if(q.isDark(r,c))d+='M'+(c+m)+' '+(r+m)+'h1v1h-1z';
  return '<svg class="qr" role="img" aria-label="QR code" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 '+(n+2*m)+' '+(n+2*m)+'" width="'+px+'" height="'+px+'" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#fff"/><path d="'+d+'" fill="#04202c"/></svg>'}
 catch(e){return '<div class="muted">QR code unavailable. Use the code below.</div>'}}
const copy=async(t,btn)=>{try{await navigator.clipboard.writeText(t)}catch(e){const i=document.createElement('input');i.value=t;document.body.appendChild(i);i.select();try{document.execCommand('copy')}catch(_){}i.remove()}
 if(btn){const o=btn.textContent;btn.textContent='Copied!';setTimeout(()=>btn.textContent=o,1400)}};
function offline(){main().innerHTML='<h1>Wallet</h1>'+TESTBANNER+'<div class="notice">Accounts and wallets are not switched on in this sample preview. See README.txt.</div>'}
async function boot(){
 if(!configured)return offline();
 const sb=await window.CC.client();if(!sb)return offline();
 const user=await window.CC.getUser();
 if(!user){location.href='login.html?next='+encodeURIComponent(location.pathname.split('/').pop()+location.search.replace(/[^a-z0-9_=&.-]/gi,''));return}
 return {sb,user};
}
const rpc=async(sb,n,a)=>{try{const r=await sb.rpc(n,a);return r}catch(e){return {error:{message:(e&&e.message)||'Network error'}}}};

const pages={
async wallet(){
 const c=await boot();if(!c)return;const {sb,user}=c;const R=$('#pay');
 const q=new URLSearchParams(location.search);
 let wallets=[],cur=null,lim={topup_max_cents:50000,transfer_max_cents:200000};
 const lr=await rpc(sb,'pay_limits',{});if(lr.data)lim=lr.data;
 async function loadWallets(){const r=await rpc(sb,'ensure_wallets',{});if(r.error){R.innerHTML=TESTBANNER+'<div class="notice err">'+esc(fixErr(r.error))+'</div>';return false}wallets=(r.data||[]).slice().sort((a,b)=>(a.kind==='vendor'?0:1)-(b.kind==='vendor'?0:1));if(!cur||!wallets.some(w=>w.id===cur))cur=(wallets[0]||{}).id;return true}
 if(!await loadWallets())return;
 const W=()=>wallets.find(w=>w.id===cur);
 let keyTop=uuid(),keySend=uuid(),keyPay=uuid(),prevPay=null,pendingSend=null;
 async function draw(note){
  const w=W();let hist=[];const hr=await rpc(sb,'wallet_history',{p_wallet:w.id,p_limit:50});if(!hr.error)hist=hr.data||[];
  const isV=w.kind==='vendor',url=base('wallet.html')+'?to='+encodeURIComponent(w.code);
  R.innerHTML=TESTBANNER+`
  ${wallets.length>1?`<div class="dtabs wtabs" role="tablist" aria-label="Wallets">${wallets.map(x=>`<button role="tab" class="${x.id===cur?'on':''}" data-w="${esc(x.id)}">${x.kind==='vendor'?esc(x.label)+' (business)':'My wallet'}</button>`).join('')}</div>`:''}
  <div class="walletgrid">
   <section class="wcard wbal"><span class="kicker">${isV?esc(w.label)+' · business wallet':'Test balance'}</span><div class="bigbal" id="bal">${cents(w.balance_cents)}</div><small>XCD · play money, not real funds</small>
    <div class="wcode"><span class="muted">Wallet code</span><code id="wcode">${esc(w.code)}</code><button class="btn ghost sm" id="cpy" type="button">Copy</button></div></section>
   <section class="wcard wqr"><div class="qrbox">${qrSvg(url,168)}</div><small>Scan to send money to this wallet.<br>Play money only.</small></section>
  </div>
  <div id="wmsg" class="notice${note?' ok':''}" ${note?'':'hidden'} role="status">${esc(note||'')}</div>
  <div class="walletgrid forms">
   <form class="wcard" id="ftop" novalidate><h3>Add test money</h3><p class="muted">Free play money for testing. Up to ${cents(lim.topup_max_cents)} per top-up and per day.</p>
    <div class="chips">${[1000,2500,5000,10000,50000].map(v=>`<button type="button" class="chip" data-a="${v}">${cents(v)}</button>`).join('')}</div>
    <label>Amount (EC$)<input id="tamt" inputmode="decimal" placeholder="25.00" autocomplete="off"></label><button class="btn alt" id="tgo">Add test money</button></form>
   <form class="wcard" id="fsend" novalidate><h3>Send to another wallet</h3>
    <label>Wallet code or email<input id="sto" placeholder="CC-ABCD-EFGH or name@example.com" autocomplete="off" value="${esc((q.get('to')||'').slice(0,60))}"></label>
    <label>Amount (EC$)<input id="samt" inputmode="decimal" placeholder="10.00" autocomplete="off"></label>
    <label>Note (optional)<input id="snote" maxlength="200" autocomplete="off"></label>
    <div id="sconf" class="notice" hidden></div><button class="btn" id="sgo">Review and send</button></form>
   ${isV?'':`<form class="wcard" id="fpay" novalidate><h3>Pay a shop charge</h3><p class="muted">A vendor gives you a code like PAY-ABCD-EFGH (or a QR). Enter it to pay with your test wallet.</p>
    <label>Charge code<input id="pcode" placeholder="PAY-ABCD-EFGH" autocomplete="off" value="${esc((q.get('pay')||'').slice(0,20))}"></label><div id="pconf" class="notice" hidden></div><button class="btn" id="pgo">Look up charge</button></form>`}
  </div>
  ${isV?`<p class="muted">Customers can pay this wallet by order, by entering your wallet code, or with a POS charge code. <a href="pos.html">Open POS</a>. You can move test money to your personal wallet with Send (use their code).</p>`:''}
  <h2>History</h2>
  <div class="hist" id="hist">${hist.length?hist.map(h=>{const inn=h.direction==='in';const lab={topup_test:'Test top-up',transfer:inn?'Received from':'Sent to',order_payment:inn?'Order payment from':'Order payment to',refund:inn?'Refund from':'Refund to',adjustment:'Adjustment'}[h.type]||h.type;
    return `<div class="hrow ${inn?'in':'out'}"><div class="hic" aria-hidden="true">${inn?'↓':'↑'}</div><div class="hmid"><b>${esc(lab)}${h.type==='topup_test'?'':' '+esc(h.counterparty||'')}</b><small>${esc(fdate(h.created_at))}${h.note&&h.type!=='topup_test'?' · '+esc(h.note):''}</small></div><div class="hamt">${inn?'+':'-'}${cents(h.amount_cents)}</div></div>`}).join(''):'<div class="empty"><div class="empty-ic" aria-hidden="true">🪙</div><h3>No transactions yet</h3><p>Add some test money to get started.</p></div>'}</div>`;
  const m=$('#wmsg');
  R.querySelectorAll('[data-w]').forEach(b=>b.onclick=()=>{cur=b.dataset.w;draw()});
  $('#cpy').onclick=e=>copy(w.code,e.target);
  R.querySelectorAll('.chip').forEach(b=>b.onclick=()=>{$('#tamt').value=(b.dataset.a/100).toFixed(2)});
  const refresh=async note=>{await loadWallets();keyTop=uuid();keySend=uuid();keyPay=uuid();await draw(note)};
  $('#ftop').onsubmit=async e=>{e.preventDefault();const a=toCents($('#tamt').value);
   if(!a||a<1){say(m,'Enter an amount like 25.00');return}
   if(a>lim.topup_max_cents){say(m,'Test top-ups are limited to '+cents(lim.topup_max_cents)+' each.');return}
   $('#tgo').disabled=true;const r=await rpc(sb,'test_topup',{p_amount_cents:a,p_idempotency_key:keyTop,p_wallet:w.id});
   if(r.error){say(m,fixErr(r.error));$('#tgo').disabled=false;return}
   await refresh('Added '+cents(a)+' of test money.')};
  $('#fsend').onsubmit=async e=>{e.preventDefault();const to=$('#sto').value.trim(),a=toCents($('#samt').value),cf=$('#sconf');
   if(!to){say(m,'Enter a wallet code or email address.');return}
   if(!a||a<1){say(m,'Enter an amount like 10.00');return}
   if(a>Number(w.balance_cents)){say(m,'That is more than your test balance ('+cents(w.balance_cents)+').');return}
   if(a>lim.transfer_max_cents){say(m,'Test transfers are limited to '+cents(lim.transfer_max_cents)+' each.');return}
   say(m,'');
   if(!pendingSend||pendingSend.to!==to||pendingSend.a!==a){ // step 1: show who it goes to
    let label='this wallet';
    if(to.indexOf('@')<0){const pr=await rpc(sb,'wallet_preview',{p_code:to});if(pr.error){say(m,fixErr(pr.error));return}if(!pr.data.ok){say(m,'We could not find that wallet. Check the code and try again.');return}label=pr.data.label}
    else label=to;
    pendingSend={to,a};cf.hidden=false;cf.className='notice';cf.innerHTML='Send <b>'+cents(a)+'</b> of test money to <b>'+esc(label)+'</b>? Press the button again to confirm.';$('#sgo').textContent='Confirm and send';return}
   $('#sgo').disabled=true;
   const r=await rpc(sb,'transfer_wallet',{p_to:to,p_amount_cents:a,p_note:$('#snote').value.trim()||null,p_idempotency_key:keySend,p_from_wallet:w.id});
   if(r.error){say(m,fixErr(r.error));$('#sgo').disabled=false;return}
   if(!r.data.ok){say(m,'We could not find that wallet. Check the code or email and try again.');$('#sgo').disabled=false;pendingSend=null;$('#sconf').hidden=true;$('#sgo').textContent='Review and send';return}
   pendingSend=null;await refresh('Sent '+cents(a)+' to '+(r.data.to_label||'the wallet')+'.')};
  ['sto','samt'].forEach(id=>$('#'+id).addEventListener('input',()=>{pendingSend=null;$('#sconf').hidden=true;$('#sgo').textContent='Review and send'}));
  const fp=$('#fpay');
  if(fp){fp.onsubmit=async e=>{e.preventDefault();const code=$('#pcode').value.trim(),cf=$('#pconf');if(!code){say(m,'Enter the charge code.');return}say(m,'');
   if(!prevPay||prevPay.code!==code){const r=await rpc(sb,'charge_preview',{p_code:code});if(r.error){say(m,fixErr(r.error));return}
    if(!r.data.ok){say(m,'We could not find that charge. Check the code.');return}
    if(r.data.status!=='open'){say(m,'This charge is '+r.data.status+'.');return}
    if(Number(r.data.amount_cents)>Number(w.balance_cents)){say(m,'The charge is '+cents(r.data.amount_cents)+' but your test balance is '+cents(w.balance_cents)+'. Add test money first.');return}
    prevPay={code,d:r.data};cf.hidden=false;cf.className='notice';cf.innerHTML='Pay <b>'+cents(r.data.amount_cents)+'</b> to <b>'+esc(r.data.vendor_name)+'</b>'+(r.data.note?' ('+esc(r.data.note)+')':'')+'?'+(Array.isArray(r.data.items)&&r.data.items.length?'<ul>'+r.data.items.slice(0,20).map(i=>'<li>'+esc((i.qty||1)+' × '+(i.name||'item'))+'</li>').join('')+'</ul>':'')+'<br>Press the button again to confirm.';$('#pgo').textContent='Confirm and pay (test)';return}
   $('#pgo').disabled=true;const r=await rpc(sb,'pay_charge',{p_code:code,p_idempotency_key:keyPay,p_from_wallet:w.id});
   if(r.error){say(m,fixErr(r.error));$('#pgo').disabled=false;return}
   if(!r.data.ok){say(m,'We could not find that charge.');$('#pgo').disabled=false;return}
   const amt=prevPay.d.amount_cents;prevPay=null;history.replaceState(null,'',location.pathname);await refresh('Paid '+cents(amt)+' (test money).')};
   $('#pcode').addEventListener('input',()=>{prevPay=null;$('#pconf').hidden=true;$('#pgo').textContent='Look up charge'})}
  if(q.get('to')&&!draw.did){draw.did=1;$('#samt').focus()}
  if(q.get('pay')&&fp&&!draw.did2){draw.did2=1;fp.requestSubmit()}
 }
 await draw();
},

async pos(){
 const c=await boot();if(!c)return;const {sb,user}=c;const R=$('#pay');
 const vr=await sb.from('vendors').select('id,name').eq('owner_id',user.id).order('created_at').limit(1);
 const v=vr.data&&vr.data[0];
 if(!v){R.innerHTML=TESTBANNER+'<div class="notice">POS is for vendor businesses. <a href="signup.html">Sign up as a vendor</a> or <a href="dashboard-vendor.html">create your business profile</a>.</div>';return}
 const pr=await sb.from('products').select('id,name,price_xcd').eq('vendor_id',v.id).eq('active',true).order('name');
 const prods=pr.data||[];const qty={};let active=null,timer=null;
 const total=()=>Object.entries(qty).reduce((s,[id,n])=>{const p=prods.find(x=>x.id===id);return s+(p?Math.round(Number(p.price_xcd)*100)*n:0)},0);
 function form(note){
  clearInterval(timer);
  R.innerHTML=TESTBANNER+`<p class="muted">${esc(v.name)} · Customers pay from their <b>test wallet</b>. Create a charge, show the code or QR, and the customer enters it on their wallet page. <a href="wallet.html">My business wallet</a></p>
  <div id="pm" class="notice${note?' ok':''}" ${note?'':'hidden'} role="status">${esc(note||'')}</div>
  <div class="posgrid"><section class="wcard"><h3>Items</h3>${prods.length?`<div class="posprods">${prods.map(p=>`<div class="pprod"><div><b>${esc(p.name)}</b><small>${cents(Math.round(Number(p.price_xcd)*100))}</small></div><div class="qtyc"><button type="button" data-m="${esc(p.id)}" aria-label="Fewer ${esc(p.name)}">−</button><span id="q-${esc(p.id)}">${qty[p.id]||0}</span><button type="button" data-p="${esc(p.id)}" aria-label="More ${esc(p.name)}">+</button></div></div>`).join('')}</div>`:'<p class="muted">No active products. Enter a custom amount instead.</p>'}</section>
  <form class="wcard" id="fch" novalidate><h3>New charge</h3><div class="oline total2"><span>Items total</span><b id="itot">${cents(total())}</b></div>
   <label>Or custom amount (EC$)<input id="camt" inputmode="decimal" placeholder="0.00" autocomplete="off"></label>
   <label>Note (optional)<input id="cnote" maxlength="200" autocomplete="off"></label><button class="btn" id="cgo">Create charge</button></form></div>
  <h2>Recent charges</h2><div id="recent"><p class="muted">Loading…</p></div>`;
  const upd=()=>{$('#itot').textContent=cents(total())};
  R.querySelectorAll('[data-p]').forEach(b=>b.onclick=()=>{const id=b.dataset.p;qty[id]=Math.min(99,(qty[id]||0)+1);$('#q-'+id).textContent=qty[id];upd()});
  R.querySelectorAll('[data-m]').forEach(b=>b.onclick=()=>{const id=b.dataset.m;qty[id]=Math.max(0,(qty[id]||0)-1);$('#q-'+id).textContent=qty[id];upd()});
  $('#fch').onsubmit=async e=>{e.preventDefault();const m=$('#pm');const custom=toCents($('#camt').value||'0');
   if($('#camt').value.trim()&&custom==null){say(m,'Enter the custom amount like 12.50');return}
   const items=Object.entries(qty).filter(([,n])=>n>0).map(([id,n])=>{const p=prods.find(x=>x.id===id);return {name:p.name,qty:n,unit_cents:Math.round(Number(p.price_xcd)*100)}});
   if(custom)items.push({name:'Custom amount',qty:1,unit_cents:custom});
   const amt=total()+(custom||0);if(amt<1){say(m,'Pick items or enter an amount first.');return}
   $('#cgo').disabled=true;const r=await rpc(sb,'create_charge',{p_amount_cents:amt,p_note:$('#cnote').value.trim()||null,p_items:items});
   if(r.error){say(m,fixErr(r.error));$('#cgo').disabled=false;return}
   for(const k of Object.keys(qty))delete qty[k];show(r.data)};
  recent();
 }
 async function recent(){const r=await sb.from('pay_requests').select('id,code,amount_cents,note,status,expires_at,created_at').eq('vendor_id',v.id).order('created_at',{ascending:false}).limit(15);const el=$('#recent');if(!el)return;
  if(r.error){el.innerHTML='<div class="notice err">'+esc(fixErr(r.error))+'</div>';return}
  const st=x=>x.status==='open'&&new Date(x.expires_at)<=new Date()?'expired':x.status;
  el.innerHTML=(r.data||[]).length?'<div class="hist">'+r.data.map(x=>`<div class="hrow ${st(x)==='paid'?'in':''}"><div class="hic" aria-hidden="true">${st(x)==='paid'?'✓':'·'}</div><div class="hmid"><b>${esc(x.code)}</b> <span class="pp pp-${st(x)==='paid'?'paid':'unpaid'}">${esc(st(x))}</span><small>${esc(fdate(x.created_at))}${x.note?' · '+esc(x.note):''}</small></div><div class="hamt">${cents(x.amount_cents)}</div></div>`).join('')+'</div>':'<p class="muted">No charges yet.</p>'}
 function show(ch){
  active=ch;const url=base('wallet.html')+'?pay='+encodeURIComponent(ch.code);
  R.innerHTML=TESTBANNER+`<div class="wcard chargecard" id="cc"><span class="kicker">Charge ready</span><div class="bigbal">${cents(ch.amount_cents)}</div>
   <div class="qrbox">${qrSvg(url,200)}</div><div class="wcode"><span class="muted">Charge code</span><code>${esc(ch.code)}</code><button class="btn ghost sm" id="ccpy" type="button">Copy</button></div>
   <p id="cstat" class="cstat" role="status">Waiting for the customer to pay… <span id="cleft"></span></p>
   <p class="muted">The customer opens <b>Wallet</b>, enters this code (or scans the QR) and confirms. Test money only.</p>
   <button class="btn ghost" id="ccancel" type="button">Cancel charge</button> <button class="btn alt" id="cnew" type="button" hidden>New charge</button></div>`;
  $('#ccpy').onclick=e=>copy(ch.code,e.target);$('#cnew').onclick=()=>form();
  $('#ccancel').onclick=async()=>{const r=await rpc(sb,'cancel_charge',{p_charge_id:ch.id});clearInterval(timer);if(r.error){$('#cstat').textContent=fixErr(r.error);return}form('Charge '+ch.code+' cancelled.')};
  const tick=async()=>{const left=Math.max(0,Math.round((new Date(ch.expires_at)-Date.now())/1000));const cl=$('#cleft');if(!cl){clearInterval(timer);return}
   cl.textContent='(expires in '+Math.floor(left/60)+':'+String(left%60).padStart(2,'0')+')';
   const r=await sb.from('pay_requests').select('status').eq('id',ch.id).maybeSingle();const s=r.data&&r.data.status;
   if(s==='paid'){clearInterval(timer);$('#cc').classList.add('paid');$('#cstat').innerHTML='<b>PAID ✓</b> '+cents(ch.amount_cents)+' received in your business wallet (test money).';$('#ccancel').hidden=true;$('#cnew').hidden=false}
   else if(s==='cancelled'||left<=0){clearInterval(timer);$('#cstat').textContent=s==='cancelled'?'This charge was cancelled.':'This charge expired. Create a new one.';$('#ccancel').hidden=true;$('#cnew').hidden=false}};
  timer=setInterval(tick,3000);tick()}
 form();
}
};
const k=document.body.dataset.page;
Promise.resolve(pages[k]()).catch(e=>{console.error(e);main().insertAdjacentHTML('beforeend','<div class="notice err">Something went wrong. Please refresh.</div>')});
})();
