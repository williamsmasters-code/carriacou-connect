// v1.16 Rewards (CC Points), Points Store and vendor Platform Funds. See supabase/wallet_repurpose.sql.
// CC Points are rewards, not money. Platform Funds are prepaid credit for Carriacou Connect services only (TEST MODE).
(function(){
const C=window.CC,{esc,cents,fdate,uuid}=C;const $=s=>document.querySelector(s);const main=()=>document.querySelector('main');
const pts=n=>Number(n||0).toLocaleString('en-US');
const NOTON='Rewards and Platform Funds are not switched on yet: supabase/wallet_repurpose.sql has not been run in Supabase.';
const fixErr=e=>{const m=(e&&e.message)||'Something went wrong.';return /schema cache|does not exist|Could not find the function/i.test(m)?NOTON:m};
const fday=d=>{try{return new Intl.DateTimeFormat('en-GB',{timeZone:'America/Grenada',day:'numeric',month:'short',year:'numeric'}).format(new Date(d))}catch(e){return d}};
const TL=C.TIER_LABEL||{};
async function boot(need){
 if(!C.configured){main().insertAdjacentHTML('beforeend','<div class="notice">Accounts are not switched on in this sample preview.</div>');return null}
 const sb=await C.client();if(!sb)return null;const user=await C.getUser();
 if(!user&&need!==false){location.href='login.html?next='+encodeURIComponent(location.pathname.split('/').pop()+location.search.replace(/[^a-z0-9_=&.-]/gi,''));return null}
 return {sb,user};
}
const KIND={earn:'Earned',reverse:'Reversed (order cancelled/refunded)',redeem:'Gift card',expire:'Expired',adjust:'Adjustment'};
const TERMS=`<details class="rw-terms"><summary>CC Points terms (summary)</summary><ul>
 <li>CC Points are a free loyalty reward from Carriacou Connect. They are <b>not money</b>, have no cash value and cannot be bought, sold, transferred to another person or cashed out.</li>
 <li>You earn 1 CC Point for every EC$1 of a completed order on the platform. Points for an order that is later cancelled or refunded are taken back.</li>
 <li>Points can only be used in the Points Store for Carriacou Connect gift cards for participating shops. Carriacou Connect sets the card values and points prices. Gift cards work only at that shop, only on Carriacou Connect, and cannot be exchanged for cash.</li>
 <li>Points never expire while you keep earning: your whole balance expires after 1 year with no points earned. Gift cards expire 1 year after they were last used (to be confirmed).</li>
 <li>If a shop leaves the Points Store, gift cards you already hold for that shop still work until used or expired (to be confirmed).</li>
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
   <a class="btn alt" href="store.html">Open the Points Store →</a></section>
  <section class="wcard rw-how"><h3>How it works</h3><ol class="rw-steps"><li><b>Shop</b> anywhere on Carriacou Connect.</li><li><b>Earn ${esc(d.points_per_ec)} point per EC$1</b> when your order is completed.</li><li><b>Swap points</b> for gift cards at participating shops.</li></ol><p class="muted"><small>${esc(C.POINTS_NOTE)}</small></p></section>
 </div>
 <h2>My gift cards</h2>
 ${cards.length?`<div class="gcgrid">${cards.map(x=>`<article class="gc gc-${esc(x.status)}"><span class="gc-shop">${esc(x.vendor)}</span><b class="gc-val">${cents(x.balance_cents)}<small> of ${cents(x.value_cents)}</small></b><code>${esc(x.code)}</code><small>${x.status==='active'?'Use it on an order with this shop · expires '+esc(fday(x.expires_at)):esc(x.status)}</small></article>`).join('')}</div>`:'<p class="muted">No gift cards yet. <a href="store.html">Visit the Points Store</a>.</p>'}
 <h2>Points history</h2>
 <div class="hist">${(d.history||[]).length?d.history.map(h=>`<div class="hrow ${h.delta>0?'in':'out'}"><div class="hic" aria-hidden="true">${h.delta>0?'★':'↑'}</div><div class="hmid"><b>${esc(KIND[h.kind]||h.kind)}${h.order_number?' · '+esc(h.order_number):''}</b><small>${esc(fdate(h.created_at))}${h.note?' · '+esc(h.note):''}</small></div><div class="hamt">${h.delta>0?'+':''}${pts(h.delta)} pts</div></div>`).join(''):'<div class="empty"><div class="empty-ic" aria-hidden="true">⭐</div><h3>No points yet</h3><p>Completed orders earn CC Points.</p></div>'}</div>
 ${TERMS}`;
},
async store(){
 const c=await boot(false);if(!c)return;const {sb,user}=c;const R=$('#pay');
 const draw=async note=>{
  const [s,p]=await Promise.all([sb.rpc('points_store'),user?sb.rpc('my_points'):Promise.resolve({data:null})]);
  if(s.error){R.innerHTML='<div class="notice err">'+esc(fixErr(s.error))+'</div>';return}
  const S=s.data,bal=p.data?p.data.balance:null;
  R.innerHTML=`<div class="ps-layout"><aside class="ps-side"><p class="lead">Swap your <b>CC Points</b> for Carriacou Connect gift cards at participating shops. Carriacou Connect sets the card values and points prices. Gift cards are only for use on Carriacou Connect.</p>
  ${user?`<div class="ps-bal"><span>Your balance</span><b id="psbal">${pts(bal)} points</b><a href="rewards.html">Rewards →</a></div>`:'<div class="notice"><a href="login.html?next=store.html">Sign in</a> to see your points and redeem.</div>'}
  <p class="muted ps-tiers"><small>Shops on the ${esc((S.tiers||[]).map(t=>TL[t]||t).join(', '))} plans can take part. ${esc(C.POINTS_NOTE)}</small></p>${TERMS}</aside>
  <div class="ps-main"><div id="psmsg" class="notice${note?' ok':''}" ${note?'':'hidden'} role="status">${esc(note||'')}</div>
  ${!S.enabled?'<div class="notice">The Points Store is closed right now.</div>':S.shops.length?`<div class="psgrid">${S.shops.map(x=>`<article class="psc"><div class="psc-h"><span class="psc-ic" aria-hidden="true">${esc((x.name||'?').slice(0,1))}</span><div><b>${esc(x.name)}</b><span class="badge t-${esc((TL[x.tier]||x.tier).replace('+',''))}">${esc(TL[x.tier]||x.tier)}</span></div></div>
    <p class="psc-rate">Carriacou Connect gift card${x.cards.length>1?'s':''}</p>
    <div class="psc-vals">${x.cards.map(g=>{const off=g.value_cents>x.remaining_cents;return `<button type="button" class="psv${bal!=null&&bal>=g.points_cost&&!off?' can':''}" data-v="${esc(x.vendor_id)}" data-t="${esc(g.type_id)}" ${off?'disabled title="Monthly limit reached"':''}><b>${cents(g.value_cents)}</b><small>${pts(g.points_cost)} pts</small></button>`}).join('')}</div>
    <small class="muted">${cents(x.remaining_cents)} of gift cards left this month at this shop</small></article>`).join('')}<article class="psc ps-soon"><div class="psc-h"><span class="psc-ic" aria-hidden="true">C</span><div><b>Carriacou Connect shop</b><span class="badge">Coming later</span></div></div><p class="muted">Spend points on Carriacou Connect&#39;s own goods and services. Not open yet.</p></article></div>`:'<div class="empty"><div class="empty-ic" aria-hidden="true">🎁</div><h3>No shops in the store yet</h3><p>No participating shops have gift cards right now. Check back soon.</p></div><div class="psgrid"><article class="psc ps-soon"><div class="psc-h"><span class="psc-ic" aria-hidden="true">C</span><div><b>Carriacou Connect shop</b><span class="badge">Coming later</span></div></div><p class="muted">Spend points on Carriacou Connect&#39;s own goods and services. Not open yet.</p></article></div>'}</div></div>`;
  R.querySelectorAll('[data-v]').forEach(b=>b.onclick=async()=>{if(!user){location.href='login.html?next=store.html';return}
   const shop=S.shops.find(x=>x.vendor_id===b.dataset.v),card=shop.cards.find(g=>g.type_id===b.dataset.t),v=card.value_cents,cost=card.points_cost;
   const r=await C.confirmPay({icon:'🎁',kicker:'Points Store',title:'Gift card for '+shop.name,amountLabel:'Gift card value',amountCents:v,
    rows:[['Costs',pts(cost)+' CC Points'],['Points after',pts((bal||0)-cost)],['Use at',shop.name+' on Carriacou Connect']],note:'Gift cards cannot be exchanged for cash or moved to someone else.',confirmText:'Redeem points',busyText:'Redeeming…',
    onConfirm:async()=>{const x=await sb.rpc('redeem_points_gift_card',{p_vendor:shop.vendor_id,p_type:card.type_id});if(x.error)return fixErr(x.error);draw._last=x.data;return null}});
   if(r&&draw._last)await draw('Your '+cents(v)+' gift card for '+shop.name+' is ready: '+draw._last.code+'. Find it under Rewards.')});
 };
 await draw();
},
async funds(){
 const c=await boot();if(!c)return;const {sb}=c;const R=$('#pay');
 let acc=[];try{const r=await sb.rpc('my_vendor_access');if(!r.error&&Array.isArray(r.data))acc=r.data.filter(a=>a.is_owner||(a.perms||[]).includes('refunds'))}catch(e){}
 if(!acc.length){R.innerHTML='<div class="notice">Platform Funds are for business owners and sub-admins. <a href="rewards.html">See your Rewards</a>.</div>';return}
 const q=new URLSearchParams(location.search);let vid=(acc.find(a=>a.vendor_id===q.get('v'))||acc[0]).vendor_id,key=uuid();
 const KL={topup_card_test:'Card top-up (test)',topup_office:'Office top-up',fees:'Platform fees',fee_refund:'Fee refund',subscription:'Subscription',featured:'Featured listing / ads',setup:'Setup / photo service',adjustment:'Adjustment',exit_payout:'Exit refund'};
 const draw=async note=>{
  const r=await sb.rpc('vendor_funds',{p_vendor:vid});if(r.error){R.innerHTML='<div class="notice err">'+esc(fixErr(r.error))+'</div>';return}
  const F=r.data,a=acc.find(x=>x.vendor_id===vid),G=F.giftcards||{},ex=F.exit,FL=await C.flags();
  R.innerHTML=`${F.test_mode?C.TESTBANNER:''}
  ${acc.length>1?`<div class="dtabs wtabs">${acc.map(x=>`<button class="${x.vendor_id===vid?'on':''}" data-vid="${esc(x.vendor_id)}">${esc(x.vendor_name)}</button>`).join('')}</div>`:''}
  <div class="walletgrid">
   <section class="wcard wbal fu-bal"><span class="kicker">${esc(a.vendor_name)} · Platform Funds</span><div class="bigbal" id="fbal">${cents(F.balance_cents)}</div><small>Prepaid credit for Carriacou Connect services only${F.test_mode?' · TEST play money':''}</small>
    <div class="fu-mini"><div><span>Subscription credit</span><b id="fsc">${cents(F.sub_credit_cents)}</b><small>from Points Store gift cards, rolls over</small></div><div><span>Fees to bill</span><b id="fub">${cents(F.unbilled_cents)}</b><small>next pay cycle ${esc(fday(F.next_cycle+'T16:00:00Z'))}</small></div></div></section>
   <form class="wcard" id="ftop" novalidate><h3>Top up</h3><p class="muted">By card (test mode only, no real money) or at the Carriacou Connect office (cash or card, recorded by staff with a receipt).</p>
    <div class="chips">${[2500,5000,10000,25000].map(v=>`<button type="button" class="chip" data-a="${v}">${cents(v)}</button>`).join('')}</div>
    <label>Amount (EC$)<input id="tamt" inputmode="decimal" placeholder="50.00" autocomplete="off"></label><button class="btn alt" id="tgo">Top up by card (test)</button></form>
  </div>
  <div id="fmsg" class="notice${note?' ok':''}" ${note?'':'hidden'} role="status">${esc(note||'')}</div>
  <section class="wcard fu-what"><h3>What Platform Funds pay for</h3><ul class="fu-list"><li>📅 Your plan subscription (subscription credit is used first)</li><li>🧾 Per-order platform fees: <b>${esc(Number(F.fee_card_pct))}%</b> on card orders paid online, <b>${esc(Number(F.fee_direct_pct))}%</b> on pay on pickup / delivery</li><li>⭐ Featured listings and ads</li><li>📸 Setup and product photo service</li></ul>
   <p class="muted"><small>Fees are charged when an order is placed and billed at the end of the pay cycle. A cancelled or refunded order gets its fee back${Number(F.fee_refund_pct)<100?' ('+esc(Number(F.fee_refund_pct))+'%)':''}. If funds are short, the rest is invoiced. Funds cannot be sent to other users or cashed out; unused funds are refunded only when you close your shop.</small></p></section>
  <h2>Fee lines</h2>
  <div class="tablewrap"><table class="fu-fees stack"><thead><tr><th>Order</th><th>Paid by</th><th>Order total</th><th>Rate</th><th>Fee</th><th>Status</th></tr></thead><tbody>${(F.fees||[]).length?F.fees.map(f=>`<tr class="${f.status}"><td>${esc(f.order_number)}<small>${esc(fdate(f.charged_at))}</small></td><td>${f.fee_class==='card'?'Card (online)':'Direct (pickup/delivery)'}</td><td>${cents(f.base_cents)}</td><td>${esc(Number(f.rate_pct))}%</td><td><b>${cents(f.fee_cents)}</b></td><td>${f.status==='refunded'?'<span class="pp pp-ref">Refunded '+cents(f.refund_cents)+'</span>':f.billed_at?'<span class="pp pp-paid">Billed</span>':'<span class="pp pp-unpaid">To bill</span>'}</td></tr>`).join(''):'<tr><td colspan=6 class="muted">No orders yet.</td></tr>'}</tbody></table></div>
  <div class="fu-cols"><div>
  <h2>Bills</h2>
  ${(F.bills||[]).length?`<div class="hist">${F.bills.map(b=>`<div class="hrow out"><div class="hic" aria-hidden="true">🧾</div><div class="hmid"><b>${esc(KL[b.kind]||b.kind)}${b.note?' · '+esc(b.note):''}</b><small>${esc(fdate(b.created_at))} · credit ${cents(b.from_sub_credit_cents)} · funds ${cents(b.from_funds_cents)}${Number(b.invoice_cents)>0?' · <b class="fu-inv">invoiced '+cents(b.invoice_cents)+'</b>':''}</small></div><div class="hamt">${cents(b.total_cents)}</div></div>`).join('')}</div>`:'<p class="muted">No bills yet.</p>'}
  </div><div>
  <h2>Funds history</h2>
  <div class="hist">${(F.ledger||[]).length?F.ledger.map(l=>`<div class="hrow ${l.amount_cents>0?'in':'out'}"><div class="hic" aria-hidden="true">${l.amount_cents>0?'↓':'↑'}</div><div class="hmid"><b>${esc(KL[l.kind]||l.kind)}</b><small>${esc(fdate(l.created_at))}${l.note?' · '+esc(l.note):''}</small></div><div class="hamt">${l.amount_cents>0?'+':'-'}${cents(Math.abs(l.amount_cents))}</div></div>`).join(''):'<p class="muted">No top-ups or charges yet.</p>'}</div>
  </div></div>
  <div class="fu-cols fu-cols2"><section class="wcard fu-gc" id="gcbox"><h3>🎁 Carriacou Connect gift cards</h3>${G.qualifies?`
   <p class="gc-state ${G.participating?'on':'off'}" id="gcstate"><b>${G.participating?'Opted in: your shop is in the Points Store.':'Opted out: your shop is not in the Points Store.'}</b></p>
   <p>Carriacou Connect creates these gift cards and sets their values and points prices. Shops cannot create or price them. Customers buy them with CC Points, never with money.</p>
   <p><b>You receive subscription credit, not cash.</b> When a customer pays you with one of these cards, Carriacou Connect credits the amount against your plan subscription. Unused credit rolls over to later bills. It is not paid out as cash, except as part of an exit refund when you close your shop.</p>
   ${(G.cards||[]).length?`<p class="muted">Cards for your shop: ${G.cards.map(g=>esc(cents(g.value_cents))+' ('+esc(pts(g.points_cost))+' pts)').join(', ')}. Up to ${cents(G.cap_cents_month)} of cards a month.</p>`:'<p class="muted">Carriacou Connect has not set up any cards for your shop yet.</p>'}
   <label class="chk gc-toggle"><input type="checkbox" role="switch" id="gcon" ${G.participating?'checked':''} ${a.is_owner||(a.perms||[]).includes('refunds')?'':'disabled'}> <span>${G.participating?'Opted in. Untick to opt out.':'Opt in: I accept Carriacou Connect gift cards and agree to be paid in subscription credit, not cash'}</span></label>
   <p class="muted"><small>Opting out stops new cards for your shop. Cards customers already hold for your shop must still be accepted until they are used or expire.</small></p>`:`<p class="muted">Carriacou Connect gift cards are a perk of the ${esc((FL.giftcard_tiers||['plus','pro','enterprise']).map(t=>TL[t]||t).join(', '))} plans. Your plan: ${esc(TL[G.tier]||G.tier||'')}. <a href="tiers.html">See plans</a>.</p>`}</section>
  <section class="wcard fu-exit"><h3>Closing your shop</h3>${ex&&['pending','confirmed'].includes(ex.status)?`<p><b>Refund request ${esc(ex.status)}</b> (${cents(ex.funds_cents)} funds + ${cents(ex.sub_credit_cents)} subscription credit). ${ex.status==='confirmed'?'Confirmed by the manager; paid in the next pay cycle':'Waiting for the platform manager to confirm'} (${esc(fday(ex.scheduled_for+'T16:00:00Z'))}). Test mode: no real money.</p>${ex.status==='pending'&&a.is_owner?'<button class="btn ghost" id="exw" type="button">Withdraw request</button>':''}`:`${ex&&ex.status==='paid'?`<p class="muted">Last exit refund paid ${esc(fdate(ex.paid_at))}.</p>`:''}<p class="muted">If you leave Carriacou Connect, unused Platform Funds and rolled-over subscription credit are paid to your business in the next pay cycle after the platform manager confirms.</p>${a.is_owner?'<button class="btn ghost" id="exr" type="button">Request exit refund</button>':'<p class="muted"><small>Only the owner can ask.</small></p>'}`}</section></div>`;
  const m=$('#fmsg'),say=(t,ok)=>{m.hidden=!t;m.className='notice '+(ok?'ok':'err');m.textContent=t};
  R.querySelectorAll('[data-vid]').forEach(b=>b.onclick=()=>{vid=b.dataset.vid;draw()});
  R.querySelectorAll('.chip').forEach(b=>b.onclick=()=>{$('#tamt').value=(b.dataset.a/100).toFixed(2)});
  $('#ftop').onsubmit=async e=>{e.preventDefault();const v=C.toCents($('#tamt').value);if(!v||v<1)return say('Enter an amount like 50.00');
   if(v>F.topup_max_cents)return say('Test top-ups are up to '+cents(F.topup_max_cents)+' each.');
   const ok=await C.confirmPay({icon:'🏦',kicker:'Platform Funds · TEST',title:'Top up '+a.vendor_name,amountLabel:'Top-up',amountCents:v,rows:[['Balance after',cents(Number(F.balance_cents)+v)],['Paid by','Test card (play money)']],note:'Platform Funds can only be spent on Carriacou Connect services.',confirmText:'Top up',busyText:'Adding…',
    onConfirm:async()=>{const x=await sb.rpc('vendor_funds_topup_test',{p_vendor:vid,p_amount_cents:v,p_key:key});return x.error?fixErr(x.error):null}});
   if(ok){key=uuid();await draw('Added '+cents(v)+' of test Platform Funds.')}};
  const gc=$('#gcon');if(gc)gc.onchange=async()=>{const x=await sb.rpc('vendor_set_giftcards',{p_vendor:vid,p_on:gc.checked});if(x.error){gc.checked=!gc.checked;say(fixErr(x.error))}else await draw(gc.checked?'Opted in: your shop is now in the Points Store.':'Opted out: no new gift cards will be issued for your shop. Cards already issued are still honoured.')};
  const er=$('#exr');if(er)er.onclick=async()=>{const ok=await C.confirmPay({icon:'🚪',kicker:'Close shop · refund request',title:a.vendor_name,amountLabel:'To refund (estimate)',amountCents:Number(F.balance_cents)+Number(F.sub_credit_cents),
    rows:[['Platform Funds',cents(F.balance_cents)],['Subscription credit',cents(F.sub_credit_cents)],['Paid on',fday(F.next_cycle+'T16:00:00Z')+' (next pay cycle)']],note:'The platform manager confirms before anything is paid. Test mode: no real money moves.',
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
