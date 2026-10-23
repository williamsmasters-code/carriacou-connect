// v1.18 Shop gift card tracker (record keeping only). Needs supabase/shop_gift_cards.sql.
// The shop sells its OWN gift cards; Carriacou Connect only keeps the record. Plus+ and higher. Admin: read-only view.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,RANK={lite:1,standard:2,plus:3,pro:4,enterprise:5};
const ec=c=>'EC$'+(Number(c||0)/100).toLocaleString('en',{minimumFractionDigits:2,maximumFractionDigits:2});
const cents=v=>{const n=Math.round(parseFloat(String(v||'').replace(/[^0-9.]/g,''))*100);return Number.isFinite(n)?n:NaN};
const fd=d=>d?CC.fdate(d):'';
const ST={active:'Active',used:'Used up',void:'Void'};
const DISC='<p class="notice sgc-disc" role="note"><b>Your shop alone is responsible for these gift cards and the money paid for them.</b> Carriacou Connect only keeps this record for you. We do not sell, hold, pay out or guarantee these cards, and we are not part of any refund. Honour, refund or replace cards under your own policy.</p>';
const nice=e=>{const m=(e&&e.message)||String(e||'');
 if(/Could not find|schema cache|does not exist/i.test(m))return 'The gift card tracker is not switched on yet (shop_gift_cards.sql has not been run in Supabase).';
 return m.replace(/^.*?ERROR:\s*/,'')};
const stat=c=>c.status==='active'&&c.expired?'<span class="badge sgc-exp">Expired</span>':'<span class="badge sgc-'+esc(c.status)+'">'+esc(ST[c.status]||c.status)+'</span>';
const rows=cards=>'<div class="tablewrap"><table class="stack sgc-tab"><thead><tr><th>Code</th><th>Status</th><th>Balance</th><th>Initial</th><th>Issued</th><th>Buyer</th><th>Expires</th><th></th></tr></thead><tbody>'+
 cards.map(c=>'<tr><td data-l="Code"><code>'+esc(c.code)+'</code></td><td data-l="Status">'+stat(c)+'</td><td data-l="Balance"><b>'+ec(c.balance_cents)+'</b></td><td data-l="Initial">'+ec(c.initial_cents)+'</td><td data-l="Issued">'+esc(fd(c.issued_at))+'</td><td data-l="Buyer">'+esc(c.buyer_name||'–')+'</td><td data-l="Expires">'+esc(c.expires_on||'–')+'</td><td data-l=""><button type="button" class="btn ghost sm" data-open="'+esc(c.code)+'">Open</button></td></tr>').join('')+'</tbody></table></div>';
const evlist=ev=>ev.length?'<ul class="auditlist sgc-ev">'+ev.map(e=>'<li><b>'+esc(({issue:'Issued',redeem:'Redeemed',adjust:'Adjusted',void:'Voided'})[e.kind]||e.kind)+'</b>'+(e.code?' <code>'+esc(e.code)+'</code>':'')+(e.amount_cents?' · '+(e.amount_cents<0?'−':'+')+ec(Math.abs(e.amount_cents)):'')+' · balance '+ec(e.balance_after)+(e.note?' · '+esc(e.note):'')+'<small>'+esc(fd(e.at))+(e.by?' · '+esc(e.by):'')+'</small></li>').join('')+'</ul>':'<p class="muted">Nothing yet.</p>';
function csv(cards){const q=v=>{v=v==null?'':String(v);return /[",\n]/.test(v)||/^[=+\-@]/.test(v)?'"'+(/^[=+\-@]/.test(v)?"'":'')+v.replace(/"/g,'""')+'"':v};
 const h=['code','status','balance_xcd','initial_xcd','issued_at','buyer_name','buyer_contact','expires_on','note','void_reason'];
 const t=[h.join(',')].concat(cards.map(c=>[c.code,c.status==='active'&&c.expired?'expired':c.status,(c.balance_cents/100).toFixed(2),(c.initial_cents/100).toFixed(2),c.issued_at,c.buyer_name,c.buyer_contact,c.expires_on,c.note,c.void_reason].map(q).join(','))).join('\r\n');
 const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['\ufeff'+t],{type:'text/csv'}));a.download='gift-cards-'+new Date().toISOString().slice(0,10)+'.csv';document.body.appendChild(a);a.click();setTimeout(()=>{URL.revokeObjectURL(a.href);a.remove()},500)}

