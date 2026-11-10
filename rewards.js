// v1.16 Rewards (CC Points), Points Store and vendor CC Cash (was "Platform Funds"). See supabase/wallet_repurpose.sql + financial_v2.sql (v1.20).
// CC Points are rewards, not money, earned only on platform orders (card online, or pay on pickup once collected).
// CC Cash is for businesses only, and only pays for Carriacou Connect services and goods (plan, fees, ads, setup, custom layout, company goods). TEST MODE.
(function(){
const C=window.CC,{esc,cents,fdate,uuid}=C;const $=s=>document.querySelector(s);const main=()=>document.querySelector('main');
const pts=n=>Number(n||0).toLocaleString('en-US');
const NOTON='Rewards and CC Cash are not switched on yet: supabase/wallet_repurpose.sql has not been run in Supabase.';
const fixErr=e=>{const m=(e&&e.message)||'Something went wrong.';return /schema cache|does not exist|Could not find the function/i.test(m)?NOTON:m};
const fday=d=>{try{return new Intl.DateTimeFormat('en-GB',{timeZone:'America/Grenada',day:'numeric',month:'short',year:'numeric'}).format(new Date(d))}catch(e){return d}};
const TL=C.TIER_LABEL||{};
async function boot(need){
 if(!C.configured){main().insertAdjacentHTML('beforeend','<div class="notice">Accounts are not switched on in this sample preview.</div>');return null}
 const sb=await C.client();if(!sb)return null;const user=await C.getUser();
 if(!user&&need!==false){location.href='login.html?next='+encodeURIComponent(location.pathname.split('/').pop()+location.search.replace(/[^a-z0-9_=&.-]/gi,''));return null}
 return {sb,user};
}
const KIND={earn:'Earned',reverse:'Reversed (order cancelled/refunded)',redeem:'Gift card',expire:'Expired',adjust:'Adjustment',refund:'Gift card returned as points'};
const NOEARN='In-person and POS sales, payments recorded by the shop outside an online order, transfers, sign-ups and reviews do not earn points.';
const TERMS=`<details class="rw-terms"><summary>CC Points terms (summary)</summary><ul>
 <li>CC Points are a free loyalty reward from Carriacou Connect. They are <b>not money</b>, have no cash value and cannot be bought, sold, transferred to another person or cashed out.</li>
 <li>You earn 1 CC Point for every EC$1 <b>only on orders you place on Carriacou Connect</b>: paid online by credit/debit card (once the payment goes through), or pay on pickup once the shop marks the order completed (collected).</li>
 <li>${NOEARN} A shop's own owner and team do not earn points on their own shop. Points for an order that is later cancelled or refunded are taken back.</li>
 <li>Points cannot be used to pay shops. A Carriacou Connect shop where you can spend points on Carriacou Connect goods and services is coming soon. Shop gift cards bought with points earlier have been turned back into points.</li>
 <li>Your whole balance expires after 1 year with no points earned.</li>
 <li>Carriacou Connect may change or end the programme with notice. Full terms will be published before launch.</li></ul></details>`;

const pages={
async rewards(){
 const c=await boot();if(!c)return;const {sb}=c;const R=$('#pay');
 const [p,g]=await Promise.all([sb.rpc('my_points'),sb.rpc('my_gift_cards')]);
 if(p.error){R.innerHTML='<div class="notice err">'+esc(fixErr(p.error))+'</div>';return}
 const d=p.data,cards=g.error?[]:(g.data||[]);
 R.innerHTML=`<div class="walletgrid">
  <section class="wcard rw-bal"><span class="kicker">CC Points</span><div class="bigbal rw-pts" id="ptsbal">${pts(d.balance)} <small>points</small></div>
   <small>Rewards, not money · no cash value</small>
   <p class="rw-exp">${d.expires_at?`Earn points again before <b>${esc(fday(d.expires_at))}</b> to keep them.`:'Complete an order to start earning.'}</p>
   <p class="muted"><small>Spending points: the Carriacou Connect shop is coming soon. <a href="store.html">Learn more</a></small></p></section>
  <section class="wcard rw-how"><h3>How it works</h3><ol class="rw-steps"><li><b>Order</b> from any shop on Carriacou Connect.</li><li><b>Pay online by card</b> or <b>pay on pickup</b>.</li><li><b>Earn ${esc(d.points_per_ec)} point per EC$1</b> when your card payment goes through, or when the shop marks your pickup order completed.</li></ol><p class="rw-noearn"><b>What does not earn points:</b> ${esc(NOEARN)}</p><p class="muted"><small>${esc(C.POINTS_NOTE)}</small></p></section>
 </div>
 ${cards.length?`<h2>Earlier gift cards</h2>`:''}
 ${cards.length?`<div class="gcgrid">${cards.map(x=>`<article class="gc gc-${esc(x.status)}"><span class="gc-shop">${esc(x.vendor)}</span><b class="gc-val">${cents(x.balance_cents)}<small> of ${cents(x.value_cents)}</small></b><code>${esc(x.code)}</code><small>${x.status==='refunded'?'Returned to you as points':x.status==='active'?'Being returned as points':esc(x.status)}</small></article>`).join('')}</div>`:''}
 <h2>Points history</h2>
 <div class="hist">${(d.history||[]).length?d.history.map(h=>`<div class="hrow ${h.delta>0?'in':'out'}"><div class="hic" aria-hidden="true">${h.delta>0?'★':'↑'}</div><div class="hmid"><b>${esc(KIND[h.kind]||h.kind)}${h.order_number?' · '+esc(h.order_number):''}</b><small>${esc(fdate(h.created_at))}${h.note?' · '+esc(h.note):''}</small></div><div class="hamt">${h.delta>0?'+':''}${pts(h.delta)} pts</div></div>`).join(''):'<div class="empty"><div class="empty-ic" aria-hidden="true">⭐</div><h3>No points yet</h3><p>Orders paid online by card, or pickup orders once completed, earn CC Points.</p></div>'}</div>
 ${TERMS}`;
},
async store(){
 // v1.20: shop gift cards for points are closed (points cannot pay shops). Spending points moves to Carriacou Connect's own shop, coming soon.
 const c=await boot(false);if(!c)return;const {sb,user}=c;const R=$('#pay');
 const p=user?await sb.rpc('my_points'):{data:null};const bal=p&&p.data?p.data.balance:null;
 R.innerHTML=`<div class="ps-layout"><aside class="ps-side"><p class="lead">Your <b>CC Points</b> will be spent in the <b>Carriacou Connect shop</b>: Carriacou Connect's own goods and services.</p>
 ${user?`<div class="ps-bal"><span>Your balance</span><b id="psbal">${pts(bal)} points</b><a href="rewards.html">Rewards →</a></div>`:'<div class="notice"><a href="login.html?next=store.html">Sign in</a> to see your points.</div>'}
 <p class="muted ps-tiers"><small>${esc(C.POINTS_NOTE)}</small></p>${TERMS}</aside>
 <div class="ps-main"><div class="psgrid"><article class="psc ps-soon"><div class="psc-h"><span class="psc-ic" aria-hidden="true">C</span><div><b>Carriacou Connect shop</b><span class="badge">Coming soon</span></div></div>
 <p>Spend points on Carriacou Connect goods and services. Not open yet: keep earning and your points will be ready.</p></article></div>
 <div class="notice"><b>Points cannot be used to pay shops.</b> Shops are paid on pickup or online by credit/debit card. Shop gift cards bought with points earlier have been turned back into points.</div></div></div>`;
},
async funds(){
 const c=await boot();if(!c)return;const {sb}=c;const R=$('#pay');
 let acc=[];try{const r=await sb.rpc('my_vendor_access');if(!r.error&&Array.isArray(r.data))acc=r.data.filter(a=>a.is_owner||(a.perms||[]).includes('refunds'))}catch(e){}
 if(!acc.length){R.innerHTML='<div class="notice"><b>CC Cash is only for vendors</b> (business owners and sub-admins), to pay for Carriacou Connect services. Customers pay shops on pickup or online by card. <a href="rewards.html">See your Rewards</a>.</div>';return}
 const q=new URLSearchParams(location.search);let vid=(acc.find(a=>a.vendor_id===q.get('v'))||acc[0]).vendor_id,key=uuid();
 const KL={topup_card_test:'Card top-up (test)',topup_office:'Office top-up',fees:'Platform fees',fee_refund:'Fee refund',subscription:'Subscription',featured:'Featured listing / ads',setup:'Setup / photo service',layout:'Custom layout service',cc_goods:'Carriacou Connect goods',adjustment:'Adjustment',exit_payout:'Exit refund'};
 const draw=async note=>{
  const r=await sb.rpc('vendor_funds',{p_vendor:vid});if(r.error){R.innerHTML='<div class="notice err">'+esc(fixErr(r.error))+'</div>';return}
  const F=r.data,a=acc.find(x=>x.vendor_id===vid),ex=F.exit,FL=await C.flags();const canPlan=a.is_owner||(a.perms||[]).includes('plan');
  let Q=null;try{const qr=await sb.rpc('vendor_subscription_quote',{p_vendor:vid,p_tier:null});if(!qr.error)Q=qr.data}catch(e){}
  const tiersUp=Q?(C.TIERS||[]).filter(t=>(C.TIERS||[]).findIndex(x=>x.k===t.k)>=(C.TIERS||[]).findIndex(x=>x.k===Q.current_tier)&&t.k!=='lite'):[];
  R.innerHTML=`${F.test_mode?C.TESTBANNER:''}
  ${acc.length>1?`<div class="dtabs wtabs">${acc.map(x=>`<button class="${x.vendor_id===vid?'on':''}" data-vid="${esc(x.vendor_id)}">${esc(x.vendor_name)}</button>`).join('')}</div>`:''}
  <div class="walletgrid">
   <section class="wcard wbal fu-bal"><span class="kicker">${esc(a.vendor_name)} · CC Cash</span><div class="bigbal" id="fbal">${cents(F.balance_cents)}</div><small>For vendors only: pays for Carriacou Connect services and goods${F.test_mode?' · TEST play money':''}</small>
    <div class="fu-mini">${Number(F.sub_credit_cents)?`<div><span>Subscription credit</span><b id="fsc">${cents(F.sub_credit_cents)}</b><small>from earlier gift cards, used on your plan</small></div>`:''}<div><span>Fees to bill</span><b id="fub">${cents(F.unbilled_cents)}</b><small>next pay cycle ${esc(fday(F.next_cycle+'T16:00:00Z'))}</small></div></div></section>
   <form class="wcard" id="ftop" novalidate><h3>Top up</h3><p class="muted">By card (test mode only, no real money) or at the Carriacou Connect office (cash or card, recorded by staff with a receipt).</p>
    <div class="chips">${[2500,5000,10000,25000].map(v=>`<button type="button" class="chip" data-a="${v}">${cents(v)}</button>`).join('')}</div>
    <label>Amount (EC$)<input id="tamt" inputmode="decimal" placeholder="50.00" autocomplete="off"></label><button class="btn alt" id="tgo">Top up by card (test)</button></form>
  </div>
  <div id="fmsg" class="notice${note?' ok':''}" ${note?'':'hidden'} role="status">${esc(note||'')}</div>
  ${Q?`<section class="wcard fu-plan" id="planpay"><h3>📅 Pay for your plan with CC Cash</h3>
   <p>You are on the <b>${esc(Q.current_label)}</b> plan${Q.paid_through?', paid through <b>'+esc(fday(Q.paid_through+'T16:00:00Z'))+'</b>':''}. Renew it or upgrade, paid straight from your CC Cash. ${Q.test_mode?'<b>Test mode:</b> play money only.':''}</p>
   ${canPlan&&tiersUp.length?`<form id="ppf" class="ppform" novalidate><label>Plan<select id="ppt">${tiersUp.map(t=>`<option value="${esc(t.k)}"${t.k===Q.current_tier?' selected':''}>${esc(t.name)}${t.k===Q.current_tier?' (renew)':' (upgrade)'}</option>`).join('')}</select></label>
   <div id="ppq" class="ppq" role="status"></div><button class="btn" id="ppgo" type="submit">Pay with CC Cash</button></form>`:canPlan?'<p class="muted">Your plan is free: nothing to pay.</p>':'<p class="muted"><small>Only the business owner can pay for the plan.</small></p>'}
   <p class="muted"><small>One month at a time. A renewal adds a month after your paid-through date; an upgrade switches your plan straight away and starts a new month today. If your CC Cash is too low the payment is refused and nothing is taken: top up first.</small></p></section>`:''}
  <section class="wcard fu-what"><h3>What CC Cash pays for</h3><p class="muted">CC Cash is for vendors only. It can only be spent on Carriacou Connect's own services and goods, never sent to customers or other shops, and customers cannot pay you with it.</p><ul class="fu-list"><li>📅 Your plan subscription: renewals and upgrades</li><li>🧾 Per-order platform fees: <b>${esc(Number(F.fee_card_pct))}%</b> on card orders paid online, <b>${esc(Number(F.fee_direct_pct))}%</b> on pay on pickup</li><li>⭐ Featured listings and ads</li><li>📸 Setup and product photo service</li><li>🎨 Custom shop layout service</li><li>🛍️ Carriacou Connect goods</li></ul>
   <p class="muted"><small>Fees are charged when an order is placed and billed at the end of the pay cycle. A cancelled or refunded order gets its fee back${Number(F.fee_refund_pct)<100?' ('+esc(Number(F.fee_refund_pct))+'%)':''}. If CC Cash is short, the rest of a fee bill is invoiced. CC Cash cannot be sent to other users or cashed out; unused CC Cash is refunded only when you close your shop.</small></p></section>
  <h2>Fee lines</h2>
  <div class="tablewrap"><table class="fu-fees stack"><thead><tr><th>Order</th><th>Paid by</th><th>Order total</th><th>Rate</th><th>Fee</th><th>Status</th></tr></thead><tbody>${(F.fees||[]).length?F.fees.map(f=>`<tr class="${f.status}"><td>${esc(f.order_number)}<small>${esc(fdate(f.charged_at))}</small></td><td>${f.fee_class==='card'?'Card (online)':'Pay on pickup'}</td><td>${cents(f.base_cents)}</td><td>${esc(Number(f.rate_pct))}%</td><td><b>${cents(f.fee_cents)}</b></td><td>${f.status==='refunded'?'<span class="pp pp-ref">Refunded '+cents(f.refund_cents)+'</span>':f.billed_at?'<span class="pp pp-paid">Billed</span>':'<span class="pp pp-unpaid">To bill</span>'}</td></tr>`).join(''):'<tr><td colspan=6 class="muted">No orders yet.</td></tr>'}</tbody></table></div>
  <div class="fu-cols"><div>
  <h2>Bills</h2>
  ${(F.bills||[]).length?`<div class="hist">${F.bills.map(b=>`<div class="hrow out"><div class="hic" aria-hidden="true">🧾</div><div class="hmid"><b>${esc(KL[b.kind]||b.kind)}${b.note?' · '+esc(b.note):''}</b><small>${esc(fdate(b.created_at))} · credit ${cents(b.from_sub_credit_cents)} · funds ${cents(b.from_funds_cents)}${Number(b.invoice_cents)>0?' · <b class="fu-inv">invoiced '+cents(b.invoice_cents)+'</b>':''}</small></div><div class="hamt">${cents(b.total_cents)}</div></div>`).join('')}</div>`:'<p class="muted">No bills yet.</p>'}
  </div><div>
  <h2>CC Cash history</h2>
  <div class="hist">${(F.ledger||[]).length?F.ledger.map(l=>`<div class="hrow ${l.amount_cents>0?'in':'out'}"><div class="hic" aria-hidden="true">${l.amount_cents>0?'↓':'↑'}</div><div class="hmid"><b>${esc(KL[l.kind]||l.kind)}</b><small>${esc(fdate(l.created_at))}${l.note?' · '+esc(l.note):''}</small></div><div class="hamt">${l.amount_cents>0?'+':'-'}${cents(Math.abs(l.amount_cents))}</div></div>`).join(''):'<p class="muted">No top-ups or charges yet.</p>'}</div>
  </div></div>
  <div class="fu-cols fu-cols2">
  <section class="wcard fu-exit"><h3>Closing your shop</h3>${ex&&['pending','confirmed'].includes(ex.status)?`<p><b>Refund request ${esc(ex.status)}</b> (${cents(ex.funds_cents)} funds + ${cents(ex.sub_credit_cents)} subscription credit). ${ex.status==='confirmed'?'Confirmed by the manager; paid in the next pay cycle':'Waiting for the platform manager to confirm'} (${esc(fday(ex.scheduled_for+'T16:00:00Z'))}). Test mode: no real money.</p>${ex.status==='pending'&&a.is_owner?'<button class="btn ghost" id="exw" type="button">Withdraw request</button>':''}`:`${ex&&ex.status==='paid'?`<p class="muted">Last exit refund paid ${esc(fdate(ex.paid_at))}.</p>`:''}<p class="muted">If you leave Carriacou Connect, unused CC Cash and any subscription credit are paid to your business in the next pay cycle after the platform manager confirms.</p>${a.is_owner?'<button class="btn ghost" id="exr" type="button">Request exit refund</button>':'<p class="muted"><small>Only the owner can ask.</small></p>'}`}</section></div>`;
  const m=$('#fmsg'),say=(t,ok)=>{m.hidden=!t;m.className='notice '+(ok?'ok':'err');m.textContent=t};
  R.querySelectorAll('[data-vid]').forEach(b=>b.onclick=()=>{vid=b.dataset.vid;draw()});
  R.querySelectorAll('.chip').forEach(b=>b.onclick=()=>{$('#tamt').value=(b.dataset.a/100).toFixed(2)});
  $('#ftop').onsubmit=async e=>{e.preventDefault();const v=C.toCents($('#tamt').value);if(!v||v<1)return say('Enter an amount like 50.00');
   if(v>F.topup_max_cents)return say('Test top-ups are up to '+cents(F.topup_max_cents)+' each.');
   const ok=await C.confirmPay({icon:'🏦',kicker:'CC Cash · TEST',title:'Top up '+a.vendor_name,amountLabel:'Top-up',amountCents:v,rows:[['Balance after',cents(Number(F.balance_cents)+v)],['Paid by','Test card (play money)']],note:'CC Cash can only be spent on Carriacou Connect services and goods.',confirmText:'Top up',busyText:'Adding…',
    onConfirm:async()=>{const x=await sb.rpc('vendor_funds_topup_test',{p_vendor:vid,p_amount_cents:v,p_key:key});return x.error?fixErr(x.error):null}});
   if(ok){key=uuid();await draw('Added '+cents(v)+' of test CC Cash.')}};
  // v1.20: plan renewal / upgrade paid with CC Cash (vendor_pay_subscription checks the balance and takes it in one step on the server)
  const ppf=$('#ppf');if(ppf){const pt=$('#ppt'),pq=$('#ppq'),pg=$('#ppgo');let cur=null,pkey=uuid();
   const showQ=async()=>{pq.textContent='Checking…';const qr=await sb.rpc('vendor_subscription_quote',{p_vendor:vid,p_tier:pt.value});if(qr.error){pq.textContent=fixErr(qr.error);pg.disabled=true;return}cur=qr.data;
    pq.innerHTML=`<div class="oline"><span>${esc(cur.label)} plan, 1 month (${cur.kind==='upgrade'?'upgrade':'renewal'})</span><b>${cents(cur.price_cents)}</b></div><div class="oline"><span>Your CC Cash</span><b>${cents(cur.balance_cents)}</b></div>`+
     (cur.enough?`<div class="oline"><span>CC Cash after</span><b>${cents(cur.balance_cents-cur.price_cents)}</b></div><div class="oline"><span>Paid through</span><b>${esc(fday(cur.new_paid_through+'T16:00:00Z'))}</b></div>`:`<p class="err-text">Not enough CC Cash: top up ${cents(cur.short_cents)} or more first.</p>`)+(cur.price_is_placeholder?'<p class="muted"><small>Plan prices are placeholders while billing is in test mode.</small></p>':'');
    pg.disabled=!cur.enough||!cur.can_pay;pg.textContent=cur.enough?'Pay '+cents(cur.price_cents)+' with CC Cash':'Pay with CC Cash'};
   pt.onchange=()=>{pkey=uuid();showQ()};await showQ();
   ppf.onsubmit=async e=>{e.preventDefault();if(!cur||!cur.enough)return;
    const ok=await C.confirmPay({icon:'📅',kicker:'Plan · CC Cash'+(F.test_mode?' · TEST':''),title:(cur.kind==='upgrade'?'Upgrade to ':'Renew ')+cur.label,amountLabel:'Plan, 1 month',amountCents:cur.price_cents,balanceCents:cur.balance_cents,
     rows:[['CC Cash after',cents(cur.balance_cents-cur.price_cents)],['Paid through',fday(cur.new_paid_through+'T16:00:00Z')],['Paid from','CC Cash']],note:cur.kind==='upgrade'?'Your plan changes as soon as the payment goes through.':'A month is added to your plan.',confirmText:'Pay with CC Cash',busyText:'Paying…',
     onConfirm:async()=>{const x=await sb.rpc('vendor_pay_subscription',{p_vendor:vid,p_tier:cur.tier,p_key:pkey});if(x.error)return fixErr(x.error).replace(/^CC_CASH_LOW:\s*/,'');draw._paid=x.data;return null}});
    if(ok&&draw._paid){const d=draw._paid;draw._paid=null;await draw((d.kind==='upgrade'?'Upgraded to '+d.label:'Renewed '+d.label)+': '+cents(d.paid_cents)+' paid with CC Cash. Paid through '+fday(d.paid_through+'T16:00:00Z')+'.')}}}
  const er=$('#exr');if(er)er.onclick=async()=>{const ok=await C.confirmPay({icon:'🚪',kicker:'Close shop · refund request',title:a.vendor_name,amountLabel:'To refund (estimate)',amountCents:Number(F.balance_cents)+Number(F.sub_credit_cents),
    rows:[['CC Cash',cents(F.balance_cents)],['Subscription credit',cents(F.sub_credit_cents)],['Paid on',fday(F.next_cycle+'T16:00:00Z')+' (next pay cycle)']],note:'The platform manager confirms before anything is paid. Test mode: no real money moves.',
    bodyHtml:'<label class="pd-f">Reason (optional)<input id="exrs" maxlength="300" data-pd-focus></label>',confirmText:'Send request',busyText:'Sending…',
    onConfirm:async w=>{const x=await sb.rpc('vendor_request_exit',{p_vendor:vid,p_reason:w.querySelector('#exrs').value||null});return x.error?fixErr(x.error):null}});
   if(ok)await draw('Request sent to the platform manager.')};
  const ew=$('#exw');if(ew)ew.onclick=async()=>{const x=await sb.rpc('vendor_withdraw_exit',{p_request:ex.id});if(x.error)say(fixErr(x.error));else await draw('Request withdrawn.')};
 };
 await draw();
}
};
const k=document.body.dataset.page;
Promise.resolve(pages[k]&&pages[k]()).catch(e=>{console.error(e);main().insertAdjacentHTML('beforeend','<div class="notice err">Something went wrong. Please refresh.</div>')});
})();
