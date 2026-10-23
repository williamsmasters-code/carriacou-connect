// Admin > Vendors (v1.6b): manage business accounts, like the Customers tab. Platform admins only; every action calls an admin_vend_* database function
// that re-checks the admin role, requires a reason (3-300 characters) and writes the audit log with before/after. Needs supabase/vendor_onboarding.sql.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,PAGE=25;
const missing=m=>/Could not find the function|schema cache|PGRST202|404/.test(m||'');
const offBox='<div class="notice">The Vendors tab is not switched on yet. In Supabase, run <code>supabase/vendor_onboarding.sql</code> (see README.txt), then refresh.</div>';
const ST={pending:['Waiting','st-placed'],changes_requested:['Changes requested','st-ready'],approved:['Approved','st-completed'],suspended:['Suspended','st-cancelled'],rejected:['Rejected','st-cancelled']};
const chip=s=>{const x=ST[s]||[s,''];return '<span class="st '+x[1]+'">'+esc(x[0])+'</span>'};
const CATS={food:'Food & Spices',crafts:'Crafts & Art',fashion:'Fashion & Textiles',beauty:'Beauty & Wellness',sea:'Sea & Boating',home:'Home & Garden'};
const ISL=['Carriacou','Petite Martinique','Grenada'];
const ACT={onb_applied:'Applied',onb_updated:'Application edited',onb_approved:'Approved',onb_rejected:'Rejected',onb_changes_requested:'Changes requested',onb_suspended:'Suspended',onb_reinstated:'Reinstated',onb_owner_assigned:'Owner assigned',onb_owner_reassigned:'Owner reassigned',onb_owner_transferred:'Owner transferred',vend_profile_edited:'Profile edited by admin',vend_tier_changed:'Plan changed by admin',tier_change_reason:'Plan change note'};
const money=n=>'EC$'+(+n||0).toFixed(2);
let seq=0;const S={q:'',status:'all',tier:'all',page:0,open:null};
async function mount(el,sb){
 const my=++seq;
 const rpc=async(fn,a)=>{const r=await sb.rpc(fn,a);if(r.error)throw r.error;return r.data};
 const fail=e=>{const m=(e&&e.message)||'Something went wrong.';el.innerHTML=missing(m)?offBox:'<div class="notice err" role="alert">'+esc(m)+'</div>'};
 const g=s=>el.querySelector(s);
 async function list(flash){
  const box=g('#vd-res');if(!box)return;let d;
  try{d=await rpc('admin_vend_list',{p_q:S.q||null,p_status:S.status,p_tier:S.tier,p_limit:PAGE,p_offset:S.page*PAGE})}catch(e){if(my!==seq)return;fail(e);return}
  if(my!==seq)return;
  const pages=Math.max(1,Math.ceil(d.total/PAGE)),c=d.counts||{};
  g('#vd-counts').innerHTML=[['all','All'],['pending','Waiting'],['approved','Approved'],['suspended','Suspended'],['rejected','Rejected'],['sample','Sample']].map(x=>'<button type="button" class="ap-chip'+(S.status===x[0]?' on':'')+'" data-st="'+x[0]+'">'+x[1]+' <b>'+(c[x[0]]||0)+'</b></button>').join('');
  el.querySelectorAll('[data-st]').forEach(b=>b.onclick=()=>{S.status=b.dataset.st;S.page=0;g('#vd-st').value=S.status;list()});
  const sw=g('#vd-samples');
  sw.innerHTML='<span>SAMPLE vendors are currently <b>'+(d.hide_samples?'hidden':'visible')+'</b> to shoppers.</span> <button type="button" class="btn ghost sm" id="vd-tog">'+(d.hide_samples?'Show sample vendors':'Hide sample vendors')+'</button>';
  g('#vd-tog').onclick=async()=>{const r=prompt((d.hide_samples?'Show':'Hide')+' all SAMPLE vendors and products? Give a reason (3-300 characters):');if(r===null)return;
   try{await rpc('admin_vend_set_hide_samples',{p_hide:!d.hide_samples,p_reason:r.trim()});list(d.hide_samples?'Sample vendors are visible again.':'Sample vendors are hidden from shoppers.')}catch(e){list();alert(e.message)}};
  box.innerHTML=(flash?'<div class="notice ok" role="status">'+esc(flash)+'</div>':'')+(d.rows.length?'<div class="tblwrap"><table class="admtab"><thead><tr><th>Business</th><th>Owner</th><th>Category</th><th>Area</th><th>Status</th><th>Plan</th><th>Joined</th><th>Products</th><th>Orders</th><th>Revenue</th><th></th></tr></thead><tbody>'+
   d.rows.map(r=>'<tr><td><b>'+esc(r.name)+'</b>'+(r.is_sample?' <span class="pp pp-unpaid">SAMPLE</span>':'')+'</td><td>'+(r.owner_email?esc(r.owner_name||'')+'<small class="muted"> '+esc(r.owner_email)+'</small>':'<span class="muted">No owner</span>')+'</td><td>'+esc(CATS[r.category]||'—')+'</td><td>'+esc(r.location||'—')+'</td><td>'+chip(r.status)+'</td><td>'+esc(CC.TIER_LABEL[r.tier]||r.tier)+'</td><td>'+esc(CC.fdate(r.created_at))+'</td><td>'+r.products+'</td><td>'+r.orders+'</td><td>'+money(r.revenue_xcd)+'</td><td><button class="btn ghost sm" data-open="'+r.id+'">View</button></td></tr>').join('')+'</tbody></table></div>':'<p class="muted">No businesses match.</p>')+
   '<div class="cu-pager"><span class="muted">'+(d.rows.length?'Showing '+(d.offset+1)+'–'+(d.offset+d.rows.length)+' of '+d.total:'0 businesses')+'</span><span><button class="btn ghost sm" id="vd-prev"'+(S.page<=0?' disabled':'')+'>Previous</button> Page '+(S.page+1)+' of '+pages+' <button class="btn ghost sm" id="vd-next"'+(S.page+1>=pages?' disabled':'')+'>Next</button></span></div>';
  box.querySelectorAll('[data-open]').forEach(b=>b.onclick=()=>{S.open=b.dataset.open;detail()});
  g('#vd-prev').onclick=()=>{S.page=Math.max(0,S.page-1);list()};g('#vd-next').onclick=()=>{S.page++;list()};
 }
 function shell(){
  el.innerHTML='<h2>Vendors</h2><p class="muted">Every business on the platform. Search, open a business to see its owner, team, products, orders and settings, edit its profile, change its plan, or suspend it. Every change needs a reason and is written to the audit log.</p>'+
  '<div class="ap-samples" id="vd-samples"></div><div class="ap-counts" id="vd-counts" role="group" aria-label="Filter by status"></div>'+
  '<form class="cu-filters" id="vd-f" role="search"><label class="cu-q">Search<input id="vd-q" type="search" maxlength="100" placeholder="Business, owner name or email, area or category" value="'+esc(S.q)+'" autocomplete="off"></label>'+
  '<label>Status<select id="vd-st"><option value="all">All</option><option value="pending">Waiting</option><option value="changes_requested">Changes requested</option><option value="approved">Approved</option><option value="suspended">Suspended</option><option value="rejected">Rejected</option><option value="sample">Sample vendors</option></select></label>'+
  '<label>Plan<select id="vd-tier"><option value="all">All plans</option>'+CC.TIERS.map(t=>'<option value="'+t.k+'">'+esc(t.name)+'</option>').join('')+'</select></label></form><div id="vd-res" aria-live="polite"><p class="muted">Loading…</p></div>';
  g('#vd-st').value=S.status;g('#vd-tier').value=S.tier;let t=null;const q=g('#vd-q');const go=()=>{S.q=q.value.trim();S.page=0;list()};
  q.oninput=()=>{clearTimeout(t);t=setTimeout(go,300)};g('#vd-f').onsubmit=e=>{e.preventDefault();clearTimeout(t);go()};
  g('#vd-st').onchange=e=>{S.status=e.target.value;S.page=0;list()};g('#vd-tier').onchange=e=>{S.tier=e.target.value;S.page=0;list()};
  list();
 }
 async function detail(flash){
  const id=S.open;el.innerHTML='<p class="muted">Loading…</p>';let d;
  try{d=await rpc('admin_vend_get',{p_vendor:id})}catch(e){if(my!==seq)return;if(missing(e.message)){el.innerHTML=offBox;return}S.open=null;shell();el.insertAdjacentHTML('afterbegin','<div class="notice err" role="alert">'+esc(e.message)+'</div>');return}
  if(my!==seq)return;
  const a=d.application,st=d.status,ck=d.checkout,os=d.order_summary,ps=d.product_summary;
  const kv=(k,v)=>'<tr><th scope="row">'+esc(k)+'</th><td>'+(v==null||v===''?'<span class="muted">—</span>':esc(v))+'</td></tr>';
  const hist=h=>{const x=h.details||{};const ch=x.after&&typeof x.after==='object'?'<small>Changed: '+Object.keys(x.after).map(k=>esc(k)+' ('+esc(String(x.before&&x.before[k]!=null?x.before[k]:'—'))+' → '+esc(String(x.after[k]!=null?x.after[k]:'—'))+')').join(', ')+'</small>':(x.after!=null&&typeof x.after!=='object'?'<small>'+esc(String(x.before))+' → '+esc(String(x.after))+'</small>':'');
   return '<li><b>'+esc(ACT[h.action]||h.action)+'</b> by '+esc(h.by||'the applicant')+' · '+esc(CC.fdate(h.at))+(x.reason?'<small>Reason: '+esc(x.reason)+'</small>':'')+ch+'</li>'};
  const vat=ck?(ck.vat_registered?'Yes, '+(ck.vat_number||''):'No'):(a?(a.vat_registered?'Yes, '+(a.vat_number||''):'No'):null);
  const loc=a?{isl:a.island,ar:a.area}:{isl:'Carriacou',ar:d.location||''};
  el.innerHTML='<p><button class="btn ghost sm" id="vd-back">← All vendors</button></p><div id="vd-msg" role="alert">'+(flash?'<div class="notice ok">'+esc(flash)+'</div>':'')+'</div>'+
  '<div class="cu-head"><h2>'+esc(d.name)+' '+chip(st)+(d.is_sample?' <span class="pp pp-unpaid">SAMPLE</span>':'')+'</h2><p class="muted">Joined '+esc(CC.fdate(d.created_at))+' · plan '+esc(CC.TIER_LABEL[d.tier]||d.tier)+' · '+(ps.active)+' active of '+ps.total+' products · '+os.count+' orders · '+money(os.revenue_xcd)+' revenue</p></div>'+
  (d.status_reason?'<div class="notice '+(st==='suspended'||st==='rejected'?'err':'')+'">Last message: <b>'+esc(d.status_reason)+'</b></div>':'')+
  '<div class="cu-grid"><section class="cu-card"><h3>Profile</h3><table class="kvtab"><tbody>'+kv('Description',d.description)+kv('Category',CATS[d.category]||d.category)+kv('Area',d.location)+kv('Business phone',d.admin_phone)+kv('WhatsApp',d.admin_whatsapp)+kv('VAT registered',vat)+
   (a?kv('Business type',a.business_type)+kv('Registration / ID',a.registration_number)+kv('Applied',CC.fdate(a.submitted_at))+kv('Terms',a.terms_version):'')+kv('Admin notes (private)',d.admin_notes)+'</tbody></table>'+
   '<details id="vd-editbox"><summary><b>Edit profile</b></summary><form id="vd-edit" novalidate><label>Business name<input id="e-name" maxlength="80" value="'+esc(d.name)+'"></label>'+
   '<label>Description<textarea id="e-desc" maxlength="500" rows="3">'+esc(d.description)+'</textarea></label>'+
   '<label>Category<select id="e-cat">'+Object.keys(CATS).map(k=>'<option value="'+k+'"'+(d.category===k?' selected':'')+'>'+esc(CATS[k])+'</option>').join('')+'</select></label>'+
   '<label>Island<select id="e-isl">'+ISL.map(i=>'<option'+(loc.isl===i?' selected':'')+'>'+i+'</option>').join('')+'</select></label><label>Parish / area<input id="e-area" maxlength="60" value="'+esc(loc.ar)+'"></label>'+
   '<label>Business phone<input id="e-phone" maxlength="30" value="'+esc(d.admin_phone||'')+'"></label><label>WhatsApp<input id="e-wa" maxlength="30" value="'+esc(d.admin_whatsapp||'')+'"></label>'+
   '<label class="ckbox"><input type="checkbox" id="e-vr"'+(ck?ck.vat_registered:(a&&a.vat_registered)?' checked':'')+'> VAT registered</label><label>VAT number<input id="e-vn" maxlength="40" value="'+esc((ck&&ck.vat_number)||(a&&a.vat_number)||'')+'"></label>'+
   '<label>Admin notes (private, max 1000)<textarea id="e-notes" maxlength="1000" rows="2">'+esc(d.admin_notes||'')+'</textarea></label>'+
   '<label>Reason for this change (required)<input id="e-reason" maxlength="300" placeholder="e.g. Corrected after phone call"></label><button class="btn" type="submit">Save changes</button></form></details>'+
   '<h3>Owner and team</h3><table class="kvtab"><tbody>'+kv('Owner',d.owner_name)+kv('Owner email',d.owner_email)+kv('Owner phone',d.owner_phone)+'</tbody></table>'+
   (d.staff.length?'<ul class="auditlist">'+d.staff.map(s=>'<li><b>'+esc(s.name||s.email||'Member')+'</b> · '+esc(s.role==='admin'?'owner':s.role)+(s.status==='suspended'?' (suspended)':'')+'<small>'+esc(s.email||'')+'</small></li>').join('')+'</ul>':'<p class="muted">No team members.</p>')+'</section>'+
  '<section class="cu-card"><h3>Actions</h3><p class="muted">Each action needs a reason (3-300 characters).</p><label>Reason<input id="a-reason" maxlength="300" placeholder="Reason for the action below"></label>'+
  '<div class="vd-btns">'+(['pending','changes_requested','rejected'].includes(st)?'<button class="btn" type="button" data-dec="approve">Approve</button> ':'')+(['pending','changes_requested'].includes(st)?'<button class="btn danger" type="button" data-dec="reject">Reject</button> ':'')+(st==='pending'?'<button class="btn ghost" type="button" data-dec="request_changes">Request changes</button> ':'')+(st==='approved'?'<button class="btn danger" type="button" data-dec="suspend">Suspend</button>':'')+(st==='suspended'?'<button class="btn" type="button" data-dec="reinstate">Reinstate</button>':'')+'</div>'+
  '<h3>Plan</h3><form id="vd-tierf" novalidate><label>Plan<select id="t-tier">'+CC.TIERS.map(t=>'<option value="'+t.k+'"'+(d.tier===t.k?' selected':'')+'>'+esc(t.name)+'</option>').join('')+'</select></label><button class="btn ghost" type="submit">Change plan</button></form><p class="muted">Test mode: no billing.</p>'+
  '<h3>Owner</h3><form id="vd-own" novalidate><label>'+(d.owner_id?'Reassign to (customer email)':'Give to (customer email)')+'<input id="o-email" type="email" maxlength="254" placeholder="person@example.com"></label>'+(d.is_sample?'<label>New business name (optional)<input id="o-name" maxlength="80" value="'+esc(d.name.replace(/^SAMPLE\s+/i,''))+'"></label>':'')+'<button class="btn ghost" type="submit">'+(d.owner_id?'Reassign owner':'Assign owner')+'</button></form></section></div>'+
  '<section class="cu-card vd-layout" id="vd-layout"></section>'+
  '<section class="cu-card vd-sgc" id="vd-sgc"></section>'+
  '<div class="cu-grid"><section class="cu-card"><h3>Products</h3><p>'+ps.total+' total, '+ps.active+' active.</p>'+(ps.recent.length?'<ul class="auditlist">'+ps.recent.map(p=>'<li>'+esc(p.name)+' · '+money(p.price_xcd)+(p.active?'':' (hidden)')+'</li>').join('')+'</ul>':'')+
   '<h3>Orders</h3><p>'+os.count+' orders, '+money(os.revenue_xcd)+' revenue (cancelled excluded).'+(os.last_order_at?' Last order '+esc(CC.fdate(os.last_order_at))+'.':'')+'</p>'+
   (Object.keys(os.by_status||{}).length?'<p class="muted">'+Object.keys(os.by_status).map(k=>esc(k.replace(/_/g,' '))+': '+os.by_status[k]).join(' · ')+'</p>':'')+'</section>'+
  '<section class="cu-card"><h3>Delivery and tax settings (read-only)</h3>'+(ck?'<table class="kvtab"><tbody>'+kv('Pickup',ck.pickup_enabled?'Yes':'No')+kv('Delivery',ck.delivery_enabled?(ck.delivery_model==='zones'?'By area ('+(ck.delivery_zones||[]).length+' areas)':'Flat EC$'+(+ck.delivery_flat_fee).toFixed(2)):'No')+kv('Free delivery over',ck.free_over_xcd!=null?money(ck.free_over_xcd):null)+kv('VAT registered',ck.vat_registered?'Yes':'No')+kv('VAT number',ck.vat_number)+kv('VAT rate',ck.vat_rate_pct!=null?ck.vat_rate_pct+'%':'platform default')+kv('Prices include tax',ck.prices_include_tax?'Yes':'No')+'</tbody></table>':'<p class="muted">The business has not saved delivery and tax settings yet.</p>')+'</section></div>'+
  '<section class="cu-card"><h3>Admin history</h3>'+(d.history.length?'<ul class="auditlist">'+d.history.map(hist).join('')+'</ul>':'<p class="muted">No admin actions yet.</p>')+'</section>';
  const msg=(t,ok)=>{const m=g('#vd-msg');m.innerHTML=t?'<div class="notice '+(ok?'ok':'err')+'">'+esc(t)+'</div>':'';if(t)m.scrollIntoView({block:'nearest'})};
  const act=async(fn,args,okMsg)=>{el.querySelectorAll('button').forEach(b=>b.disabled=true);try{await rpc(fn,args);await detail(okMsg)}catch(e){el.querySelectorAll('button').forEach(b=>b.disabled=false);msg(e.message||'Could not save.',false)}};
  const reason=sel=>{const r=g(sel).value.trim();if(r.length<3){msg('Please give a reason (at least 3 characters).',false);return null}if(r.length>300){msg('The reason is too long (max 300 characters).',false);return null}return r};
  g('#vd-back').onclick=()=>{S.open=null;shell()};
  if(CC.shopGiftCards&&g('#vd-sgc'))CC.shopGiftCards.adminMount(g('#vd-sgc'),sb,{id,name:d.name});
  if(CC.shopLayout&&g('#vd-layout'))CC.shopLayout.adminMount(g('#vd-layout'),sb,{id,name:d.name});
  el.querySelectorAll('[data-dec]').forEach(b=>b.onclick=()=>{const dec=b.dataset.dec,r=reason('#a-reason');if(!r)return;if(!confirm(b.textContent+' '+d.name+'?'))return;
   act('admin_vend_decide',{p_vendor:id,p_decision:dec,p_reason:r,p_tier:dec==='approve'?(a&&a.requested_tier)||d.tier:null},({approve:'Approved.',reject:'Rejected.',request_changes:'Changes requested.',suspend:'Business suspended.',reinstate:'Business reinstated.'})[dec])});
  g('#vd-tierf').onsubmit=e=>{e.preventDefault();const r=reason('#a-reason');if(!r)return;const t=g('#t-tier').value;if(t===d.tier){msg('That is already the current plan.',false);return}if(!confirm('Change '+d.name+' to the '+CC.TIER_LABEL[t]+' plan?'))return;act('admin_vend_set_tier',{p_vendor:id,p_tier:t,p_reason:r},'Plan changed.')};
  g('#vd-own').onsubmit=e=>{e.preventDefault();const r=reason('#a-reason');if(!r)return;const em=g('#o-email').value.trim();if(!em){msg('Enter the customer\'s email address.',false);return}if(!confirm((d.owner_id?'Reassign ':'Assign ')+d.name+' to '+em+'?'))return;
   act('admin_vend_assign_owner',{p_vendor:id,p_email:em,p_reason:r,p_new_name:g('#o-name')?g('#o-name').value.trim()||null:null},d.owner_id?'Owner reassigned.':'Owner assigned.')};
  g('#vd-edit').onsubmit=e=>{e.preventDefault();const r=reason('#e-reason');if(!r)return;const p={},v=s=>g(s).value.trim();
   if(v('#e-name')!==d.name)p.name=v('#e-name');if(v('#e-desc')!==d.description)p.description=v('#e-desc');if(v('#e-cat')!==(d.category||''))p.category=v('#e-cat');
   if(v('#e-isl')!==loc.isl||v('#e-area')!==loc.ar){p.island=v('#e-isl');p.area=v('#e-area')}
   if(v('#e-phone')!==(d.admin_phone||''))p.phone=v('#e-phone');if(v('#e-wa')!==(d.admin_whatsapp||''))p.whatsapp=v('#e-wa');
   const ovr=ck?ck.vat_registered:!!(a&&a.vat_registered),ovn=(ck&&ck.vat_number)||(a&&a.vat_number)||'';
   if(g('#e-vr').checked!==ovr||v('#e-vn')!==ovn){p.vat_registered=g('#e-vr').checked;p.vat_number=v('#e-vn')}
   if(v('#e-notes')!==(d.admin_notes||''))p.admin_notes=v('#e-notes');
   if(!Object.keys(p).length){msg('Nothing was changed.',false);return}
   act('admin_vend_update',{p_vendor:id,p:p,p_reason:r},'Profile saved and logged.')};
 }
 if(S.open)detail();else shell();
}
CC.vendors={mount};
})();