function locked(el,o){
 el.innerHTML='<section class="sgc sgc-locked"><h3>Shop gift cards <span class="badge t-Plus">Plus+ and higher</span></h3>'+
 '<div class="notice lockedmsg" role="note">🔒 Track the gift cards your shop sells: issue codes, check balances, redeem part or all of a card, void lost cards and export a CSV. This is part of the <b>Plus+</b> plan (and Pro and Enterprise). '+(o.isOwner?'<button class="btn" type="button" data-lk="1">Upgrade to use it</button>':'Ask the business owner to upgrade the plan.')+'</div>'+
 '<div class="lk-grid"><div class="aa-lk" aria-disabled="true"><h4>Issue cards</h4><p>A unique code for every card you sell.</p><span class="lk-lock" aria-hidden="true">🔒</span></div><div class="aa-lk" aria-disabled="true"><h4>Redeem at the till</h4><p>Take part or all of the balance.</p><span class="lk-lock" aria-hidden="true">🔒</span></div><div class="aa-lk" aria-disabled="true"><h4>History and CSV</h4><p>Every redemption and change, logged.</p><span class="lk-lock" aria-hidden="true">🔒</span></div></div></section>';
 const b=el.querySelector('[data-lk]');if(b)b.onclick=()=>o.onUpgrade?o.onUpgrade():(location.href='tiers.html');
}

