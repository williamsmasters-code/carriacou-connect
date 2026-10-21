// v1.13 offline payments (pay on pickup / pay on delivery): vendor records Paid in full / Paid partially; customer sees status.
(function(){const C=window.CC,esc=C.esc;
const num=v=>Number(v)||0,c$=x=>C.cents(Math.round(num(x)*100));
const isOff=o=>o&&o.payment_method!=='pay_with_wallet'&&o.payment_status==='unpaid';
const paid=o=>num(o.amount_paid_xcd),bal=o=>Math.max(0,Math.round((num(o.total_xcd)-paid(o))*100)/100);
const state=o=>!o?'unpaid':o.payment_status==='refunded'?'refunded':o.payment_status==='paid'?'paid':(o.offline_status||'unpaid');
const METH={cash:'Cash',card:'Card',bank:'Bank transfer',other:'Other'};
const fmt=d=>{try{return new Intl.DateTimeFormat('en-GB',{timeZone:'America/Grenada',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}).format(new Date(d))}catch(e){return d}};
const missing=e=>e&&/order_payments|schema cache|does not exist|vendor_record_payment/i.test(e.message||'');
const summary=o=>`<div class="op-sum op-${state(o)}"><div><span>Status</span><b>${state(o)==='paid'?'Paid in full':state(o)==='partial'?'Paid partially':'Unpaid'}</b></div><div><span>Order total</span><b>${c$(o.total_xcd)}</b></div><div><span>Paid so far</span><b>${c$(paid(o))}</b></div><div class="op-due"><span>Balance due</span><b>${c$(bal(o))}</b></div></div>`;
const hist=(rows,canVoid)=>rows.length?`<ol class="op-hist">${rows.map(p=>`<li class="${p.voided?'void':''}"><span class="op-amt">${c$(p.amount_xcd)}</span><span class="op-m">${esc(METH[p.method]||p.method)} · ${p.kind==='full'?'balance paid':'part payment'}</span><span class="op-t">${esc(fmt(p.created_at))}</span>${p.note?`<span class="op-n">“${esc(p.note)}”</span>`:''}${p.voided?`<span class="op-v">Voided: ${esc(p.void_reason||'')}</span>`:canVoid?`<button type="button" class="linkbtn op-void" data-pay="${esc(p.id)}">Void</button>`:''}</li>`).join('')}</ol>`:'<p class="muted op-none">No payments recorded yet.</p>';
async function ledger(sb,ids){if(!ids.length)return {};const r=await sb.from('order_payments').select('*').in('order_id',ids).order('created_at',{ascending:true});
 if(r.error)return {_err:r.error};const m={};(r.data||[]).forEach(p=>(m[p.order_id]=m[p.order_id]||[]).push(p));return m}
// customer: read-only box
async function customerBox(el,o,{sb}){if(!el||!isOff(o))return;const L=await ledger(sb,[o.id]);
 el.innerHTML=`<div class="offpay cust"><h3>Payment to ${esc(o.vendors&&o.vendors.name||'the vendor')}</h3>${summary(o)}${L._err?'':hist(L[o.id]||[],false)}<p class="muted"><small>The vendor records cash, card or bank payments made on ${o.fulfilment==='delivery'?'delivery':'pickup'}.</small></p></div>`}
// vendor: fill .offpay[data-oid] slots on the order cards
async function vendorMount(T,list,{sb,can,onChange}){const slots=[...T.querySelectorAll('.offpay[data-oid]')];if(!slots.length)return;
 const L=await ledger(sb,slots.map(s=>s.dataset.oid));
 slots.forEach(s=>{const o=list.find(x=>x.id===s.dataset.oid);if(!o)return;const live=o.status!=='cancelled',b=bal(o);
  s.innerHTML=`${summary(o)}${L._err?(missing(L._err)?'<p class="muted"><small>Offline payment tracking is not switched on yet (offline_payments.sql).</small></p>':''):`<details class="op-log"${(L[o.id]||[]).length?'':''}><summary>Payment history (${(L[o.id]||[]).filter(p=>!p.voided).length})</summary>${hist(L[o.id]||[],can('refunds'))}</details>`}
  ${live&&b>0&&can('orders_update')&&!L._err?`<div class="op-acts"><button type="button" class="btn op-full" data-full="${esc(o.id)}">✓ Paid in full</button><button type="button" class="btn ghost op-part" data-part="${esc(o.id)}">Paid partially…</button></div>`:''}`});
 const rpc=async(fn,args)=>{const r=await sb.rpc(fn,args);if(r.error)return missing(r.error)?'Offline payments are not switched on yet (offline_payments.sql has not been run in Supabase).':r.error.message;return null};
 const after=async ok=>{if(ok&&onChange)await onChange()};
 T.querySelectorAll('[data-full]').forEach(btn=>btn.onclick=async()=>{const o=list.find(x=>x.id===btn.dataset.full);
  after(await C.confirmPay({icon:'💵',kicker:'Record payment · Paid in full',title:'Order '+o.order_number,amountLabel:'Customer paid',amountCents:Math.round(bal(o)*100),
   rows:[['Order total',c$(o.total_xcd)],['Already paid',c$(paid(o))],['Balance after','EC$0.00']],note:'Records money you received in person. No wallet money moves.',
   bodyHtml:`<label class="pd-f">How did they pay?<select id="opm" data-pd-focus>${Object.entries(METH).map(([k,v])=>`<option value="${k}">${v}</option>`).join('')}</select></label><label class="pd-f">Note (optional)<input id="opn" maxlength="200" placeholder="e.g. receipt #"></label>`,
   confirmText:'Record paid in full',busyText:'Saving…',
   onConfirm:w=>rpc('vendor_record_payment',{p_order:o.id,p_kind:'full',p_amount:null,p_method:w.querySelector('#opm').value,p_note:w.querySelector('#opn').value||null})}))});
 T.querySelectorAll('[data-part]').forEach(btn=>btn.onclick=async()=>{const o=list.find(x=>x.id===btn.dataset.part),b=bal(o);
  after(await C.confirmPay({icon:'🪙',kicker:'Record payment · Paid partially',title:'Order '+o.order_number,amountCents:null,
   rows:[['Order total',c$(o.total_xcd)],['Already paid',c$(paid(o))],['Balance due',c$(b)]],note:'Records money you received in person. No wallet money moves.',
   bodyHtml:`<label class="pd-f">Amount received (EC$)<input id="opa" inputmode="decimal" data-pd-focus placeholder="less than ${b.toFixed(2)}"></label><label class="pd-f">How did they pay?<select id="opm">${Object.entries(METH).map(([k,v])=>`<option value="${k}">${v}</option>`).join('')}</select></label><label class="pd-f">Note (optional)<input id="opn" maxlength="200"></label>`,
   confirmText:'Record part payment',busyText:'Saving…',
   onConfirm:w=>{const cc=C.toCents(w.querySelector('#opa').value);if(cc==null||cc<=0)return 'Enter the amount received, e.g. 20.00';if(cc>=Math.round(b*100))return 'A part payment must be less than the balance due ('+c$(b)+'). Use Paid in full instead.';
    return rpc('vendor_record_payment',{p_order:o.id,p_kind:'partial',p_amount:cc/100,p_method:w.querySelector('#opm').value,p_note:w.querySelector('#opn').value||null})}}))});
 T.querySelectorAll('[data-pay]').forEach(btn=>btn.onclick=async()=>{let p=null;Object.values(L).forEach(a=>Array.isArray(a)&&a.forEach(x=>{if(x.id===btn.dataset.pay)p=x}));if(!p)return;
  const o=list.find(x=>x.id===p.order_id);
  after(await C.confirmPay({icon:'↩️',kicker:'Void a payment record',title:'Order '+(o?o.order_number:''),amountLabel:'Payment to void',amountCents:Math.round(num(p.amount_xcd)*100),
   rows:[['Method',METH[p.method]||p.method],['Recorded',fmt(p.created_at)]],note:'Use this only to correct a mistake. The record stays in the history, marked void.',
   bodyHtml:`<label class="pd-f">Reason<input id="opr" maxlength="200" data-pd-focus placeholder="e.g. wrong amount"></label>`,confirmText:'Void payment',busyText:'Voiding…',
   onConfirm:w=>{const r=w.querySelector('#opr').value.trim();if(!r)return 'Give a reason';return rpc('vendor_void_payment',{p_payment:p.id,p_reason:r})}}))});
}
C.offpay={isOff,paid,bal,state,customerBox,vendorMount,ledger,METH};
})();
