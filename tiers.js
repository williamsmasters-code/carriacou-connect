// Plans page (v0.9). TEST MODE: no billing exists. Limits shown here are a display copy of the tier_limits table (the database enforces them).
(function(){
const CC=window.CC,esc=CC.esc,$=s=>document.querySelector(s);
const R=$('#plans');
const T=CC.TIERS;
const yes='<span class="yes" aria-label="Included">✓</span>',no='<span class="no" aria-label="Not included">–</span>',soon='<small class="soonlbl">coming soon</small>';
const rows=[
 ['Business owner account',()=>'1 included'],
 ['Staff accounts',t=>CC.lim(t.staff).replace('Unlimited','Variable')+(t.k==='lite'?' (owner only)':'')],
 ['Sub-admin accounts',t=>t.sub===0?no:CC.lim(t.sub).replace('Unlimited','Variable')],
 ['Products',t=>CC.lim(t.products)],
 ['Business dashboard + orders',()=>yes],
 ['Wallet payments and refunds (test)',()=>yes],
 ['POS',t=>t.pos],
 ['Basic analytics (sales, top products, stock alerts)',()=>yes],
 ['Business analytics',t=>t.bizAnalytics?yes+' '+soon:no],
 ['Multiple locations',t=>t.multi?yes+' '+soon:no],
 ['Dedicated support',t=>t.support?yes:no]];
async function boot(){
 let cur=null,sb=null,vendor=null,plan=null,pending=null,access=null;
 if(CC.configured){
  sb=await CC.client();const user=sb&&await CC.getUser();
  if(user){try{const r=await sb.rpc('my_vendor_access');if(!r.error&&r.data)access=r.data.find(a=>a.is_owner)||r.data[0]||null}catch(e){}
   if(access){vendor=access;cur=access.tier;try{const p=await sb.rpc('vendor_plan',{p_vendor:access.vendor_id});if(!p.error){plan=p.data;pending=p.data.pending_request;cur=p.data.tier}}catch(e){}}}
 }
 const ci=T.findIndex(t=>t.k===cur);
 const owner=!!(access&&access.is_owner);
 const act=t=>{const i=T.findIndex(x=>x.k===t.k);
  if(!owner)return t.k==='lite'?'<span class="muted">Every new business starts here</span>':'<a class="btn ghost" href="signup.html">Sign up to sell</a>';
  if(i===ci)return '<span class="curtag">Your current plan</span>';
  if(i<ci)return '<span class="muted">Below your plan</span>';
  if(pending&&pending.to_tier===t.k)return '<span class="curtag wait">Requested: waiting for approval</span>';
  if(pending)return '<span class="muted">Another request is pending</span>';
  return '<button class="btn" data-req="'+esc(t.k)+'" type="button">Request '+esc(t.name)+'</button>'};
 R.innerHTML=CC.TESTBANNER.replace('play money, not real funds','plans are for testing: <u>billing is not live</u>, nobody is charged')+
 '<p class="lead">Every business starts on <b>Lite</b>. A plan sets how many team accounts and products you can have. Pricing will be announced before billing goes live.'+(owner?'':' <a href="login.html?next=tiers.html">Log in</a> as a vendor to request an upgrade.')+'</p>'+
 '<div id="rmsg" class="notice" hidden role="alert"></div>'+
 '<div class="tiercards">'+T.map((t,i)=>'<article class="tiercard'+(t.k===cur?' current':'')+(t.k==='pro'?' pop':'')+'"><span class="kicker">'+esc(t.tag)+'</span><h2><span class="badge t-'+esc(t.name.replace('+',''))+'">'+esc(t.name)+'</span></h2><p class="muted">'+esc(t.blurb)+'</p>'+
   '<ul class="tierul"><li><b>'+esc(CC.lim(t.products))+'</b> products</li><li><b>'+(t.staff===0?'No':esc(CC.lim(t.staff).replace('Unlimited','Variable')))+'</b> staff</li>'+(t.sub?'<li><b>'+esc(CC.lim(t.sub).replace('Unlimited','Variable'))+'</b> sub-admins</li>':'')+'<li>'+esc(t.pos)+' POS</li>'+(t.bizAnalytics?'<li>Business analytics</li>':'')+(t.multi?'<li>Multiple locations</li>':'')+(t.support?'<li>Dedicated support</li>':'')+'</ul><div class="tieract">'+act(t)+'</div></article>').join('')+'</div>'+
 '<h2>Compare plans</h2><div class="tblwrap"><table class="cmp"><tr><th>Feature</th>'+T.map(t=>'<th class="'+(t.k===cur?'cur':'')+'">'+esc(t.name)+'</th>').join('')+'</tr>'+rows.map(r=>'<tr><td>'+esc(r[0])+'</td>'+T.map(t=>'<td class="'+(t.k===cur?'cur':'')+'">'+r[1](t)+'</td>').join('')+'</tr>').join('')+'</table></div>'+
 '<p class="muted">“Variable” means the team size is agreed with Carriacou Connect. Features marked <i>coming soon</i> are planned, not built yet. Campaigns and advertising are also planned for every plan.</p>'+
 '<h2>Who can do what in a team</h2><div class="tblwrap"><table class="ptab"><tr><th>Action</th><th>Staff</th><th>Sub-admin</th><th>Owner</th></tr>'+
 [['Manage orders, order notes and POS',1,1,1],['See all products',1,1,1],['Add, edit and delete products',0,1,1],['Refund wallet-paid orders',0,1,1],['Analytics',0,1,1],['Invite, change or remove team members',0,0,1],['Business wallet, profile and plan requests',0,0,1]].map(r=>'<tr><td>'+esc(r[0])+'</td>'+[1,2,3].map(i=>'<td>'+(r[i]?yes:no)+'</td>').join('')+'</tr>').join('')+'</table></div>';
 R.querySelectorAll('[data-req]').forEach(b=>b.onclick=async()=>{const to=b.dataset.req,m=$('#rmsg');
  if(!confirm('Request the '+CC.TIER_LABEL[to]+' plan?\n\nTEST MODE: billing is not live. The request goes to the Carriacou Connect team to approve. You are not charged.'))return;
  R.querySelectorAll('button').forEach(x=>x.disabled=true);
  const r=await sb.rpc('request_upgrade',{p_vendor:vendor.vendor_id,p_tier:to,p_note:null});
  if(r.error){m.className='notice err';m.textContent=/schema cache|Could not find/.test(r.error.message)?'Plans are not switched on yet (staff.sql has not been run).':r.error.message;m.hidden=false;R.querySelectorAll('button').forEach(x=>x.disabled=false);return}
  boot()});
}
boot().catch(e=>{console.error(e);R.innerHTML='<div class="notice err">Something went wrong. Please refresh.</div>'});
})();
