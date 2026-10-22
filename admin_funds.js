// v1.16 admin: Platform Funds overview, office top-ups, service charges, end-of-cycle fee billing,
// manager queue for vendor exit refunds, and the wallet-repurpose feature flags. Every action is re-checked in the database.
(function(){
const C=window.CC,esc=C.esc,cents=C.cents,fdate=C.fdate,TL=C.TIER_LABEL||{};
const NOTON='Platform Funds are not switched on yet: supabase/wallet_repurpose.sql has not been run in Supabase.';
const fix=e=>{const m=(e&&e.message)||'Something went wrong.';return /schema cache|does not exist|Could not find the function/i.test(m)?NOTON:m};
async function mount(el,sb){
 let msg='',ok=true;
 const draw=async()=>{
  const [o,q,f]=await Promise.all([sb.rpc('admin_funds_overview'),sb.rpc('admin_exit_queue'),sb.rpc('platform_flags_get')]);
  if(o.error||q.error){el.innerHTML='<div class="notice err">'+esc(fix(o.error||q.error))+'</div>';return}
  const V=o.data||[],Q=q.data||[],F=f.data||{},open=Q.filter(x=>['pending','confirmed'].includes(x.status));
  const vopt=V.map(v=>`<option value="${esc(v.vendor_id)}">${esc(v.name)}</option>`).join('');
  el.innerHTML=`${C.TESTBANNER}<div id="afmsg" class="notice ${ok?'ok':'err'}" ${msg?'':'hidden'} role="status">${esc(msg)}</div>
  <section class="wcard af-q" id="exits"><h3>🚪 Manager queue: shop exit refunds ${open.length?`<b class="nbadge">${open.length}</b>`:''}</h3>
   ${Q.length?`<div class="tablewrap"><table><thead><tr><th>Shop</th><th>Requested</th><th>Funds / credit now</th><th>Pay cycle</th><th>Status</th><th></th></tr></thead><tbody>${Q.map(x=>`<tr><td><b>${esc(x.vendor)}</b>${x.reason?`<small>“${esc(x.reason)}”</small>`:''}</td><td>${esc(fdate(x.created_at))}</td><td>${cents(x.funds_now_cents)} / ${cents(x.sub_credit_now_cents)}</td><td>${esc(x.scheduled_for||'')}</td><td><span class="pp ${x.status==='paid'?'pp-paid':x.status==='pending'?'pp-unpaid':'pp-part'}">${esc(x.status)}</span></td>
    <td class="af-acts">${x.status==='pending'?`<button class="btn sm" data-ex="confirm" data-id="${esc(x.id)}">Confirm</button><button class="btn ghost sm" data-ex="reject" data-id="${esc(x.id)}">Reject</button>`:x.status==='confirmed'?`<button class="btn alt sm" data-ex="paid" data-id="${esc(x.id)}">Mark paid (test)</button><button class="btn ghost sm" data-ex="reject" data-id="${esc(x.id)}">Reject</button>`:''}</td></tr>`).join('')}</tbody></table></div>`:'<p class="muted">No exit requests.</p>'}</section>
  <section class="wcard"><h3>🏦 Platform Funds by shop</h3><div class="tablewrap"><table><thead><tr><th>Shop</th><th>Plan</th><th>Funds</th><th>Subscription credit</th><th>Fees to bill</th><th>Open invoices</th></tr></thead><tbody>${V.map(v=>`<tr><td>${esc(v.name)}</td><td>${esc(TL[v.tier]||v.tier)}</td><td>${cents(v.balance_cents)}</td><td>${cents(v.sub_credit_cents)}</td><td>${cents(v.unbilled_cents)}</td><td>${Number(v.open_invoice_cents)>0?'<b class="fu-inv">'+cents(v.open_invoice_cents)+'</b>':cents(0)}</td></tr>`).join('')}</tbody></table></div>
   <p><button class="btn" id="afbill" type="button">Bill per-order fees now (end of pay cycle)</button></p></section>
  <div class="walletgrid forms">
   <form class="wcard" id="aftop"><h3>Office top-up (TEST)</h3><label>Shop<select id="atv">${vopt}</select></label><label>Amount (EC$)<input id="ata" inputmode="decimal" placeholder="100.00"></label>
    <label>Paid by<select id="atm"><option value="cash">Cash at office</option><option value="card">Card at office</option></select></label><label>Receipt no.<input id="atr" maxlength="80" placeholder="R-0001"></label><button class="btn alt">Record top-up</button></form>
   <form class="wcard" id="afsvc"><h3>Charge a platform service</h3><label>Shop<select id="asv">${vopt}</select></label><label>Service<select id="ask"><option value="subscription">Subscription</option><option value="featured">Featured listing / ads</option><option value="setup">Setup / photo service</option></select></label>
    <label>Amount (EC$)<input id="asa" inputmode="decimal" placeholder="50.00"></label><label>Note<input id="asn" maxlength="200"></label><button class="btn">Charge</button></form>
   <form class="wcard" id="afflags"><h3>⚙️ Feature flags</h3>
    <label>Money wallet<select id="ffw"><option value="off"${F.wallet_mode==='off'?' selected':''}>Off (parked)</option><option value="test"${F.wallet_mode==='test'?' selected':''}>Test mode (play money)</option></select></label>
    <label class="chk"><input type="checkbox" id="ffr"${F.rewards_enabled?' checked':''}> <span>CC Points rewards</span></label><label class="chk"><input type="checkbox" id="ffc"${F.vendor_credit_enabled?' checked':''}> <span>Platform Funds + per-order fees</span></label><label class="chk"><input type="checkbox" id="ffg"${F.gift_cards_enabled?' checked':''}> <span>Points Store gift cards</span></label>
    <label>Card fee %<input id="ffcp" inputmode="decimal" value="${esc(F.fee_card_pct)}"></label><label>Pickup/delivery fee %<input id="ffdp" inputmode="decimal" value="${esc(F.fee_direct_pct)}"></label><label>Fee refund on cancel %<input id="ffrp" inputmode="decimal" value="${esc(F.fee_refund_pct)}"></label>
    <fieldset class="fftiers"><legend>Points Store tiers <small>(undecided: default Plus+ and above)</small></legend>${['lite','standard','plus','pro','enterprise'].map(t=>`<label class="chk"><input type="checkbox" data-tier="${t}"${(F.giftcard_tiers||[]).includes(t)?' checked':''}> <span>${esc(TL[t]||t)}</span></label>`).join('')}</fieldset>
    <label>Points per EC$1 of gift card, by tier (JSON)<input id="ffpp" value='${esc(JSON.stringify(F.giftcard_points_per_ec||{}))}'></label><label>Gift card cap per shop per month (EC$)<input id="ffcap" inputmode="decimal" value="${esc((F.giftcard_cap_cents_month||0)/100)}"></label>
    <button class="btn">Save flags</button></form>
  </div>`;
  const run=async(fn,args,good)=>{const r=await sb.rpc(fn,args);msg=r.error?fix(r.error):good(r.data);ok=!r.error;await draw()};
  el.querySelectorAll('[data-ex]').forEach(b=>b.onclick=async()=>{const act=b.dataset.ex,x=Q.find(y=>y.id===b.dataset.id);let note=null,ref=null;
   if(act==='reject'){note=prompt('Reason for rejecting');if(!note)return}
   if(act==='paid'){ref=prompt('Payout reference (test)','TEST-'+Date.now().toString(36).toUpperCase());if(!ref)return}
   await run('admin_exit_decide',{p_request:x.id,p_action:act,p_note:note,p_ref:ref},()=>x.vendor+': '+(act==='confirm'?'confirmed for the next pay cycle':act==='paid'?'marked paid (test, no real money)':'rejected'))});
  el.querySelector('#afbill').onclick=()=>run('admin_bill_fees',{},d=>'Billed '+cents(d.total_cents)+' of fees for '+d.vendors+' shop(s).');
  el.querySelector('#aftop').onsubmit=e=>{e.preventDefault();const a=C.toCents(el.querySelector('#ata').value);if(!a){msg='Enter an amount';ok=false;return draw()}
   run('admin_funds_topup',{p_vendor:el.querySelector('#atv').value,p_amount_cents:a,p_method:el.querySelector('#atm').value,p_receipt:el.querySelector('#atr').value||null},d=>'Top-up recorded. New balance '+cents(d.balance_cents)+'.')};
  el.querySelector('#afsvc').onsubmit=e=>{e.preventDefault();const a=C.toCents(el.querySelector('#asa').value);if(!a){msg='Enter an amount';ok=false;return draw()}
   run('admin_charge_service',{p_vendor:el.querySelector('#asv').value,p_kind:el.querySelector('#ask').value,p_amount_cents:a,p_note:el.querySelector('#asn').value||null},b=>'Charged '+cents(b.total_cents)+(Number(b.invoice_cents)>0?' ('+cents(b.invoice_cents)+' invoiced: not enough funds)':'')+'.')};
  el.querySelector('#afflags').onsubmit=e=>{e.preventDefault();let pp;try{pp=JSON.parse(el.querySelector('#ffpp').value)}catch(x){msg='Points prices must be JSON, e.g. {"plus":100}';ok=false;return draw()}
   run('admin_set_flags',{p:{wallet_mode:el.querySelector('#ffw').value,rewards_enabled:el.querySelector('#ffr').checked,vendor_credit_enabled:el.querySelector('#ffc').checked,gift_cards_enabled:el.querySelector('#ffg').checked,
    fee_card_pct:+el.querySelector('#ffcp').value,fee_direct_pct:+el.querySelector('#ffdp').value,fee_refund_pct:+el.querySelector('#ffrp').value,
    giftcard_tiers:[...el.querySelectorAll('[data-tier]:checked')].map(x=>x.dataset.tier),giftcard_points_per_ec:pp,giftcard_cap_cents_month:Math.round(+el.querySelector('#ffcap').value*100)}},()=>'Flags saved.')};
  if(location.hash==='#exits'){const x=el.querySelector('#exits');if(x)x.scrollIntoView()}
 };
 await draw();
}
C.adminFunds={mount};
})();
