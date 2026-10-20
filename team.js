// Team & plan tab (v0.9, owner only). Needs supabase/staff.sql. Plans are TEST MODE: nothing is billed.
// Every change goes through a database function that re-checks who you are; hiding a button here is only for friendliness.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,fdate=CC.fdate;
const ACTION={checkout_settings_changed:'Delivery and tax settings changed',products_bulk:'Bulk product import',invite_created:'Invite created',invite_revoked:'Invite revoked',member_joined:'Joined the team',role_changed:'Role changed',member_suspended:'Access paused',member_reactivated:'Access restored',member_removed:'Removed from the team',member_left:'Left the team',tier_changed:'Plan changed',upgrade_requested:'Upgrade requested',upgrade_request_cancelled:'Upgrade request cancelled',upgrade_approved:'Upgrade approved',upgrade_declined:'Upgrade declined',plan_override_set:'Custom seat limits set',onb_applied:'Application sent',onb_updated:'Application edited',onb_approved:'Application approved',onb_rejected:'Application rejected',onb_changes_requested:'Changes requested on the application',onb_suspended:'Business suspended',onb_reinstated:'Business reinstated',onb_owner_assigned:'Owner assigned',onb_owner_reassigned:'Owner reassigned by Carriacou Connect',onb_owner_transferred:'Ownership transferred',onb_payment_info:'Payment information saved',tier_change_reason:'Plan change note'};
const nice=m=>{m=(m&&m.message)||String(m||'');return /Could not find the function|schema cache|does not exist/i.test(m)?'Teams and plans are not switched on yet (staff.sql has not been run in Supabase).':m};
const left=(limit,used)=>limit==null?Infinity:Math.max(0,limit-used);
const lbl=n=>n==null?'unlimited':String(n);
const inDays=d=>{const ms=new Date(d)-Date.now();if(ms<=0)return 'expired';const h=Math.floor(ms/36e5);return h<48?'in '+Math.max(1,h)+' hour'+(h===1?'':'s'):'in '+Math.floor(h/24)+' days'};
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
  <section><h3>Open invites</h3><p class="muted">The invite code is shown only once, when you create it, so a lost invite cannot be shown again: revoke it and create a new one.</p>${data.invites.length?'<div class="invites">'+data.invites.map(i=>`<div class="irow${i.expired?' exp':''}"><div><b>${esc(i.email)}</b> <span class="rolebadge r-${esc(i.role)}">${esc(CC.ROLE_LABEL[i.role])}</span><small>${i.expired?'Expired':'Expires'} ${esc(fdate(i.expires_at))} (${esc(inDays(i.expires_at))})</small></div><button class="btn ghost sm" data-rev="${esc(i.id)}" type="button">Revoke</button></div>`).join('')+'</div>':'<p class="muted">No open invites.</p>'}</section>
  ${transferSection()}
  <details class="permtable"><summary><span class="sumt">What can each role do?</span><span class="sumh">Staff · Sub-admin · Owner</span><span class="chev" aria-hidden="true"></span></summary>${perms()}</details>
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
 const mailto=(i,link)=>'mailto:'+encodeURIComponent(i.email).replace(/%40/g,'@')+'?subject='+encodeURIComponent('Join '+vendor.name+' on Carriacou Connect')+'&body='+encodeURIComponent('Hello,\n\nYou are invited to join '+vendor.name+' on Carriacou Connect as '+(CC.ROLE_LABEL[i.role]||i.role)+'.\n\n1. Log in or sign up with THIS email address: '+i.email+'\n2. Open this link: '+link+'\n   (or enter the code '+i.code+' on the Accept invite page)\n\nThe invite works once and expires '+fdate(i.expires_at)+'.\n');
 function inviteBox(i){
  const link=location.origin+location.pathname.replace(/[^/]*$/,'')+'accept-invite.html#code='+encodeURIComponent(i.code);
  return `<div class="invbox" role="status"><b>Invite ready for ${esc(i.email)}</b> as ${esc(CC.ROLE_LABEL[i.role])}
   <p class="muted">Copy it now. For safety the code is shown only once. It expires ${esc(fdate(i.expires_at))}.</p>
   <div class="wcode"><span class="muted">Link</span><code id="ilink">${esc(link)}</code><button class="btn ghost sm" data-copy="${esc(link)}" type="button">Copy link</button></div>
   <div class="wcode"><span class="muted">Code</span><code>${esc(i.code)}</code><button class="btn ghost sm" data-copy="${esc(i.code)}" type="button">Copy code</button></div>
   <p><a class="btn ghost sm" id="imail" href="${esc(mailto(i,link))}">Email draft (opens your mail app)</a> <small class="muted">Carriacou Connect does not send email. This only opens a draft in your own email app, which you send yourself.</small></p></div>`;
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
  // v1.7.1: display only. The real permission checks live in the database (role_perms() in staff.sql).
  const rows=[['Orders: see and update','orders_view',1,1,1],['Order notes to customers','notes',1,1,1],['POS charges','pos',1,1,1],['See all products','products_view',1,1,1],['Add, edit, delete products','products_edit',0,1,1],['Refund wallet-paid orders','refunds',0,1,1],['Analytics','analytics',0,1,1],['Team, invites and activity log','team',0,0,1],['Request plan upgrades','plan',0,0,1],['Business wallet (send, top up) and business profile',null,0,0,1]];
  const sv=(d)=>`<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
  const IC={staff:'<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 4-6 8-6s8 2 8 6"/>',subadmin:'<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M9 12l2 2 4-4"/>',admin:'<path d="M3 8l4 4 5-7 5 7 4-4-2 11H5z"/>',
   orders:'<path d="M6 2h12l2 5H4z"/><path d="M4 7v13h16V7"/><path d="M9 11h6"/>',products:'<path d="M12 2l9 5-9 5-9-5z"/><path d="M3 12l9 5 9-5"/><path d="M3 17l9 5 9-5"/>',money:'<rect x="2" y="6" width="20" height="13" rx="2"/><circle cx="12" cy="12.5" r="3"/><path d="M6 10v5M18 10v5"/>',team:'<circle cx="9" cy="8" r="3"/><circle cx="17" cy="9" r="2.5"/><path d="M3 20c0-3 3-5 6-5s6 2 6 5M15 15c3 0 6 1.5 6 4.5"/>'};
  const CHK='<path d="M5 12l5 5L20 7"/>';
  const ROLES=[{k:'staff',i:2,n:'Staff',tag:'Front counter & orders'},{k:'subadmin',i:3,n:'Sub-admin',tag:'Runs the shop day to day'},{k:'admin',i:4,n:'Owner',tag:'Full control of the business'}];
  const GROUPS=[['orders','Orders & sales',[0,1,2]],['products','Products',[3,4]],['money','Money & insights',[5,6]],['team','Team & business',[7,8,9]]];
  const tot=rows.length,cnt=r=>rows.filter(x=>x[r.i]).length;
  const yes=r=>`<span class="pp yes r-${r.k}">${sv(CHK)}<span>Allowed</span></span>`,no='<span class="pp no"><span aria-hidden="true">–</span><span class="sr">Not allowed</span></span>';
  const head=ROLES.map(r=>{const c=cnt(r),pc=Math.round(c/tot*100);return `<th scope="col" class="rh rh-${r.k}"><span class="rhc"><span class="rhi">${sv(IC[r.k])}</span><b>${esc(r.n)}</b><small>${esc(r.tag)}</small><span class="cap" role="img" aria-label="${c} of ${tot} permissions"><span class="capbar"><span style="width:${pc}%"></span></span><span class="capn">${c}/${tot}</span></span></span></th>`}).join('');
  const body=GROUPS.map(([g,label,ix])=>`<tbody class="pg pg-${g}"><tr class="pgh"><th scope="rowgroup" colspan="4"><span class="pgi">${sv(IC[g])}</span>${esc(label)}</th></tr>${ix.map(i=>{const r=rows[i];return `<tr class="pr" tabindex="0"><th scope="row">${esc(r[0])}</th>${ROLES.map(R=>`<td data-role="${esc(R.n)}">${r[R.i]?yes(R):no}</td>`).join('')}</tr>`}).join('')}</tbody>`).join('');
  const cards=ROLES.map(r=>{const c=cnt(r);return `<section class="rcard rh-${r.k}"><header class="rhc"><span class="rhi">${sv(IC[r.k])}</span><b>${esc(r.n)}</b><small>${esc(r.tag)}</small><span class="cap" role="img" aria-label="${c} of ${tot} permissions"><span class="capbar"><span style="width:${Math.round(c/tot*100)}%"></span></span><span class="capn">${c}/${tot}</span></span></header><ul>${rows.map(x=>`<li class="${x[r.i]?'ok':'nope'}">${x[r.i]?yes(r):no}<span>${esc(x[0])}</span></li>`).join('')}</ul></section>`}).join('');
  return `<div class="rolesgrid"><table class="ptab rtab"><caption class="sr">Permissions for each business role</caption><thead><tr><th scope="col" class="rh0">What they can do</th>${head}</tr></thead>${body}</table></div><div class="rcards">${cards}</div>
   <p class="infochip"><span aria-hidden="true">${sv('<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>')}</span>Sub-admin seats exist on <b>Pro</b> and <b>Enterprise</b> only.</p>`;
 }
 function transferSection(){
  const c=(data.members||[]).filter(m=>!m.is_owner&&m.status==='active');
  return `<section class="xfer"><h3>Transfer ownership</h3>${c.length?`<p class="muted">Hand this business to someone on your team. They become the owner (billing, team and plan). You become a sub-admin if your plan has a free sub-admin seat; otherwise you lose access. The wallet and orders stay with the business. Carriacou Connect can also reassign an owner.</p><form id="xff" class="invform" autocomplete="off"><label>New owner<select id="xto">${c.map(m=>`<option value="${esc(m.user_id)}">${esc(m.name)} (${esc(CC.ROLE_LABEL[m.role]||m.role)}, ${esc(m.email||'')})</option>`).join('')}</select></label><label>Type the business name to confirm<input id="xcf" maxlength="80" placeholder="${esc(vendor.name)}"></label><button class="btn danger" type="submit">Transfer ownership</button></form>`:'<p class="muted">To transfer ownership, first add an active staff or sub-admin member. A business always has exactly one owner.</p>'}</section>`;
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
  const xf=box.querySelector('#xff');
  if(xf)xf.onsubmit=async e=>{e.preventDefault();const to=xf.querySelector('#xto'),nm=to.options[to.selectedIndex].text;if(xf.querySelector('#xcf').value.trim().toLowerCase()!==vendor.name.trim().toLowerCase()){say('Type the exact business name to confirm.');return}
   if(!confirm('Transfer '+vendor.name+' to '+nm+'? You will no longer be the owner.'))return;if(busy)return;busy=true;xf.querySelectorAll('button').forEach(b=>b.disabled=true);
   const r=await sb.rpc('transfer_vendor_ownership',{p_vendor:vendor.id,p_new_owner:to.value,p_confirm:xf.querySelector('#xcf').value.trim()});busy=false;
   if(r.error){await load();say(nice(r.error));return}
   box.innerHTML='<div class="notice ok" role="status">Ownership transferred to '+esc(r.data.new_owner)+'. '+(r.data.old_owner_role?'You are now a sub-admin.':'You no longer have access to this business.')+' <a href="dashboard-vendor.html">Continue</a></div>';setTimeout(()=>{location.href='dashboard-vendor.html'},2500)};
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
