// Customer profile management for the platform operator (v1.4, TEST MODE). Platform admins only; every action goes through
// admin_cust_* database functions that re-check the admin role, and each change is written to the audit log. Needs supabase/admin_customers.sql.
// Emails and phones are shown here because the admin is the operator; other pages stay masked. Wallet figures are read-only play money.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,PAGE=25;
const missing=m=>/Could not find the function|schema cache|PGRST202|404/.test(m||'');
const offBox='<div class="notice">Customer management is not switched on yet. In Supabase, open the SQL Editor and run <code>supabase/admin_customers.sql</code> (see README.txt), then refresh.</div>';
const ST={active:['Active','pp-paid'],suspended:['Suspended','pp-unpaid']};
const chip=s=>{const [l,c]=ST[s]||ST.active;return `<span class="pp ${c} cu-chip">${l}</span>`};
const money=n=>'EC$'+(Number(n)||0).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});
const ROLE={consumer:'Customer',vendor:'Vendor account'};
const TX={topup_test:'Test top-up',transfer:'Transfer',order_payment:'Order payment',refund:'Refund',adjustment:'Adjustment'};
const ACT={customer_edited:'Details edited',customer_suspended:'Suspended',customer_reactivated:'Reactivated',customer_role_changed:'Role changed'};
const fld={name:'Name',phone:'Phone',address:'Address',notes:'Notes',status:'Status',role:'Role'};
let seq=0;
const S={q:'',status:'all',role:'consumer',page:0,open:null};

