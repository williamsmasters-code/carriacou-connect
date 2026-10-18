// Team & plan tab (v0.9, owner only). Needs supabase/staff.sql. Plans are TEST MODE: nothing is billed.
// Every change goes through a database function that re-checks who you are; hiding a button here is only for friendliness.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,fdate=CC.fdate;
const ACTION={invite_created:'Invite created',invite_revoked:'Invite revoked',member_joined:'Joined the team',role_changed:'Role changed',member_suspended:'Access paused',member_reactivated:'Access restored',member_removed:'Removed from the team',member_left:'Left the team',tier_changed:'Plan changed',upgrade_requested:'Upgrade requested',upgrade_request_cancelled:'Upgrade request cancelled',upgrade_approved:'Upgrade approved',upgrade_declined:'Upgrade declined',plan_override_set:'Custom seat limits set',tier_change_reason:'Plan change note'};
const nice=m=>{m=(m&&m.message)||String(m||'');return /Could not find the function|schema cache|does not exist/i.test(m)?'Teams and plans are not switched on yet (staff.sql has not been run in Supabase).':m};
const left=(limit,used)=>limit==null?Infinity:Math.max(0,limit-used);
const lbl=n=>n==null?'unlimited':String(n);
function meter(used,limit){return limit==null||limit===0?'':'<span class="meter"><span style="width:'+Math.min(100,Math.round(used/limit*100))+'%"></span></span>'}
function mount(box,o){
 const {sb,vendor}=o;let data=null,P=o.plan,newInvite=null,busy=false;
 const T=CC.TIERS.find(t=>t.k===(P&&P.tier||vendor.tier))||CC.TIERS[0];
 const say=(m,ok)=>{const e=box.querySelector('#tmsg');if(!e)return;e.className='notice '+(ok?'ok':'err');e.textContent=m||'';e.hidden=!m;if(m)e.scrollIntoView({block:'nearest'})};
 async function load(){
  box.innerHTML='<p class="muted">Loading team…</p>';
  const [pl,tl]=await Promise.all([sb.rpc('vendor_plan',{p_vendor:vendor.id}),sb.rpc('team_list',{p_vendor:vendor.id})]);
  if(pl.error||tl.error){box.innerHTML='<div class="notice err">'+esc(nice(pl.error||tl.error))+'</div>';return}
  P=pl.data;data=tl.data;draw();
 }
 function draw(){
  const L=P.limits,U=P.usage,tk=P.tier,next=CC.TIERS.find(t=>t.k===P.next_tier);
  const staffLeft=left(L.max_staff,U.staff+U.pending_staff),subLeft=left(L.max_subadmins,U.subadmins+U.pending_subadmins);
  const noTeam=L.max_staff===0&&L.max_subadmins===0;
  const pend=P.pending_request;
  box.innerHTML=`<div id="tmsg" class="notice" hidden role="alert"></div>
  <section class="plancard"><div class="ph"><div><span class="kicker">Your plan</span><h3><span class="badge t-${esc(CC.TIER_LABEL[tk].replace('+',''))}">${esc(CC.TIER_LABEL[tk])}</span></h3></div><span class="testtag">TEST MODE: billing is not live</span></div>
   <div class="usegrid"><div><b>Staff</b><span>${U.staff} of ${lbl(L.max_staff)}</span>${meter(U.staff,L.max_staff)}</div>
   ${L.max_subadmins===0?'':`<div><b>Sub-admins</b><span>${U.subadmins} of ${lbl(L.max_subadmins)}</span>${meter(U.subadmins,L.max_subadmins)}</div>`}
   <div><b>Products</b><span>${U.products} of ${lbl(L.max_products)}</span>${meter(U.products,L.max_products)}</div></div>
   ${U.pending_staff+U.pending_subadmins?`<p class="muted">${U.pending_staff+U.pending_subadmins} open invite${U.pending_staff+U.pending_subadmins===1?'':'s'} already reserve${U.pending_staff+U.pending_subadmins===1?'s':''} a seat.</p>`:''}
   ${P.overridden?'<p class="muted">Custom seat limits were set for your business.</p>':''}
   <div class="planact">${pend?`<p class="notice ok">Upgrade to <b>${esc(CC.TIER_LABEL[pend.to_tier])}</b> requested ${esc(fdate(pend.created_at))}. Waiting for approval. <button class="btn ghost sm" id="rqcancel" type="button">Cancel request</button></p>`
     :next?`<form id="rqf" class="rqform"><label>Request an upgrade <select id="rqt">${CC.TIERS.filter(t=>t.k!==tk&&CC.TIERS.findIndex(x=>x.k===t.k)>CC.TIERS.findIndex(x=>x.k===tk)).map(t=>`<option value="${t.k}">${esc(t.name)}</option>`).join('')}</select></label><label>Note (optional)<input id="rqn" maxlength="300" placeholder="Why you need it"></label><button class="btn" type="submit">Request upgrade</button> <a class="btn ghost" href="tiers.html">Compare plans</a><p class="muted">Test mode: the request goes to the Carriacou Connect team to approve. You are not charged.</p></form>`
     :'<p class="muted">You are on the top plan. <a href="tiers.html">See all plans</a></p>'}</div></section>
  <section><h3>Team members</h3><div class="members">${data.members.map(m=>memberRow(m)).join('')}</div></section>
  <section><h3>Invite someone</h3>${noTeam?upsell():inviteForm(staffLeft,subLeft)}${newInvite?inviteBox(newInvite):''}</section>
  <section><h3>Open invites</h3>${data.invites.length?'<div class="invites">'+data.invites.map(i=>`<div class="irow${i.expired?' exp':''}"><div><b>${esc(i.email)}</b> <span class="rolebadge r-${esc(i.role)}">${esc(CC.ROLE_LABEL[i.role])}</span><small>${i.expired?'Expired':'Expires'} ${esc(fdate(i.expires_at))}</small></div><button class="btn ghost sm" data-rev="${esc(i.id)}" type="button">Revoke</button></div>`).join('')+'</div>':'<p class="muted">No open invites.</p>'}</section>
  <details class="permtable"><summary>What can each role do?</summary>${perms()}</details>
  <details class="auditbox" id="aud"><summary>Activity log</summary><div id="audbody"><p class="muted">Loading…</p></div></details>`;
  wire();
 }
 const upsell=()=>`<div class="upsell"><b>Your ${esc(T.name)} plan has no team accounts.</b><p>Staff accounts start on the <b>Standard</b> plan (1 owner + 2 staff). <b>Plus+</b> allows 5 staff, and <b>Pro</b> adds 2 sub-admins who can manage products and see analytics.</p><a class="btn" href="tiers.html">See plans</a></div>`;
 function inviteForm(staffLeft,subLeft){
  const full=staffLeft===0&&subLeft===0;
  return `<form id="invf" class="invform" autocomplete="off"><label>Email of the person<input id="ie" type="email" required maxlength="254" placeholder="name@example.com" ${full?'disabled':''}></label>
   <label>Role <select id="ir" ${full?'disabled':''}><option value="staff"${staffLeft===0?' disabled':''}>Staff${staffLeft===0?' (no seats left)':''}</option><option value="subadmin"${subLeft===0?' disabled':''}>Sub-admin${subLeft===0?(P.limits.max_subadmins===0?' (needs Pro)':' (no seats left)'):''}</option></select></label>
   <button class="btn" ${full?'disabled':''}>Create invite link</button>${full?`<p class="err-text">All seats on your ${esc(T.name)} plan are used. Remove someone or <a href="tiers.html">upgrade</a>.</p>`:''}
   <p class="muted">No email is sent. You get a link and a code to share yourself. It only works for that email address, once, for 7 days. The person signs up or logs in with that email first.</p></form>`;
 }
 function inviteBox(i){
  const link=location.origin+location.pathname.replace(/[^/]*$/,'')+'accept-invite.html#code='+encodeURIComponent(i.code);
  return `<div class="invbox" role="status"><b>Invite ready for ${esc(i.email)}</b> as ${esc(CC.ROLE_LABEL[i.role])}
   <p class="muted">Copy it now. For safety the code is shown only once. It expires ${esc(fdate(i.expires_at))}.</p>
   <div class="wcode"><span class="muted">Link</span><code id="ilink">${esc(link)}</code><button class="btn ghost sm" data-copy="${esc(link)}" type="button">Copy link</button></div>
   <div class="wcode"><span class="muted">Code</span><code>${esc(i.code)}</code><button class="btn ghost sm" data-copy="${esc(i.code)}" type="button">Copy code</button></div></div>`;
 }
 function memberRow(m){
  const pill=m.status==='suspended'?'<span class="pp pp-ref">Paused</span>':'<span class="pp pp-paid">Active</span>';
  const canEditRole=!m.is_owner;
  return `<div class="mrow${m.status==='suspended'?' paused':''}"><div class="mwho"><b>${esc(m.name)}</b>${m.is_owner?' <span class="rolebadge r-admin">Owner</span>':''}<small>${esc(m.email||'')}</small><small>Joined ${esc(fdate(m.joined_at))}</small></div>
   <div class="mrole">${canEditRole?`<select data-role="${esc(m.id)}" aria-label="Role for ${esc(m.name)}"><option value="staff"${m.role==='staff'?' selected':''}>Staff</option><option value="subadmin"${m.role==='subadmin'?' selected':''}>Sub-admin</option></select>`:'<span class="muted">Full access</span>'}</div>
   <div class="mstat">${pill}</div>
   <div class="mact">${canEditRole?`<button class="btn ghost sm" data-susp="${esc(m.id)}" data-to="${m.status==='suspended'?'active':'suspended'}" type="button">${m.status==='suspended'?'Restore access':'Pause access'}</button> <button class="btn ghost sm danger" data-rm="${esc(m.id)}" data-name="${esc(m.name)}" type="button">Remove</button>`:''}</div></div>`;
 }
 function perms(){
  const rows=[['Orders: see and update','orders_view',1,1,1],['Order notes to customers','notes',1,1,1],['POS charges','pos',1,1,1],['See all products','products_view',1,1,1],['Add, edit, delete products','products_edit',0,1,1],['Refund wallet-paid orders','refunds',0,1,1],['Analytics','analytics',0,1,1],['Team, invites and activity log','team',0,0,1],['Request plan upgrades','plan',0,0,1],['Business wallet (send, top up) and business profile',null,0,0,1]];
  const y='<span class="yes" aria-label="Yes">✓</span>',n='<span class="no" aria-label="No">–</span>';
  return '<div class="tblwrap"><table class="ptab"><tr><th>Action</th><th>Staff</th><th>Sub-admin</th><th>Owner</th></tr>'+rows.map(r=>`<tr><td>${esc(r[0])}</td><td>${r[2]?y:n}</td><td>${r[3]?y:n}</td><td>${r[4]?y:n}</td></tr>`).join('')+'</table></div><p class="muted">Sub-admin seats exist on Pro and Enterprise only.</p>';
 }
 async function act(fn,args,okMsg){
  if(busy)return;busy=true;box.querySelectorAll('button').forEach(b=>b.disabled=true);
  const r=await sb.rpc(fn,args);busy=false;
  if(r.error){await load();say(nice(r.error));return null}
  await load();if(okMsg)say(okMsg,true);return r.data;
 }
 function wire(){
  box.querySelectorAll('[data-copy]').forEach(b=>b.onclick=async()=>{try{await navigator.clipboard.writeText(b.dataset.copy);b.textContent='Copied ✓'}catch(e){const r=document.createRange();const c=b.previousElementSibling;r.selectNodeContents(c);const s=getSelection();s.removeAllRanges();s.addRange(r);b.textContent='Selected: press copy'}});
  const f=box.querySelector('#invf');
  if(f)f.onsubmit=async e=>{e.preventDefault();if(busy)return;busy=true;const bt=f.querySelector('button');bt.disabled=true;
   const r=await sb.rpc('create_invite',{p_vendor:vendor.id,p_email:f.querySelector('#ie').value.trim(),p_role:f.querySelector('#ir').value});busy=false;
   if(r.error){await load();say(nice(r.error));return}
   newInvite=r.data;await load();const bx=box.querySelector('.invbox');if(bx)bx.scrollIntoView({block:'nearest'})};
  box.querySelectorAll('[data-rev]').forEach(b=>b.onclick=()=>{if(confirm('Revoke this invite? The link and code will stop working.')){newInvite=null;act('revoke_invite',{p_invite:b.dataset.rev},'Invite revoked.')}});
  box.querySelectorAll('[data-role]').forEach(s=>s.onchange=()=>act('change_member_role',{p_member:s.dataset.role,p_role:s.value},'Role updated. It takes effect immediately.'));
  box.querySelectorAll('[data-susp]').forEach(b=>b.onclick=()=>act('set_member_status',{p_member:b.dataset.susp,p_status:b.dataset.to},b.dataset.to==='suspended'?'Access paused. They keep their seat.':'Access restored.'));
  box.querySelectorAll('[data-rm]').forEach(b=>b.onclick=()=>{if(confirm('Remove '+b.dataset.name+' from your team? They lose access straight away.'))act('remove_member',{p_member:b.dataset.rm},'Removed. The seat is free again.')});
  const rf=box.querySelector('#rqf');
  if(rf)rf.onsubmit=async e=>{e.preventDefault();const to=rf.querySelector('#rqt').value;
   if(!confirm('Request the '+CC.TIER_LABEL[to]+' plan? TEST MODE: no billing exists yet, the Carriacou Connect team approves test upgrades.'))return;
   const r=await act('request_upgrade',{p_vendor:vendor.id,p_tier:to,p_note:rf.querySelector('#rqn').value.trim()||null},'Upgrade requested. You will see the new plan here once it is approved.')};
  const rc=box.querySelector('#rqcancel');if(rc)rc.onclick=()=>act('cancel_upgrade_request',{p_request:P.pending_request.id},'Request cancelled.');
  const ad=box.querySelector('#aud');
  if(ad)ad.addEventListener('toggle',async()=>{if(!ad.open||ad.dataset.done)return;ad.dataset.done=1;const b=box.querySelector('#audbody');
   const r=await sb.rpc('team_audit',{p_vendor:vendor.id,p_limit:50});if(r.error){b.innerHTML='<div class="notice err">'+esc(nice(r.error))+'</div>';return}
   b.innerHTML=(r.data||[]).length?'<ul class="auditlist">'+r.data.map(a=>`<li><b>${esc(ACTION[a.action]||a.action)}</b>${a.target?' · '+esc(a.target):''}${a.details&&a.details.email?' · '+esc(a.details.email):''}${a.details&&a.details.from?' · '+esc(a.details.from)+' → '+esc(a.details.to):a.details&&a.details.to?' · '+esc(a.details.to):''}${a.details&&a.details.role&&!a.details.from?' ('+esc(a.details.role)+')':''}<small>${esc(a.actor)} · ${esc(fdate(a.at))}</small></li>`).join('')+'</ul>':'<p class="muted">Nothing yet.</p>'});
 }
 return load();
}
CC.team={mount};
})();
