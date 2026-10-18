// Vendor applications + vendor status for the platform operator (v1.6). Platform admins only; every action goes through admin_app_* /
// admin_vendor_set_status / admin_assign_owner database functions that re-check the admin role and write the audit log. Needs supabase/vendor_onboarding.sql.
// The admin sees applicant phone / WhatsApp / VAT / registration numbers here because they run the platform. The public never sees them.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,PAGE=25;
const missing=m=>/Could not find the function|schema cache|PGRST202|404/.test(m||'');
const offBox='<div class="notice">Vendor applications are not switched on yet. In Supabase, open the SQL Editor and run <code>supabase/vendor_onboarding.sql</code> (see README.txt), then refresh.</div>';
const ST={pending:['Waiting','st-placed'],changes_requested:['Changes requested','st-ready'],approved:['Approved','st-completed'],suspended:['Suspended','st-cancelled'],rejected:['Rejected','st-cancelled']};
const chip=s=>{const [l,c]=ST[s]||[s,''];return '<span class="st '+c+'">'+esc(l)+'</span>'};
const BT={sole_trader:'Sole trader',company:'Company',cooperative:'Cooperative / group',nonprofit:'Non-profit',other:'Other'};
const CATS={food:'Food & Spices',crafts:'Crafts & Art',fashion:'Fashion & Textiles',beauty:'Beauty & Wellness',sea:'Sea & Boating',home:'Home & Garden'};
const ACT={onb_applied:'Applied',onb_updated:'Application edited and resubmitted',onb_approved:'Approved',onb_rejected:'Rejected',onb_changes_requested:'Changes requested',onb_suspended:'Suspended',onb_reinstated:'Reinstated',onb_owner_assigned:'Owner assigned',onb_owner_reassigned:'Owner reassigned',onb_owner_transferred:'Owner transferred by the owner',onb_payment_info:'Payment information saved'};
let seq=0;
const S={q:'',status:'pending',page:0,open:null};
async function mount(el,sb){
 const my=++seq;
 const rpc=async(fn,a)=>{const r=await sb.rpc(fn,a);if(r.error)throw r.error;return r.data};
 const fail=e=>{const m=(e&&e.message)||'Something went wrong.';el.innerHTML=missing(m)?offBox:'<div class="notice err" role="alert">'+esc(m)+'</div>'};
 async function list(flash){
  const box=el.querySelector('#ap-res');if(!box)return;
  let d;try{d=await rpc('admin_app_list',{p_q:S.q||null,p_status:S.status,p_limit:PAGE,p_offset:S.page*PAGE})}catch(e){if(my!==seq)return;fail(e);return}
  if(my!==seq)return;
  const pages=Math.max(1,Math.ceil(d.total/PAGE));
  const c=d.counts||{};
  el.querySelector('#ap-counts').innerHTML=[['pending','Waiting'],['changes_requested','Changes requested'],['approved','Approved'],['suspended','Suspended'],['rejected','Rejected'],['sample','Sample'],['all','All']].map(([k,l])=>'<button type="button" class="ap-chipbtn'+(S.status===k?' on':'')+'" data-st="'+k+'">'+esc(l)+' <b>'+(c[k]||0)+'</b></button>').join('');
  el.querySelectorAll('[data-st]').forEach(b=>b.onclick=()=>{S.status=b.dataset.st;S.page=0;el.querySelector('#ap-st').value=S.status;list()});
  const sw=el.querySelector('#ap-samples');
  sw.innerHTML='<span>SAMPLE vendors are currently <b>'+(d.hide_samples?'hidden':'visible')+'</b> to shoppers.</span> <button type="button" class="btn ghost sm" id="ap-tog">'+(d.hide_samples?'Show sample vendors':'Hide sample vendors')+'</button>';
  sw.querySelector('#ap-tog').onclick=async()=>{if(!confirm(d.hide_samples?'Show the SAMPLE vendors and products to shoppers again?':'Hide all SAMPLE vendors and products from shoppers? (Real vendors are not affected.)'))return;
   try{await rpc('admin_set_hide_samples',{p_hide:!d.hide_samples,p_reason:null});list(d.hide_samples?'Sample vendors are visible again.':'Sample vendors are hidden from shoppers.')}catch(e){list();alert(e.message)}};
  box.innerHTML=(flash?'<div class="notice ok" role="status">'+esc(flash)+'</div>':'')+(d.rows.length?'<div class="tblwrap"><table class="admtab"><thead><tr><th>Business</th><th>Status</th><th>Owner</th><th>Where</th><th>Asked for</th><th>Applied</th><th></th></tr></thead><tbody>'+d.rows.map(r=>'<tr><td><b>'+esc(r.name)+'</b>'+(r.is_sample?' <span class="pp pp-unpaid">SAMPLE</span>':'')+'<small>'+esc(CATS[r.category]||'')+'</small></td><td>'+chip(r.status)+'</td><td>'+esc(r.owner_email||'no owner')+'<small>'+esc(r.owner_name||'')+'</small></td><td>'+esc(r.area?r.area+', '+r.island:'')+'</td><td>'+(r.requested_tier?esc(CC.TIER_LABEL[r.requested_tier]):'<span class="muted">n/a</span>')+'</td><td>'+(r.submitted_at?esc(CC.fdate(r.submitted_at)):'<span class="muted">before v1.6</span>')+'</td><td><button class="btn sm" data-open="'+esc(r.id)+'">Review</button></td></tr>').join('')+'</tbody></table></div>':'<p class="muted">Nothing here.</p>')+
   '<div class="cu-pager"><span class="muted">'+(d.rows.length?'Showing '+(d.offset+1)+'–'+(d.offset+d.rows.length)+' of '+d.total:'0 businesses')+'</span><span><button class="btn ghost sm" id="ap-prev"'+(S.page<=0?' disabled':'')+'>Previous</button> <span class="muted">Page '+(S.page+1)+' of '+pages+'</span> <button class="btn ghost sm" id="ap-next"'+(S.page+1>=pages?' disabled':'')+'>Next</button></span></div>';
  box.querySelectorAll('[data-open]').forEach(b=>b.onclick=()=>{S.open=b.dataset.open;detail()});
  box.querySelector('#ap-prev').onclick=()=>{S.page=Math.max(0,S.page-1);list()};box.querySelector('#ap-next').onclick=()=>{S.page++;list()};
 }
 function shell(){
  el.innerHTML='<h2>Applications &amp; vendors</h2><p class="muted">Review businesses that want to sell, approve or reject them, and suspend or reinstate a business. You see applicant phone numbers and ID numbers here because you run the platform; shoppers never do. Every action is saved to the audit log. No email is sent: applicants see the result on their Application status page.</p>'+
  '<div class="ap-samples" id="ap-samples"></div><div class="ap-counts" id="ap-counts" role="group" aria-label="Filter by status"></div>'+
  '<form class="cu-filters" id="ap-f" role="search"><label class="cu-q">Search<input id="ap-q" type="search" maxlength="100" placeholder="Business, owner name, email, phone or area" value="'+esc(S.q)+'" autocomplete="off"></label>'+
  '<label>Status<select id="ap-st"><option value="all">All</option><option value="pending">Waiting</option><option value="changes_requested">Changes requested</option><option value="approved">Approved</option><option value="suspended">Suspended</option><option value="rejected">Rejected</option><option value="sample">Sample vendors</option></select></label></form><div id="ap-res" aria-live="polite"><p class="muted">Loading…</p></div>';
  const q=el.querySelector('#ap-q');el.querySelector('#ap-st').value=S.status;let t=null;const go=()=>{S.q=q.value.trim();S.page=0;list()};
  q.oninput=()=>{clearTimeout(t);t=setTimeout(go,300)};el.querySelector('#ap-f').onsubmit=e=>{e.preventDefault();clearTimeout(t);go()};
  el.querySelector('#ap-st').onchange=e=>{S.status=e.target.value;S.page=0;list()};
  list();
 }
 async function detail(flash){
  const id=S.open;el.innerHTML='<p class="muted">Loading…</p>';
  let d;try{d=await rpc('admin_app_get',{p_vendor:id})}catch(e){if(my!==seq)return;if(missing(e.message)){el.innerHTML=offBox;return}S.open=null;shell();el.insertAdjacentHTML('afterbegin','<div class="notice err" role="alert">'+esc(e.message)+'</div>');return}
  if(my!==seq)return;
  const a=d.application,st=d.status,waiting=st==='pending',canApprove=['pending','changes_requested','rejected'].includes(st);
  const kv=(k,v)=>'<tr><th scope="row">'+esc(k)+'</th><td>'+(v==null||v===''?'<span class="muted">—</span>':esc(v))+'</td></tr>';
  const hist=h=>{const x=h.details||{};return '<li><b>'+esc(ACT[h.action]||h.action)+'</b> by '+esc(h.by||'the applicant')+' · '+esc(CC.fdate(h.at))+(x.reason?'<small>Reason: '+esc(x.reason)+'</small>':'')+(x.new_owner?'<small>New owner: '+esc(x.new_owner)+(x.old_owner?' (was '+esc(x.old_owner)+')':'')+(x.old_owner_role?' · old owner kept as '+esc(x.old_owner_role):'')+'</small>':'')+(x.tier?'<small>Plan: '+esc(CC.TIER_LABEL[x.tier]||x.tier)+'</small>':'')+'</li>'};
  el.innerHTML='<p><button class="btn ghost sm" id="ap-back">← All applications</button></p><div id="ap-msg" role="alert">'+(flash?'<div class="notice ok">'+esc(flash)+'</div>':'')+'</div>'+
  '<div class="cu-head"><h2>'+esc(d.name)+' '+chip(st)+(d.is_sample?' <span class="pp pp-unpaid">SAMPLE</span>':'')+'</h2><p class="muted">Created '+esc(CC.fdate(d.created_at))+' · plan '+esc(CC.TIER_LABEL[d.tier]||d.tier)+' · '+d.active_products+' active of '+d.products+' products · '+d.orders+' orders</p></div>'+
  (d.status_reason?'<div class="notice '+(st==='suspended'||st==='rejected'?'err':'')+'">Last message ('+esc(st.replace('_',' '))+'): <b>'+esc(d.status_reason)+'</b></div>':'')+
  '<div class="cu-grid"><section class="cu-card"><h3>Application</h3>'+(a?'<table class="kvtab"><tbody>'+kv('Description',d.description)+kv('Category',CATS[a.category]||a.category)+kv('Business type',BT[a.business_type]||a.business_type)+kv('Where',a.area+', '+a.island)+kv('Wants',(a.offers_pickup?'Pickup ':'')+(a.offers_delivery?'Delivery':''))+kv('Asked for plan',CC.TIER_LABEL[a.requested_tier]||a.requested_tier)+kv('VAT registered',a.vat_registered?'Yes, '+(a.vat_number||''):'No')+kv('Registration / ID',a.registration_number)+kv('Terms accepted',a.terms_version+' on '+CC.fdate(a.terms_accepted_at))+kv('Submitted',CC.fdate(a.submitted_at))+(a.resubmitted_at?kv('Resubmitted',CC.fdate(a.resubmitted_at)):'')+'</tbody></table>':'<p class="muted">No application on file (this business existed before applications, or was created by an admin). It was approved automatically when applications were switched on.</p>'+'<table class="kvtab"><tbody>'+kv('Description',d.description)+kv('Location',d.location)+'</tbody></table>')+
  '<h3>Private contact (admin only)</h3><table class="kvtab"><tbody>'+kv('Owner',d.owner_name)+kv('Owner email',d.owner_email)+kv('Owner phone',d.owner_phone)+(a?kv('Business phone',a.phone)+kv('WhatsApp',a.whatsapp):'')+kv('Payment information',d.payment_info)+'</tbody></table></section>'+
  '<section class="cu-card"><h3>Decision</h3>'+
  (canApprove?'<form id="ap-approve" novalidate><label>Plan to give them<select id="d-tier">'+CC.TIERS.map(t=>'<option value="'+t.k+'"'+((a&&a.requested_tier||d.tier)===t.k?' selected':'')+'>'+esc(t.name)+'</option>').join('')+'</select></label><label>Note to the applicant (optional)<input id="d-ok" maxlength="300"></label><button class="btn" type="submit">Approve'+(st==='rejected'?' (reverse rejection)':'')+'</button></form>':'')+
  (waiting||st==='changes_requested'?'<form id="ap-rej" novalidate><label>Reason (the applicant sees this)<input id="d-reason" maxlength="300" placeholder="e.g. We could not verify the business"></label>'+(waiting?'<button class="btn ghost" type="button" id="d-chg">Request changes</button> ':'')+'<button class="btn danger" type="button" id="d-rej">Reject</button></form>':'')+
  (st==='approved'?'<form id="ap-sus" novalidate><label>Reason for suspending<input id="s-reason" maxlength="300" required placeholder="e.g. Repeated complaints"></label><button class="btn danger" type="submit">Suspend business</button></form><p class="muted">A suspended business is hidden from shoppers and cannot receive new orders. It can still see and finish existing orders.</p>':'')+
  (st==='suspended'?'<form id="ap-reins" novalidate><label>Reason for reinstating<input id="s-reason" maxlength="300" required placeholder="e.g. Issue resolved"></label><button class="btn" type="submit">Reinstate business</button></form>':'')+
  (!canApprove&&st!=='approved'&&st!=='suspended'?'':'')+
  '<h3>Owner</h3><p>'+(d.owner_id?'Owner: <b>'+esc(d.owner_email)+'</b>.':'<b>No owner.</b> '+(d.is_sample?'This is a SAMPLE business.':''))+'</p>'+
  '<form id="ap-own" novalidate><label>'+(d.owner_id?'Reassign to (customer email)':'Give to (customer email)')+'<input id="o-email" type="email" maxlength="254" placeholder="person@example.com"></label>'+
  (d.is_sample?'<label>New business name (optional, removes the SAMPLE look)<input id="o-name" maxlength="80" value="'+esc(d.name.replace(/^SAMPLE\s+/i,''))+'"></label>':'')+
  '<label>Reason<input id="o-reason" maxlength="300" placeholder="e.g. Real shop takes over this listing"></label><button class="btn ghost" type="submit">'+(d.owner_id?'Reassign owner':'Assign owner')+'</button></form>'+
  '<p class="muted">'+(d.is_sample?'Assigning an owner turns the SAMPLE business into a real one. Its sample products stay until the owner edits or deletes them.':'The previous owner becomes a sub-admin when the plan has a free sub-admin seat; otherwise they lose access. Wallet and orders stay with the business.')+'</p></section></div>'+
  '<section class="cu-card"><h3>History</h3>'+(d.history.length?'<ul class="auditlist">'+d.history.map(hist).join('')+'</ul>':'<p class="muted">No onboarding actions yet.</p>')+'</section>';
  const msg=(t,ok)=>{const m=el.querySelector('#ap-msg');m.innerHTML=t?'<div class="notice '+(ok?'ok':'err')+'">'+esc(t)+'</div>':'';if(t)m.scrollIntoView({block:'nearest'})};
  const act=async(fn,args,okMsg)=>{el.querySelectorAll('button').forEach(b=>b.disabled=true);try{await rpc(fn,args);await detail(okMsg)}catch(e){el.querySelectorAll('button').forEach(b=>b.disabled=false);msg(e.message||'Could not save.',false)}};
  el.querySelector('#ap-back').onclick=()=>{S.open=null;shell()};
  const g=s=>el.querySelector(s);
  if(g('#ap-approve'))g('#ap-approve').onsubmit=e=>{e.preventDefault();if(!confirm('Approve '+d.name+' on the '+CC.TIER_LABEL[g('#d-tier').value]+' plan?'))return;act('admin_app_decide',{p_vendor:id,p_decision:'approve',p_reason:g('#d-ok').value.trim()||null,p_tier:g('#d-tier').value},'Approved. The applicant will see this on their Application status page.')};
  const needReason=()=>{const r=g('#d-reason').value.trim();if(r.length<3){msg('Please give a reason (at least 3 characters).',false);return null}return r};
  if(g('#d-rej'))g('#d-rej').onclick=()=>{const r=needReason();if(!r||!confirm('Reject this application?'))return;act('admin_app_decide',{p_vendor:id,p_decision:'reject',p_reason:r,p_tier:null},'Rejected.')};
  if(g('#d-chg'))g('#d-chg').onclick=()=>{const r=needReason();if(!r)return;act('admin_app_decide',{p_vendor:id,p_decision:'request_changes',p_reason:r,p_tier:null},'Changes requested. The applicant can edit and resubmit.')};
  if(g('#ap-rej'))g('#ap-rej').onsubmit=e=>e.preventDefault();
  const stForm=(sel,action,okMsg,q)=>{if(g(sel))g(sel).onsubmit=e=>{e.preventDefault();const r=g('#s-reason').value.trim();if(r.length<3){msg('Please give a reason (at least 3 characters).',false);return}if(!confirm(q))return;act('admin_vendor_set_status',{p_vendor:id,p_action:action,p_reason:r},okMsg)}};
  stForm('#ap-sus','suspend','Business suspended.','Suspend '+d.name+'? Shoppers will not see it or be able to order.');
  stForm('#ap-reins','reinstate','Business reinstated.','Reinstate '+d.name+'?');
  g('#ap-own').onsubmit=e=>{e.preventDefault();const em=g('#o-email').value.trim(),r=g('#o-reason').value.trim();
   if(!em){msg('Enter the customer\'s email address.',false);return}if(r.length<3){msg('Please give a reason (at least 3 characters).',false);return}
   if(!confirm((d.owner_id?'Reassign ':'Assign ')+d.name+' to '+em+'?'))return;
   act('admin_assign_owner',{p_vendor:id,p_email:em,p_reason:r,p_new_name:g('#o-name')?g('#o-name').value.trim()||null:null},d.owner_id?'Owner reassigned.':'Owner assigned. This business is now a real vendor.')};
 }
 if(S.open)detail();else shell();
}
CC.applications={mount,pendingCount:async sb=>{try{const r=await sb.rpc('admin_app_list',{p_q:null,p_status:'pending',p_limit:1,p_offset:0});return r.error?0:(r.data.total||0)}catch(e){return 0}}};
})();