async function mount(el,sb){
 const my=++seq;S.open=S.open||null;
 const rpc=async(fn,a)=>{const r=await sb.rpc(fn,a);if(r.error)throw r.error;return r.data};
 const fail=e=>{const m=(e&&e.message)||'Something went wrong.';el.innerHTML=missing(m)?offBox:'<div class="notice err" role="alert">'+esc(m)+'</div>'};
 async function list(){
  const box=el.querySelector('#cu-res');if(!box)return;
  box.setAttribute('aria-busy','true');
  let d;try{d=await rpc('admin_cust_list',{p_q:S.q||null,p_status:S.status,p_role:S.role,p_limit:PAGE,p_offset:S.page*PAGE})}catch(e){if(my!==seq)return;if(missing(e.message)){el.innerHTML=offBox;return}box.innerHTML='<div class="notice err" role="alert">'+esc(e.message)+'</div>';return}
  if(my!==seq||!el.contains(box))return;
  const pages=Math.max(1,Math.ceil(d.total/PAGE));
  if(S.page>0&&!d.rows.length){S.page=pages-1;return list()}
  box.removeAttribute('aria-busy');
  box.innerHTML=(d.rows.length?`<div class="tblwrap"><table class="admtab cu-tab"><thead><tr><th>Name</th><th>Email</th><th>Phone</th><th>Status</th><th>Joined</th><th>Orders</th><th>Wallet <small>(play money)</small></th><th></th></tr></thead><tbody>${d.rows.map(r=>`<tr data-id="${esc(r.id)}"><td><b>${esc(r.name||'(no name)')}</b>${r.role!=='consumer'?`<small>${esc(ROLE[r.role]||r.role)}</small>`:''}</td><td>${esc(r.email||'')}</td><td>${esc(r.phone||'—')}</td><td>${chip(r.status)}</td><td>${esc(CC.fdate(r.joined).replace(/,? \d{1,2}:\d\d.*$/,''))}</td><td>${r.orders}</td><td>${r.wallet_cents==null?'<span class="muted">none</span>':esc(CC.cents(r.wallet_cents))}</td><td><button class="btn sm" data-open="${esc(r.id)}" aria-label="Manage ${esc(r.name||r.email||'customer')}">Manage</button></td></tr>`).join('')}</tbody></table></div>`
   :'<div class="empty small"><div class="empty-ic" aria-hidden="true">🔎</div><p>'+(S.q||S.status!=='all'?'No one matches that search.':'No customers yet.')+'</p></div>')+
   `<div class="cu-pager"><span class="muted" id="cu-count">${d.total?`Showing ${d.offset+1}–${d.offset+d.rows.length} of ${d.total}`:'0 people'}</span><span><button class="btn ghost sm" id="cu-prev" ${S.page<=0?'disabled':''}>Previous</button> <span class="muted">Page ${S.page+1} of ${pages}</span> <button class="btn ghost sm" id="cu-next" ${S.page+1>=pages?'disabled':''}>Next</button></span></div>`;
  box.querySelectorAll('[data-open]').forEach(b=>b.onclick=()=>{S.open=b.dataset.open;detail()});
  const pv=box.querySelector('#cu-prev'),nx=box.querySelector('#cu-next');
  pv.onclick=()=>{S.page=Math.max(0,S.page-1);list()};nx.onclick=()=>{S.page++;list()};
 }
 function shell(){
  el.innerHTML=`<h2>Customers</h2><p class="muted">Look up and manage customer accounts. You can see emails and phones here because you run the platform. Every change is saved to the audit log with your name and a reason.</p>
  <form class="cu-filters" id="cu-f" role="search"><label class="cu-q">Search<input id="cu-q" type="search" maxlength="100" placeholder="Name, email or phone" value="${esc(S.q)}" autocomplete="off"></label>
  <label>Show<select id="cu-role"><option value="consumer">Customers</option><option value="vendor">Vendor accounts</option><option value="all">Everyone (not admins)</option></select></label>
  <label>Status<select id="cu-st"><option value="all">All</option><option value="active">Active</option><option value="suspended">Suspended</option></select></label></form>
  <div id="cu-res" aria-live="polite"><p class="muted">Loading…</p></div>`;
  const f=el.querySelector('#cu-f'),q=el.querySelector('#cu-q');el.querySelector('#cu-role').value=S.role;el.querySelector('#cu-st').value=S.status;
  let t=null;const go=()=>{S.q=q.value.trim();S.page=0;list()};
  q.oninput=()=>{clearTimeout(t);t=setTimeout(go,300)};f.onsubmit=e=>{e.preventDefault();clearTimeout(t);go()};
  el.querySelector('#cu-role').onchange=e=>{S.role=e.target.value;S.page=0;list()};el.querySelector('#cu-st').onchange=e=>{S.status=e.target.value;S.page=0;list()};
  list();
 }
 async function detail(flash){
  const id=S.open;el.innerHTML='<p class="muted">Loading…</p>';
  let d;try{d=await rpc('admin_cust_get',{p_id:id})}catch(e){if(my!==seq)return;if(missing(e.message)){el.innerHTML=offBox;return}S.open=null;shell();el.insertAdjacentHTML('afterbegin','<div class="notice err" role="alert">'+esc(e.message)+'</div>');return}
  if(my!==seq)return;
  const sus=d.status==='suspended',o=d.orders,w=d.wallet;
  const diff=h=>{const b=h.details&&h.details.before||{},a=h.details&&h.details.after||{};return Object.keys(a).map(k=>`${esc(fld[k]||k)}: <s>${esc(b[k]==null?'(blank)':b[k])}</s> → <b>${esc(a[k]==null?'(blank)':a[k])}</b>`).join('; ')};
  el.innerHTML=`<p><button class="btn ghost sm" id="cu-back">← All customers</button></p><div id="cu-msg" role="alert">${flash?`<div class="notice ok">${esc(flash)}</div>`:''}</div>
  <div class="cu-head"><h2>${esc(d.name||'(no name)')} ${chip(d.status)}</h2><p class="muted">${esc(ROLE[d.role]||d.role)} · joined ${esc(CC.fdate(d.joined))}</p></div>
  ${sus?`<div class="notice err">Suspended${d.suspended_at?' on '+esc(CC.fdate(d.suspended_at)):''}. Reason: <b>${esc(d.reason||'')}</b>. This person cannot place orders, check out or use their wallet. They will see a message when they log in or check out.</div>`:''}
  <div class="kpis cu-kpis"><div class="kpi"><span>Orders</span><b>${o.count}</b><small>${o.cancelled} cancelled</small></div><div class="kpi"><span>Order value</span><b>${esc(money(o.sales_xcd))}</b><small>not cancelled or refunded</small></div><div class="kpi"><span>Wallet (play money)</span><b>${w.exists?esc(CC.cents(w.balance_cents)):'None'}</b><small>read-only</small></div><div class="kpi"><span>Last order</span><b class="cu-sm">${o.last_order_at?esc(CC.fdate(o.last_order_at)):'—'}</b></div></div>
  <div class="cu-grid">
  <section class="cu-card"><h3>Profile</h3><form id="cu-edit" novalidate>
   <label>Email <input value="${esc(d.email||'')}" readonly aria-describedby="cu-em"></label><small id="cu-em" class="muted">Email is managed by sign-in and can't be changed here.</small>
   <label>Name<input id="e-name" maxlength="80" value="${esc(d.name||'')}"></label>
   <label>Phone<input id="e-phone" maxlength="30" inputmode="tel" value="${esc(d.phone||'')}"></label>
   <label>Address<textarea id="e-addr" rows="2" maxlength="300">${esc(d.address||'')}</textarea></label>
   <label>Internal notes <small class="muted">(only admins see these)</small><textarea id="e-notes" rows="3" maxlength="1000">${esc(d.admin_notes||'')}</textarea></label>
   <label>Reason for this change<input id="e-reason" maxlength="300" placeholder="e.g. Customer asked by phone" required></label>
   <button class="btn" type="submit">Save changes</button></form></section>
  <section class="cu-card"><h3>Account status</h3>
   <p>${sus?'This account is <b>suspended</b>.':'This account is <b>active</b>.'}</p>
   <form id="cu-status" novalidate><label>${sus?'Reason for reactivating':'Reason for suspending'}<input id="s-reason" maxlength="300" required placeholder="${sus?'e.g. Appeal accepted':'e.g. Repeated fake orders'}"></label>
   <button class="btn ${sus?'':'danger'}" type="submit">${sus?'Reactivate account':'Suspend account'}</button></form>
   <p class="muted">Suspending stops new orders, checkout, wallet payments, transfers and top-ups straight away, even if they are already logged in. Money owed back to them (refunds) still goes through. Nothing is deleted.</p>
   <h3>Role</h3><form id="cu-role-f" novalidate><label>Account type<select id="r-role"><option value="consumer"${d.role==='consumer'?' selected':''}>Customer</option><option value="vendor"${d.role==='vendor'?' selected':''}>Vendor account</option></select></label>
   <label>Reason<input id="r-reason" maxlength="300" required placeholder="e.g. Opening a shop"></label><button class="btn ghost" type="submit">Change role</button></form>
   <p class="muted">${d.businesses.length?'Owns: '+d.businesses.map(b=>esc(b.name)).join(', ')+'. Hand over or remove the business before making them a customer.':'Admin rights cannot be given from this page.'}</p></section></div>
  <section class="cu-card"><h3>Order history <span class="nbadge">${o.count}</span></h3>${o.recent.length?`<div class="tblwrap"><table class="admtab"><thead><tr><th>Order</th><th>Business</th><th>Placed</th><th>Status</th><th>Payment</th><th>Total</th></tr></thead><tbody>${o.recent.map(r=>`<tr><td><b>${esc(r.order_number)}</b></td><td>${esc(r.vendor||'')}</td><td>${esc(CC.fdate(r.created_at))}</td><td>${esc(r.status)}</td><td>${esc(r.payment_status)}</td><td>${esc(money(r.total_xcd))}</td></tr>`).join('')}</tbody></table></div>${o.count>o.recent.length?`<p class="muted">Showing the latest ${o.recent.length} of ${o.count}.</p>`:''}`:'<p class="muted">No orders yet.</p>'}</section>
  <section class="cu-card"><h3>Wallet <span class="pp pp-unpaid">TEST MODE</span></h3>${w.exists?`<p>Code <b>${esc(w.code)}</b> · balance <b>${esc(CC.cents(w.balance_cents))}</b> · received ${esc(CC.cents(w.received_cents))} · sent ${esc(CC.cents(w.sent_cents))} · ${w.transactions} transactions. <span class="muted">Read-only play money. This page cannot move money.</span></p>${w.recent.length?`<div class="tblwrap"><table class="admtab"><thead><tr><th>When</th><th>Type</th><th>Amount</th></tr></thead><tbody>${w.recent.map(t=>`<tr><td>${esc(CC.fdate(t.at))}</td><td>${esc(TX[t.type]||t.type)}${t.note?`<small>${esc(t.note)}</small>`:''}</td><td>${t.direction==='in'?'+':'−'}${esc(CC.cents(t.amount_cents))}</td></tr>`).join('')}</tbody></table></div>`:''}`:'<p class="muted">No wallet yet (created the first time they open Wallet).</p>'}</section>
  <section class="cu-card"><h3>Admin history</h3>${d.history.length?`<ul class="auditlist">${d.history.map(h=>`<li><b>${esc(ACT[h.action]||h.action)}</b> by ${esc(h.by||'an admin')} · ${esc(CC.fdate(h.at))}<small>Reason: ${esc(h.details&&h.details.reason||'')}</small><small>${diff(h)}</small></li>`).join('')}</ul>`:'<p class="muted">No admin actions on this account yet.</p>'}</section>`;
  const msg=(t,ok)=>{const m=el.querySelector('#cu-msg');m.innerHTML=t?`<div class="notice ${ok?'ok':'err'}">${esc(t)}</div>`:'';if(t)m.scrollIntoView({block:'nearest'})};
  const act=async(btn,fn,args,okMsg)=>{el.querySelectorAll('button').forEach(b=>b.disabled=true);try{await rpc(fn,args);await detail(okMsg)}catch(e){el.querySelectorAll('button').forEach(b=>b.disabled=false);msg(e.message||'Could not save.',false)}};
  el.querySelector('#cu-back').onclick=()=>{S.open=null;shell()};
  el.querySelector('#cu-edit').onsubmit=e=>{e.preventDefault();const r=el.querySelector('#e-reason').value.trim();
   act(e.target.querySelector('button'),'admin_cust_update',{p_id:id,p_name:el.querySelector('#e-name').value,p_phone:el.querySelector('#e-phone').value,p_address:el.querySelector('#e-addr').value,p_notes:el.querySelector('#e-notes').value,p_reason:r},'Saved. The change is in the audit log.')};
  el.querySelector('#cu-status').onsubmit=e=>{e.preventDefault();const r=el.querySelector('#s-reason').value.trim();
   if(r.length<3){msg('Please give a reason (at least 3 characters).',false);return}
   if(!confirm(sus?'Reactivate this account?':'Suspend this account? They will not be able to order or use their wallet.'))return;
   act(e.target.querySelector('button'),'admin_cust_set_status',{p_id:id,p_suspend:!sus,p_reason:r},sus?'Account reactivated.':'Account suspended.')};
  el.querySelector('#cu-role-f').onsubmit=e=>{e.preventDefault();const r=el.querySelector('#r-reason').value.trim(),to=el.querySelector('#r-role').value;
   if(to===d.role){msg('Choose a different account type first.',false);return}
   if(r.length<3){msg('Please give a reason (at least 3 characters).',false);return}
   if(!confirm('Change this account to '+(ROLE[to]||to)+'?'))return;
   act(e.target.querySelector('button'),'admin_cust_set_role',{p_id:id,p_role:to,p_reason:r},'Role changed.')};
 }
 if(S.open)detail();else shell();
}
CC.customers={mount};
})();
