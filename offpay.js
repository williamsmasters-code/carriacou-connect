// v1.13 offline payments (pay on pickup / pay on delivery): vendor records Paid in full / Paid partially; customer sees status.
(function(){const C=window.CC,esc=C.esc;
const num=v=>Number(v)||0,c$=x=>C.cents(Math.round(num(x)*100));
const isOff=o=>o&&o.payment_method!=='pay_with_wallet'&&o.payment_status==='unpaid';
const paid=o=>num(o.amount_paid_xcd),bal=o=>Math.max(0,Math.round((num(o.total_xcd)-paid(o))*100)/100);
const state=o=>!o?'unpaid':o.payment_status==='refunded'?'refunded':o.payment_status==='paid'?'paid':(o.offline_status||'unpaid');
const METH={cash:'Cash',card:'Card',bank:'Bank transfer',other:'Other',wallet:'Wallet (test)',gift_card:'Gift card (CC Points)'};
const RMETH={cash:'Cash',card:'Card',bank:'Bank transfer',other:'Other'};
const fmt=d=>{try{return new Intl.DateTimeFormat('en-GB',{timeZone:'America/Grenada',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}).format(new Date(d))}catch(e){return d}};
const missing=e=>e&&/order_payments|schema cache|does not exist|vendor_record_payment/i.test(e.message||'');
const summary=o=>`<div class="op-sum op-${state(o)}"><div><span>Status</span><b>${state(o)==='paid'?'Paid in full':state(o)==='partial'?'Paid partially':'Unpaid'}</b></div><div><span>Order total</span><b>${c$(o.total_xcd)}</b></div><div><span>Paid so far</span><b>${c$(paid(o))}</b></div><div class="op-due"><span>Balance due</span><b>${c$(bal(o))}</b></div></div>`;
const hist=(rows,canVoid)=>rows.length?`<ol class="op-hist">${rows.map(p=>`<li class="${p.voided?'void':''}"><span class="op-amt">${c$(p.amount_xcd)}</span><span class="op-m">${esc(METH[p.method]||p.method)} · ${p.kind==='full'?'balance paid':'part payment'}</span><span class="op-t">${esc(fmt(p.created_at))}</span>${p.note?`<span class="op-n">“${esc(p.note)}”</span>`:''}${p.voided?`<span class="op-v">Voided: ${esc(p.void_reason||'')}</span>`:canVoid&&p.method!=='wallet'&&p.method!=='gift_card'?`<button type="button" class="linkbtn op-void" data-pay="${esc(p.id)}">Void</button>`:''}</li>`).join('')}</ol>`:'<p class="muted op-none">No payments recorded yet.</p>';
async function ledger(sb,ids){if(!ids.length)return {};const r=await sb.from('order_payments').select('*').in('order_id',ids).order('created_at',{ascending:true});
 if(r.error)return {_err:r.error};const m={};(r.data||[]).forEach(p=>(m[p.order_id]=m[p.order_id]||[]).push(p));return m}
async function requests(sb,ids){if(!ids.length)return {};const r=await sb.from('order_pay_requests').select('*').in('order_id',ids).eq('status','pending');
 if(r.error)return {_err:r.error};const m={};(r.data||[]).forEach(q=>m[q.order_id]=q);return m}
const canPay=o=>isOff(o)&&o.status!=='cancelled'&&bal(o)>0;
const payAmt=(o,q)=>q?Math.min(num(q.amount_xcd),bal(o)):bal(o);
// customer: order list pills "Pay balance EC$x"
async function listBadges(root,rows,{sb}){const els=[...root.querySelectorAll('[data-pb]')];if(!els.length)return;const FL=await C.flags();if(FL.wallet_mode==='off'){els.forEach(e=>{const o=rows.find(x=>x.id===e.dataset.pb);e.innerHTML=o&&canPay(o)?`<span class="pp pp-unpaid">Balance due ${c$(bal(o))}</span>`:''});return}const Q=await requests(sb,rows.filter(canPay).map(o=>o.id));
 els.forEach(e=>{const o=rows.find(x=>x.id===e.dataset.pb);e.innerHTML=o&&canPay(o)?`<span class="pp pp-due${Q[o.id]?' req':''}">${Q[o.id]?'🔔 ':''}Pay balance ${c$(payAmt(o,Q[o.id]))}</span>`:''})}
// customer: read-only box
async function customerBox(el,o,{sb,onPaid}){if(!el||!isOff(o))return;const FL=await C.flags();const parked=FL.wallet_mode==='off';
 const draw=async()=>{const [L,Q]=await Promise.all([ledger(sb,[o.id]),parked?{}:requests(sb,[o.id])]);const q=Q._err?null:Q[o.id],amt=payAmt(o,q),pay=!parked&&canPay(o)&&!Q._err;
  let cards=[];if(FL.gift_cards_enabled&&canPay(o)){try{const g=await sb.rpc('my_gift_cards');if(!g.error)cards=(g.data||[]).filter(x=>x.vendor_id===o.vendor_id&&x.status==='active'&&x.balance_cents>0)}catch(e){}}
  el.innerHTML=`<div class="offpay cust"><h3>Payment to ${esc(o.vendors&&o.vendors.name||'the vendor')}</h3>${summary(o)}
  ${q?`<div class="op-req"><span class="op-req-ic" aria-hidden="true">🔔</span><div><b>${esc(o.vendors&&o.vendors.name||'The vendor')} requested ${c$(q.amount_xcd)}</b>${q.message?`<span>“${esc(q.message)}”</span>`:''}<small>${esc(fmt(q.created_at))}</small></div></div>`:''}
  ${pay?`<div class="op-pay">${C.TESTBANNER}<button type="button" class="btn alt" id="opbal">Pay balance ${c$(amt)}</button>${q&&amt<bal(o)?`<button type="button" class="linkbtn" id="opall">Pay the full balance ${c$(bal(o))} instead</button>`:''}<small class="muted">From your test wallet (play money), or pay the vendor on ${o.fulfilment==='delivery'?'delivery':'pickup'}.</small><div id="opbm" class="notice" hidden role="alert"></div></div>`:''}
  ${cards.length?`<div class="op-gc"><span class="kicker">🎁 Use a gift card</span><label class="pd-f">Gift card for this shop<select id="gcsel">${cards.map(g=>`<option value="${esc(g.code)}">${esc(g.code)} · ${C.cents(g.balance_cents)} left</option>`).join('')}</select></label><button type="button" class="btn alt" id="gcuse">Use gift card</button><small class="muted">Gift cards come from the Points Store (paid with CC Points). The rest of the balance is paid to the shop directly.</small><div id="gcm" class="notice" hidden role="alert"></div></div>`:''}
  ${L._err?'':hist(L[o.id]||[],false)}<p class="muted"><small>${parked?'You pay the shop directly. The shop records cash, card or bank payments made on '+(o.fulfilment==='delivery'?'delivery':'pickup')+'. Carriacou Connect never holds your money.':'The vendor records cash, card or bank payments made on '+(o.fulfilment==='delivery'?'delivery':'pickup')+'. Wallet payments are recorded automatically.'}</small></p></div>`;
  const gb=el.querySelector('#gcuse');if(gb)gb.onclick=async()=>{const code=el.querySelector('#gcsel').value,g=cards.find(x=>x.code===code);const use=Math.min(g.balance_cents,Math.round(bal(o)*100));
   const res=await C.confirmPay({icon:'🎁',kicker:'Gift card · CC Points',title:'Order '+o.order_number,amountLabel:'Gift card pays',amountCents:use,
    rows:[['Shop',(o.vendors&&o.vendors.name)||'Shop'],['Gift card',code],['Card left after',C.cents(g.balance_cents-use)],['Balance due after',c$(bal(o)-use/100)]],note:'Gift cards are rewards bought with CC Points. They are not money and work only at this shop on Carriacou Connect.',confirmText:'Use gift card',busyText:'Applying…',
    onConfirm:async()=>{const r=await sb.rpc('apply_gift_card',{p_order:o.id,p_code:code});return r.error?r.error.message:null}});
   if(res){if(onPaid)await onPaid();else await draw()}};
  const go=async(a,btn)=>{btn.disabled=true;let wb=null;try{const wr=await sb.rpc('ensure_wallets');const w=!wr.error&&Array.isArray(wr.data)&&wr.data.find(x=>x.kind==='user');if(w)wb=Number(w.balance_cents)}catch(e){}
   const tl=C.orderLines(o).find(l=>/VAT/.test(l.k)),key='bal-'+o.id+'-'+C.uuid().slice(0,12);
   const okp=await C.confirmPay({title:'Pay '+(a<bal(o)?'part of the balance':'the balance')+' for '+o.order_number,amountCents:Math.round(a*100),vat:tl?'Order '+tl.k.toLowerCase()+': '+C.cents(Math.round(tl.v*100)):'',balanceCents:wb,
    rows:[['Order',o.order_number],['Vendor',(o.vendors&&o.vendors.name)||'Vendor'],['Order total',c$(o.total_xcd)],['Balance due after',c$(bal(o)-a)],['Paid from','Your test wallet']],confirmText:'Confirm pay',
    onConfirm:async()=>{const r=await sb.rpc('customer_pay_balance',{p_order:o.id,p_amount:a,p_idempotency_key:key});if(r.error)return /customer_pay_balance|schema cache|does not exist/i.test(r.error.message)?'Paying the balance from the wallet is not switched on yet (order_pay_requests.sql).':r.error.message;return null}});
   btn.disabled=false;if(okp&&onPaid)onPaid()};
  const b1=el.querySelector('#opbal');if(b1)b1.onclick=()=>go(amt,b1);const b2=el.querySelector('#opall');if(b2)b2.onclick=()=>go(bal(o),b2)};
 await draw();
 if(C.live){if(C._opOff)C._opOff();C._opOff=C.live.on(n=>{if(n&&n.ref_id===o.id&&/^pay_request/.test(n.kind||'')&&el.isConnected)draw()})}}
// vendor: fill .offpay[data-oid] slots on the order cards
async function vendorMount(T,list,{sb,can,onChange}){const slots=[...T.querySelectorAll('.offpay[data-oid]')];if(!slots.length)return;const parked=(await C.flags()).wallet_mode==='off';
 const ids=slots.map(s=>s.dataset.oid);const [L,Q]=await Promise.all([ledger(sb,ids),requests(sb,ids)]);
 slots.forEach(s=>{const o=list.find(x=>x.id===s.dataset.oid);if(!o)return;const live=o.status!=='cancelled',b=bal(o);
  s.innerHTML=`${summary(o)}${L._err?(missing(L._err)?'<p class="muted"><small>Offline payment tracking is not switched on yet (offline_payments.sql).</small></p>':''):`<details class="op-log"${(L[o.id]||[]).length?'':''}><summary>Payment history (${(L[o.id]||[]).filter(p=>!p.voided).length})</summary>${hist(L[o.id]||[],can('refunds'))}</details>`}
  ${(q=>q?`<div class="op-req vend"><span class="op-req-ic" aria-hidden="true">🔔</span><div><b>Payment requested: ${c$(q.amount_xcd)}</b>${q.message?`<span>“${esc(q.message)}”</span>`:''}<small>Sent ${esc(fmt(q.created_at))}${q.reminder_count?` · ${q.reminder_count} reminder${q.reminder_count>1?'s':''}, last ${esc(fmt(q.reminded_at))}`:''} · waiting for the customer</small></div>${can('orders_update')?`<div class="op-req-b"><button type="button" class="btn ghost sm" data-remind="${esc(q.id)}">Send reminder</button><button type="button" class="linkbtn" data-rcancel="${esc(q.id)}">Cancel request</button></div>`:''}</div>`:'')(Q._err?null:Q[o.id])}
  ${live&&b>0&&can('orders_update')&&!L._err?`<div class="op-acts">${!parked&&!Q._err&&!Q[o.id]?`<button type="button" class="btn op-reqb" data-req="${esc(o.id)}">🔔 Request payment</button>`:''}<button type="button" class="btn op-full" data-full="${esc(o.id)}">✓ Paid in full</button><button type="button" class="btn ghost op-part" data-part="${esc(o.id)}">Paid partially…</button></div>`:''}`});
 const rpc=async(fn,args)=>{const r=await sb.rpc(fn,args);if(r.error)return /order_pay_requests|vendor_(request|remind|cancel)_pay/i.test(r.error.message)?'Payment requests are not switched on yet (order_pay_requests.sql has not been run in Supabase).':missing(r.error)?'Offline payments are not switched on yet (offline_payments.sql has not been run in Supabase).':r.error.message;return null};
 const after=async ok=>{if(ok&&onChange)await onChange()};
 T.querySelectorAll('[data-full]').forEach(btn=>btn.onclick=async()=>{const o=list.find(x=>x.id===btn.dataset.full);
  after(await C.confirmPay({icon:'💵',kicker:'Record payment · Paid in full',title:'Order '+o.order_number,amountLabel:'Customer paid',amountCents:Math.round(bal(o)*100),
   rows:[['Order total',c$(o.total_xcd)],['Already paid',c$(paid(o))],['Balance after','EC$0.00']],note:'Records money you received in person. No wallet money moves.',
   bodyHtml:`<label class="pd-f">How did they pay?<select id="opm" data-pd-focus>${Object.entries(RMETH).map(([k,v])=>`<option value="${k}">${v}</option>`).join('')}</select></label><label class="pd-f">Note (optional)<input id="opn" maxlength="200" placeholder="e.g. receipt #"></label>`,
   confirmText:'Record paid in full',busyText:'Saving…',
   onConfirm:w=>rpc('vendor_record_payment',{p_order:o.id,p_kind:'full',p_amount:null,p_method:w.querySelector('#opm').value,p_note:w.querySelector('#opn').value||null})}))});
 T.querySelectorAll('[data-part]').forEach(btn=>btn.onclick=async()=>{const o=list.find(x=>x.id===btn.dataset.part),b=bal(o);
  after(await C.confirmPay({icon:'🪙',kicker:'Record payment · Paid partially',title:'Order '+o.order_number,amountCents:null,
   rows:[['Order total',c$(o.total_xcd)],['Already paid',c$(paid(o))],['Balance due',c$(b)]],note:'Records money you received in person. No wallet money moves.',
   bodyHtml:`<label class="pd-f">Amount received (EC$)<input id="opa" inputmode="decimal" data-pd-focus placeholder="less than ${b.toFixed(2)}"></label><label class="pd-f">How did they pay?<select id="opm">${Object.entries(RMETH).map(([k,v])=>`<option value="${k}">${v}</option>`).join('')}</select></label><label class="pd-f">Note (optional)<input id="opn" maxlength="200"></label>`,
   confirmText:'Record part payment',busyText:'Saving…',
   onConfirm:w=>{const cc=C.toCents(w.querySelector('#opa').value);if(cc==null||cc<=0)return 'Enter the amount received, e.g. 20.00';if(cc>=Math.round(b*100))return 'A part payment must be less than the balance due ('+c$(b)+'). Use Paid in full instead.';
    return rpc('vendor_record_payment',{p_order:o.id,p_kind:'partial',p_amount:cc/100,p_method:w.querySelector('#opm').value,p_note:w.querySelector('#opn').value||null})}}))});
const allQ=()=>Object.values(Q).filter(x=>x&&x.id);
 T.querySelectorAll('[data-req]').forEach(btn=>btn.onclick=async()=>{const o=list.find(x=>x.id===btn.dataset.req),b=bal(o);
  after(await C.confirmPay({icon:'🔔',kicker:'Request payment · test wallet',title:'Order '+o.order_number,amountCents:null,
   rows:[['Order total',c$(o.total_xcd)],['Already paid',c$(paid(o))],['Balance due',c$(b)]],note:'The customer gets a notification and can pay from their test wallet (play money). They can still pay you in person.',
   bodyHtml:`<label class="pd-f">Amount to request (EC$)<input id="rqa" inputmode="decimal" data-pd-focus value="${b.toFixed(2)}"></label><label class="pd-f">Message (optional)<input id="rqm" maxlength="200" placeholder="e.g. deposit before delivery"></label>`,
   confirmText:'Send request',busyText:'Sending…',
   onConfirm:w=>{const cc=C.toCents(w.querySelector('#rqa').value);if(cc==null||cc<=0)return 'Enter an amount, e.g. 20.00';if(cc>Math.round(b*100))return 'The request cannot be more than the balance due ('+c$(b)+').';
    return rpc('vendor_request_payment',{p_order:o.id,p_amount:cc/100,p_message:w.querySelector('#rqm').value||null})}}))});
 T.querySelectorAll('[data-remind]').forEach(btn=>btn.onclick=async()=>{btn.disabled=true;const e=await rpc('vendor_remind_pay_request',{p_request:btn.dataset.remind});btn.disabled=false;
  const box=btn.closest('.op-req');let m=box.querySelector('.op-msg');if(!m){m=document.createElement('small');m.className='op-msg';box.appendChild(m)}m.textContent=e||'Reminder sent.';m.classList.toggle('err',!!e);if(!e&&onChange)setTimeout(onChange,900)});
 T.querySelectorAll('[data-rcancel]').forEach(btn=>btn.onclick=async()=>{const q=allQ().find(x=>x.id===btn.dataset.rcancel);const o=q&&list.find(x=>x.id===q.order_id);
  after(await C.confirmPay({icon:'✖',kicker:'Cancel payment request',title:'Order '+(o?o.order_number:''),amountLabel:'Requested',amountCents:Math.round(num(q.amount_xcd)*100),rows:[],note:'The customer is told the request was withdrawn. They can still pay in person or pay the balance anytime.',confirmText:'Cancel request',busyText:'Cancelling…',
   onConfirm:()=>rpc('vendor_cancel_pay_request',{p_request:q.id})}))});
 T.querySelectorAll('[data-pay]').forEach(btn=>btn.onclick=async()=>{let p=null;Object.values(L).forEach(a=>Array.isArray(a)&&a.forEach(x=>{if(x.id===btn.dataset.pay)p=x}));if(!p)return;
  const o=list.find(x=>x.id===p.order_id);
  after(await C.confirmPay({icon:'↩️',kicker:'Void a payment record',title:'Order '+(o?o.order_number:''),amountLabel:'Payment to void',amountCents:Math.round(num(p.amount_xcd)*100),
   rows:[['Method',METH[p.method]||p.method],['Recorded',fmt(p.created_at)]],note:'Use this only to correct a mistake. The record stays in the history, marked void.',
   bodyHtml:`<label class="pd-f">Reason<input id="opr" maxlength="200" data-pd-focus placeholder="e.g. wrong amount"></label>`,confirmText:'Void payment',busyText:'Voiding…',
   onConfirm:w=>{const r=w.querySelector('#opr').value.trim();if(!r)return 'Give a reason';return rpc('vendor_void_payment',{p_payment:p.id,p_reason:r})}}))});
}
C.offpay={listBadges,requests,canPay,isOff,paid,bal,state,customerBox,vendorMount,ledger,METH};
})();