async function mount(el,o){
 const {sb,vendor}=o,tier=(o.plan&&o.plan.tier)||vendor.tier,role=(o.me&&o.me.role)||'staff',manage=role==='admin'||role==='subadmin',owner=role==='admin';
 el.innerHTML='<p class="muted">Loading gift cards…</p>';
 const r=await sb.rpc('sgc_list',{p_vendor:vendor.id,p_status:null,p_limit:500});
 if(r.error){if((RANK[tier]||1)<3||/Plus\+ plan/.test(r.error.message))return locked(el,o);el.innerHTML='<div class="notice err">'+esc(nice(r.error))+'</div>';return}
 const d=r.data,tierOk=d.tier_ok!==false;let filter='all',q='';
 const say=(m,ok)=>{const e=el.querySelector('#sgc-msg');e.className='notice '+(ok?'ok':'err');e.textContent=m||'';e.hidden=!m;if(m)e.scrollIntoView({block:'nearest'})};
 el.innerHTML='<section class="sgc"><div class="sgc-head"><h3>Shop gift cards</h3><div class="sgc-sum"><div><b>'+d.summary.active+'</b><span>active cards</span></div><div><b>'+ec(d.summary.outstanding_cents)+'</b><span>still to honour</span></div><div><b>'+d.summary.count+'</b><span>cards issued</span></div></div></div>'+DISC+
 (tierOk?'':'<div class="notice" role="note">Your plan is below Plus+. You can still look up, redeem and void your existing cards, but you cannot issue new ones. <a href="tiers.html">See plans</a></div>')+
 '<div id="sgc-msg" class="notice" hidden role="status"></div><div class="sgc-grid">'+
 '<div class="sgc-col"><section class="formcard"><h4>Look up or redeem a card</h4><form id="sgc-lf" novalidate><label>Card code<input id="sgc-code" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="ABCD-EFGH-JKLM" maxlength="20" required></label><button class="btn" type="submit">Look up</button></form><div id="sgc-card"></div></section>'+
 (manage&&tierOk?'<section class="formcard"><h4>Issue a new card</h4><form id="sgc-if" novalidate><label>Value (EC$)<input id="sgc-val" type="number" min="1" max="100000" step="0.01" inputmode="decimal" required placeholder="e.g. 50"></label><label>Buyer name <small>(optional)</small><input id="sgc-bn" maxlength="120"></label><label>Buyer phone or email <small>(optional)</small><input id="sgc-bc" maxlength="160"></label><label>Expiry date <small>(optional)</small><input id="sgc-exp" type="date"></label><label>Note <small>(optional, e.g. receipt number)</small><input id="sgc-note" maxlength="300"></label><button class="btn" type="submit">Issue card</button></form><p class="muted small">The code is made by the system and is unique in your shop. Record here only cards your shop has sold or given.</p></section>':'')+
 (owner&&tierOk?'<section class="formcard"><h4>Balance check on your shop page</h4><label class="chk"><input type="checkbox" id="sgc-pub"'+(d.public_check?' checked':'')+'> Let customers check their balance by code on your shop page</label><p class="muted small">They see only the balance, status and expiry. Nobody can spend a card online.</p></section>':'')+
 '</div><div class="sgc-col sgc-wide"><div class="sgc-tools"><label class="sr" for="sgc-q">Search cards</label><input id="sgc-q" type="search" placeholder="Search code or buyer" autocomplete="off"><select id="sgc-f" aria-label="Filter"><option value="all">All cards</option><option value="active">Active</option><option value="used">Used up</option><option value="void">Void</option></select><button class="btn ghost" type="button" id="sgc-csv">Export CSV</button></div><div id="sgc-list"></div><h4>Recent history</h4>'+evlist(d.events.slice(0,30))+'</div></div></section>';
 const g=s=>el.querySelector(s);
 const list=()=>{const t=q.toLowerCase();const cs=d.cards.filter(c=>(filter==='all'||c.status===filter)&&(!t||c.code.toLowerCase().includes(t)||(c.buyer_name||'').toLowerCase().includes(t)));
  g('#sgc-list').innerHTML=cs.length?rows(cs):'<p class="muted">No cards'+(d.cards.length?' match.':' yet.')+'</p>';CC.stackTables&&CC.stackTables();
  el.querySelectorAll('[data-open]').forEach(b=>b.onclick=()=>{g('#sgc-code').value=b.dataset.open;look(b.dataset.open);g('#sgc-lf').scrollIntoView({block:'start'})})};
 const reload=m=>mount(el,o).then(()=>{if(m){const e=el.querySelector('#sgc-msg');e.className='notice ok';e.textContent=m;e.hidden=false}});
 async function look(code){const box=g('#sgc-card');box.innerHTML='<p class="muted">Looking up…</p>';const x=await sb.rpc('sgc_lookup',{p_vendor:vendor.id,p_code:code});
  if(x.error){box.innerHTML='<div class="notice err">'+esc(nice(x.error))+'</div>';return}const c=x.data,live=c.status==='active'&&!c.expired;
  box.innerHTML='<div class="sgc-cardv"><p class="sgc-code"><code>'+esc(c.code)+'</code> '+stat(c)+'</p><p class="sgc-bal">'+ec(c.balance_cents)+' <small>of '+ec(c.initial_cents)+'</small></p><p class="muted">Issued '+esc(fd(c.issued_at))+(c.buyer_name?' · '+esc(c.buyer_name):'')+(c.buyer_contact?' · '+esc(c.buyer_contact):'')+(c.expires_on?' · expires '+esc(c.expires_on):'')+(c.void_reason?' · void: '+esc(c.void_reason):'')+'</p>'+
  (live?'<form id="sgc-rf" class="sgc-row" novalidate><label>Redeem amount (EC$)<input id="sgc-ra" type="number" min="0.01" step="0.01" inputmode="decimal" max="'+(c.balance_cents/100)+'"></label><label>Note <small>(optional)</small><input id="sgc-rn" maxlength="300" placeholder="e.g. order or receipt number"></label><div class="sgc-btns"><button class="btn" type="submit">Redeem</button><button class="btn ghost" type="button" id="sgc-all">Use full balance</button></div></form>':'')+
  (manage&&c.status!=='void'?'<details class="sgc-more"><summary>Correct or void this card</summary><form id="sgc-af" class="sgc-row" novalidate><label>Adjust balance by (EC$, use − to lower)<input id="sgc-ad" type="number" step="0.01" inputmode="decimal"></label><label>Reason (required)<input id="sgc-ar" maxlength="300"></label><div class="sgc-btns"><button class="btn ghost" type="submit">Save adjustment</button><button class="btn danger" type="button" id="sgc-void">Void card</button></div></form></details>':'')+
  '<h4>Card history</h4>'+evlist(c.events)+'</div>';
  const rf=g('#sgc-rf');if(rf){const red=async a=>{if(!(a>0)){say('Enter an amount above zero.');return}if(a>c.balance_cents){say('That is more than the balance ('+ec(c.balance_cents)+').');return}
    if(!confirm('Redeem '+ec(a)+' from card '+c.code+'?'))return;const y=await sb.rpc('sgc_redeem',{p_vendor:vendor.id,p_code:c.code,p_amount_cents:a,p_note:g('#sgc-rn').value.trim()||null});
    if(y.error){say(nice(y.error));return}reload('Redeemed '+ec(a)+'. New balance '+ec(y.data.balance_cents)+'.').then(()=>{g('#sgc-code').value=c.code;look(c.code)})};
   rf.onsubmit=e=>{e.preventDefault();red(cents(g('#sgc-ra').value))};g('#sgc-all').onclick=()=>red(c.balance_cents)}
  const af=g('#sgc-af');if(af){af.onsubmit=async e=>{e.preventDefault();const raw=g('#sgc-ad').value,dv=Math.round(parseFloat(raw)*100),rs=g('#sgc-ar').value.trim();if(!dv){say('Enter an adjustment other than zero.');return}if(rs.length<3){say('Give a reason (at least 3 characters).');return}
    const y=await sb.rpc('sgc_adjust',{p_vendor:vendor.id,p_code:c.code,p_delta_cents:dv,p_reason:rs});if(y.error){say(nice(y.error));return}reload('Balance adjusted to '+ec(y.data.balance_cents)+'.').then(()=>{g('#sgc-code').value=c.code;look(c.code)})};
   g('#sgc-void').onclick=async()=>{const rs=g('#sgc-ar').value.trim();if(rs.length<3){say('Type the reason for voiding first (at least 3 characters).');return}if(!confirm('Void card '+c.code+'? It can no longer be redeemed. This cannot be undone.'))return;
    const y=await sb.rpc('sgc_void',{p_vendor:vendor.id,p_code:c.code,p_reason:rs});if(y.error){say(nice(y.error));return}reload('Card '+c.code+' is now void.')}}
 }
 g('#sgc-lf').onsubmit=e=>{e.preventDefault();const v=g('#sgc-code').value.trim();if(!v){say('Enter a card code.');return}look(v)};
 const iF=g('#sgc-if');if(iF)iF.onsubmit=async e=>{e.preventDefault();const v=cents(g('#sgc-val').value);if(!(v>=100&&v<=10000000)){say('Enter a value from EC$1 to EC$100,000.');return}
  const y=await sb.rpc('sgc_issue',{p_vendor:vendor.id,p_value_cents:v,p_buyer_name:g('#sgc-bn').value.trim()||null,p_buyer_contact:g('#sgc-bc').value.trim()||null,p_expires_on:g('#sgc-exp').value||null,p_note:g('#sgc-note').value.trim()||null});
  if(y.error){say(nice(y.error));return}reload('Card issued: '+y.data.code+' for '+ec(y.data.initial_cents)+'. Write this code on the card or receipt.').then(()=>{g('#sgc-code').value=y.data.code;look(y.data.code)})};
 const pub=g('#sgc-pub');if(pub)pub.onchange=async()=>{const y=await sb.rpc('sgc_set_public_check',{p_vendor:vendor.id,p_on:pub.checked});if(y.error){pub.checked=!pub.checked;say(nice(y.error));return}say(pub.checked?'Customers can now check their balance on your shop page.':'The balance check is off.',true)};
 g('#sgc-q').oninput=e=>{q=e.target.value;list()};g('#sgc-f').onchange=e=>{filter=e.target.value;list()};g('#sgc-csv').onclick=()=>csv(d.cards);
 list();
}

