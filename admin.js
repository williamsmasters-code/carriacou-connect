// Platform admin (v0.9, TEST MODE). Only profiles.role='admin' can use it; every action is re-checked in the database.
(function(){
const CC=window.CC,esc=CC.esc,fdate=CC.fdate,$=s=>document.querySelector(s),R=$('#adm');
const nice=m=>/Could not find the function|schema cache/.test(m||'')?'Plans and admin tools are not switched on yet (staff.sql has not been run in Supabase).':m;
async function boot(){
 if(!CC.configured){R.innerHTML='<div class="notice">Accounts are not switched on in this preview.</div>';return}
 const sb=await CC.client(),user=sb&&await CC.getUser();
 if(!user){location.href='login.html?next=admin.html';return}
 const pr=await sb.from('profiles').select('role').eq('id',user.id).maybeSingle();
 if(!pr.data||pr.data.role!=='admin'){R.innerHTML='<div class="notice err">This page is for platform admins only.</div>';return}
 const tabsEl=$('#admtabs'),PA=$('#admpa');tabsEl.hidden=false;
 let tab='plans';if(CC.applications)CC.applications.pendingCount(sb).then(n=>{const b=tabsEl.querySelector('[data-t=applications]');if(b&&n)b.insertAdjacentHTML('beforeend',' <b class="nbadge" title="Applications waiting">'+n+'</b>')});
 const show=async()=>{tabsEl.querySelectorAll('button').forEach(b=>b.classList.toggle('on',b.dataset.t===tab));R.hidden=tab!=='plans';PA.hidden=tab==='plans';
  if(tab==='analytics'){PA.innerHTML='';await CC.platform.mountAnalytics(PA,sb)}else if(tab==='customers'){PA.innerHTML='';await CC.customers.mount(PA,sb)}else if(tab==='vendors'){PA.innerHTML='';await CC.vendors.mount(PA,sb)}else if(tab==='applications'){PA.innerHTML='';await CC.applications.mount(PA,sb)}else if(tab==='settings'){PA.innerHTML='';await CC.platform.mountSettings(PA,sb)}};
 const pick=t=>{tab=t;if(location.hash!=='#'+t&&t!=='plans')history.replaceState(null,'','#'+t);else if(t==='plans')history.replaceState(null,'',location.pathname+location.search);show()};
 tabsEl.querySelectorAll('button').forEach(b=>b.onclick=()=>pick(b.dataset.t));
 window.addEventListener('hashchange',()=>{const h=location.hash.slice(1);if(['analytics','applications','vendors','customers','settings'].includes(h)&&h!==tab){tab=h;show()}});
 let q='',msg='',mok=true;
 const load=async()=>{
  const [v,r]=await Promise.all([sb.rpc('admin_list_vendors'),sb.rpc('admin_list_requests',{p_status:null})]);
  if(v.error||r.error){R.innerHTML='<div class="notice err">'+esc(nice((v.error||r.error).message))+'</div>';return}
  draw(v.data||[],r.data||[]);
 };
 const call=async(fn,args,ok)=>{R.querySelectorAll('button').forEach(b=>b.disabled=true);const r=await sb.rpc(fn,args);msg=r.error?nice(r.error.message):ok;mok=!r.error;await load()};
 function draw(vs,rs){
  const pend=rs.filter(x=>x.status==='pending'),done=rs.filter(x=>x.status!=='pending').slice(0,15);
  const f=vs.filter(v=>!q||(v.name+' '+(v.owner_email||'')).toLowerCase().includes(q.toLowerCase()));
  R.innerHTML=CC.TESTBANNER.replace('play money, not real funds','plans are test only: no billing')+(msg?'<div class="notice '+(mok?'ok':'err')+'" role="alert">'+esc(msg)+'</div>':'')+
  '<h2>Upgrade requests <span class="nbadge">'+pend.length+'</span></h2>'+(pend.length?'<div class="reqs">'+pend.map(x=>'<div class="rqrow"><div><b>'+esc(x.vendor_name)+'</b> <span class="muted">'+esc(x.owner_email||'')+'</span><br>'+esc(CC.TIER_LABEL[x.current_tier])+' → <b>'+esc(CC.TIER_LABEL[x.to_tier])+'</b><small>'+esc(fdate(x.created_at))+(x.note?' · “'+esc(x.note)+'”':'')+'</small></div><div class="rqact"><button class="btn sm" data-ap="'+esc(x.id)+'">Approve</button> <button class="btn ghost sm" data-dc="'+esc(x.id)+'">Decline</button></div></div>').join('')+'</div>':'<p class="muted">No requests waiting.</p>')+
  (done.length?'<details><summary>Recent decisions</summary><ul class="auditlist">'+done.map(x=>'<li><b>'+esc(x.vendor_name)+'</b>: '+esc(CC.TIER_LABEL[x.from_tier])+' → '+esc(CC.TIER_LABEL[x.to_tier])+' · '+esc(x.status)+'<small>'+esc(fdate(x.decided_at||x.created_at))+'</small></li>').join('')+'</ul></details>':'')+
  '<h2>Vendors <span class="nbadge">'+vs.length+'</span></h2><p><input id="aq" type="search" placeholder="Search name or email" value="'+esc(q)+'" aria-label="Search vendors"></p>'+
  '<div class="tblwrap"><table class="admtab"><tr><th>Business</th><th>Plan</th><th>Staff</th><th>Sub-admins</th><th>Products</th><th>Set plan</th></tr>'+f.map(v=>'<tr><td><b>'+esc(v.name)+'</b>'+(v.is_sample?' <span class="pp pp-unpaid">SAMPLE</span>':'')+'<small>'+esc(v.owner_email||'no owner')+'</small></td><td><span class="badge t-'+esc(CC.TIER_LABEL[v.tier].replace('+',''))+'">'+esc(CC.TIER_LABEL[v.tier])+'</span>'+(v.pending_to_tier?'<small>wants '+esc(CC.TIER_LABEL[v.pending_to_tier])+'</small>':'')+(v.overridden?'<small>custom seats</small>':'')+'</td><td>'+v.staff+'</td><td>'+v.subadmins+'</td><td>'+v.products+'</td><td class="setcell"><select data-sel="'+esc(v.id)+'" aria-label="Plan for '+esc(v.name)+'">'+CC.TIERS.map(t=>'<option value="'+t.k+'"'+(t.k===v.tier?' selected':'')+'>'+esc(t.name)+'</option>').join('')+'</select> <button class="btn sm" data-set="'+esc(v.id)+'" data-name="'+esc(v.name)+'">Set</button>'+(v.tier==='enterprise'||v.overridden?' <button class="btn ghost sm" data-ov="'+esc(v.id)+'" data-name="'+esc(v.name)+'">Seats…</button>':'')+'</td></tr>').join('')+'</table></div>'+
  '<p class="muted">Moving a business to a smaller plan is blocked while it still has more products or team members than the smaller plan allows; the message says what to remove first. Changing a plan resets custom seat limits.</p>';
  const aq=$('#aq');aq.oninput=()=>{q=aq.value;const p=aq.selectionStart;draw(vs,rs);const n=$('#aq');n.focus();n.setSelectionRange(p,p)};
  R.querySelectorAll('[data-ap]').forEach(b=>b.onclick=()=>{if(confirm('Approve this upgrade? (test mode, no billing)'))call('admin_decide_request',{p_request:b.dataset.ap,p_approve:true,p_note:null},'Approved. The business is now on the new plan.')});
  R.querySelectorAll('[data-dc]').forEach(b=>b.onclick=()=>{const n=prompt('Reason for declining (optional internal note):','');if(n===null)return;call('admin_decide_request',{p_request:b.dataset.dc,p_approve:false,p_note:n||null},'Request declined.')});
  R.querySelectorAll('[data-set]').forEach(b=>b.onclick=()=>{const to=R.querySelector('[data-sel="'+b.dataset.set+'"]').value;if(confirm('Set '+b.dataset.name+' to the '+CC.TIER_LABEL[to]+' plan? (test mode)'))call('admin_set_tier',{p_vendor:b.dataset.set,p_tier:to,p_reason:'Set from the admin page'},'Plan updated.')});
  R.querySelectorAll('[data-ov]').forEach(b=>b.onclick=()=>{const s=prompt('Custom staff seats for '+b.dataset.name+' (blank = plan default):','');if(s===null)return;const a=prompt('Custom sub-admin seats (blank = plan default):','');if(a===null)return;
   const num=x=>x.trim()===''?null:Number(x);const ms=num(s),ma=num(a);if((ms!==null&&!Number.isInteger(ms))||(ma!==null&&!Number.isInteger(ma))){msg='Seats must be whole numbers.';mok=false;load();return}
   call('admin_set_plan_override',{p_vendor:b.dataset.ov,p_max_staff:ms,p_max_subadmins:ma},'Seat limits saved.')});
 }
 await load();
 {const h=location.hash.slice(1);if(['analytics','applications','vendors','customers','settings'].includes(h)){tab=h;await show()}}
}
boot().catch(e=>{console.error(e);R.innerHTML='<div class="notice err">Something went wrong. Please refresh.</div>'});
})();