// platform admin: read-only
async function adminMount(el,sb,v){
 el.innerHTML='<h3>Shop gift cards (read-only)</h3><p class="muted">Loading…</p>';
 const r=await sb.rpc('sgc_list',{p_vendor:v.id,p_status:null,p_limit:500});
 if(r.error){el.innerHTML='<h3>Shop gift cards (read-only)</h3><p class="muted">'+esc(/Plus\+ plan/.test(r.error.message)?'This shop is below Plus+ and has no gift cards.':nice(r.error))+'</p>';return}
 const d=r.data;el.innerHTML='<h3>Shop gift cards (read-only)</h3><p class="muted">The shop sells and is responsible for these cards. Admins can view them but cannot issue, redeem or void.</p><p>'+d.summary.count+' issued · '+d.summary.active+' active · '+ec(d.summary.outstanding_cents)+' outstanding'+(d.public_check?' · public balance check on':'')+'</p>'+(d.cards.length?rows(d.cards.slice(0,50)).replace(/<td data-l=""><button[^<]*<\/button><\/td>/g,'<td data-l=""></td>'):'')+'<details><summary>History</summary>'+evlist(d.events.slice(0,50))+'</details>';
 CC.stackTables&&CC.stackTables();
}

// shop page: optional customer balance check (only shown when the RPC says it is on)
function publicMount(el,sb,vendorId){
 el.innerHTML='<section class="sgc-pubbox formcard"><h3>Check a gift card balance</h3><form id="sgcp-f" class="sgc-row" novalidate><label>Card code<input id="sgcp-c" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="20" placeholder="ABCD-EFGH-JKLM"></label><button class="btn" type="submit">Check balance</button></form><div id="sgcp-r" role="status"></div><p class="muted small">This card is sold and honoured by the shop. Carriacou Connect does not hold its value.</p></section>';
 el.querySelector('#sgcp-f').onsubmit=async e=>{e.preventDefault();const out=el.querySelector('#sgcp-r');const x=await sb.rpc('sgc_public_balance',{p_vendor:vendorId,p_code:el.querySelector('#sgcp-c').value});
  if(x.error){out.innerHTML='<div class="notice err">'+esc(nice(x.error))+'</div>';return}const c=x.data;
  out.innerHTML='<div class="notice ok"><b>'+ec(c.balance_cents)+'</b> · '+esc(c.status==='active'&&c.expired?'Expired':ST[c.status]||c.status)+(c.expires_on?' · expires '+esc(c.expires_on):'')+'</div>'};
}
async function maybePublic(el,sb,vendorId){try{const x=await sb.rpc('sgc_public_balance',{p_vendor:vendorId,p_code:'probe'});if(x.error&&/12-character/.test(x.error.message))publicMount(el,sb,vendorId)}catch(e){}}
CC.shopGiftCards={mount,adminMount,publicMount,maybePublic};
})();
