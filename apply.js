// "Sell on Carriacou Connect" application + Application status view (v1.6). Needs supabase/vendor_onboarding.sql.
// The database re-checks everything (who you are, what status you are in). No email is sent: status is shown here.
(function(){
const CC=window.CC,esc=CC.esc,$=s=>document.querySelector(s),R=$('#ap'),fdate=CC.fdate;
const CATS={food:'Food & Spices',crafts:'Crafts & Art',fashion:'Fashion & Textiles',beauty:'Beauty & Wellness',sea:'Sea & Boating',home:'Home & Garden'};
const BT={sole_trader:'Sole trader / individual',company:'Registered company',cooperative:'Cooperative or group',nonprofit:'Non-profit or community group',other:'Other'};
const AREAS={'Carriacou':['Hillsborough','Tyrrel Bay',"L'Esterre",'Harvey Vale','Windward','Belair','Paradise','Bogles','Craigston','Dover','Lauriston','Mount Pleasant'],'Petite Martinique':['Petite Martinique'],'Grenada':['St. George','St. Andrew','St. David','St. John','St. Mark','St. Patrick']};
const STATUS={pending:['Waiting for review','st-placed'],changes_requested:['Changes requested','st-ready'],approved:['Approved','st-completed'],suspended:['Suspended','st-cancelled'],rejected:['Rejected','st-cancelled']};
const chip=s=>'<span class="st '+esc((STATUS[s]||[s,''])[1])+'">'+esc((STATUS[s]||[s])[0])+'</span>';
const nice=m=>{m=(m&&m.message)||String(m||'');return /Could not find the function|schema cache|does not exist/i.test(m)?'Vendor applications are not switched on yet (vendor_onboarding.sql has not been run in Supabase).':m.replace(/^ACCOUNT_SUSPENDED:\s*/,'')};
const opt=(o,sel)=>Object.entries(o).map(([k,v])=>'<option value="'+esc(k)+'"'+(k===sel?' selected':'')+'>'+esc(v)+'</option>').join('');
function form(a,edit){
 const x=a&&a.application||{},nm=a&&a.name||'',ds=a&&a.description||'';
 const tiers=CC.TIERS.map(t=>'<option value="'+t.k+'"'+((x.tier||'lite')===t.k?' selected':'')+'>'+esc(t.name)+' ('+(t.products==null?'unlimited':t.products)+' products)</option>').join('');
 return '<form id="apf" class="formcard apform" novalidate>'+
 '<h3>About your business</h3>'+
 '<label>Business name<input id="f-name" maxlength="80" required value="'+esc(nm)+'"></label>'+
 '<label>Main category<select id="f-cat">'+opt(CATS,x.category)+'</select></label>'+
 '<label>What do you sell? (shown on your public page)<textarea id="f-desc" rows="3" maxlength="500" required>'+esc(ds)+'</textarea></label>'+
 '<label>Business type<select id="f-bt">'+opt(BT,x.business_type)+'</select></label>'+
 '<h3>Where you are</h3>'+
 '<label>Island<select id="f-isl">'+opt({'Carriacou':'Carriacou','Petite Martinique':'Petite Martinique','Grenada':'Grenada (mainland)'},x.island)+'</select></label>'+
 '<label>Parish or area<input id="f-area" list="arealist" maxlength="60" required value="'+esc(x.area||'')+'" placeholder="e.g. Hillsborough"></label><datalist id="arealist"></datalist>'+
 '<h3>Contact (private)</h3><p class="muted">Only Carriacou Connect staff see these, to check your application. They are never shown on your shop page.</p>'+
 '<label>Contact phone<input id="f-phone" type="tel" maxlength="30" required value="'+esc(x.phone||'')+'" placeholder="+1 473 555 0100"></label>'+
 '<label>WhatsApp number (optional)<input id="f-wa" type="tel" maxlength="30" value="'+esc(x.whatsapp||'')+'"></label>'+
 '<label>Business registration or ID number (optional, text only)<input id="f-reg" maxlength="60" value="'+esc(x.registration_number||'')+'"></label>'+
 '<label class="chk"><input type="checkbox" id="f-vat"'+(x.vat_registered?' checked':'')+'> We are VAT registered</label>'+
 '<label id="f-vatl">VAT number<input id="f-vatn" maxlength="40" value="'+esc(x.vat_number||'')+'"></label>'+
 '<h3>How customers get their order</h3>'+
 '<label class="chk"><input type="checkbox" id="f-pu"'+(x.offers_pickup===false?'':' checked')+'> Pickup</label>'+
 '<label class="chk"><input type="checkbox" id="f-dl"'+(x.offers_delivery?' checked':'')+'> Delivery</label>'+
 '<h3>Starting plan</h3><label>Plan you would like<select id="f-tier">'+tiers+'</select></label><p class="muted">Plans are in test mode: nothing is billed. Carriacou Connect confirms your starting plan when it approves you, and you can ask to upgrade later.</p>'+
 '<label class="chk"><input type="checkbox" id="f-agree"> I have read and accept the <a href="vendor-terms.html" target="_blank" rel="noopener">Vendor Terms (draft)</a></label>'+
 '<div id="f-err" class="notice err" role="alert" hidden></div>'+
 '<button class="btn" type="submit">'+(edit?'Save and resubmit':'Submit application')+'</button></form>';
}
function wire(box,a,edit,done){
 const f=box.querySelector('#apf'),err=box.querySelector('#f-err');
 const areas=()=>{box.querySelector('#arealist').innerHTML=(AREAS[box.querySelector('#f-isl').value]||[]).map(v=>'<option value="'+esc(v)+'">').join('')};
 box.querySelector('#f-isl').onchange=areas;areas();
 const vatSync=()=>{box.querySelector('#f-vatl').hidden=!box.querySelector('#f-vat').checked};box.querySelector('#f-vat').onchange=vatSync;vatSync();
 f.onsubmit=async e=>{e.preventDefault();err.hidden=true;
  const g=id=>box.querySelector(id),p={name:g('#f-name').value.trim(),description:g('#f-desc').value.trim(),island:g('#f-isl').value,area:g('#f-area').value.trim(),category:g('#f-cat').value,phone:g('#f-phone').value.trim(),whatsapp:g('#f-wa').value.trim()||null,business_type:g('#f-bt').value,vat_registered:g('#f-vat').checked,vat_number:g('#f-vat').checked?g('#f-vatn').value.trim():null,registration_number:g('#f-reg').value.trim()||null,offers_pickup:g('#f-pu').checked,offers_delivery:g('#f-dl').checked,tier:g('#f-tier').value,agree_terms:g('#f-agree').checked};
  const bad=!p.name?'Enter your business name.':p.description.length<10?'Describe what you sell (at least 10 characters).':!p.area?'Enter your parish or area.':!p.phone?'Enter a contact phone number.':(p.vat_registered&&!p.vat_number)?'Enter your VAT number, or untick VAT registered.':(!p.offers_pickup&&!p.offers_delivery)?'Choose pickup, delivery or both.':!p.agree_terms?'Please accept the Vendor Terms to apply.':'';
  if(bad){err.textContent=bad;err.hidden=false;err.scrollIntoView({block:'nearest'});return}
  f.querySelectorAll('button').forEach(b=>b.disabled=true);
  const sb=await CC.client();const r=edit?await sb.rpc('update_vendor_application',{p_vendor:a.vendor_id,p:p}):await sb.rpc('submit_vendor_application',{p:p});
  if(r.error){err.textContent=nice(r.error);err.hidden=false;f.querySelectorAll('button').forEach(b=>b.disabled=false);err.scrollIntoView({block:'nearest'});return}
  done(edit?'Saved. Your application is back in the queue for review.':'Application sent. We will review it and the result will show on this page.')};
}
function statusCard(a){
 const msg={pending:'We are reviewing your application. No email is sent yet, so please check back on this page. You can still edit your answers below.',
  changes_requested:'We need a few changes before we can approve you. Please update your answers below and resubmit.',
  rejected:'We could not approve this application. You can fix the points below and resubmit it.',
  approved:'You are approved. Open your vendor dashboard to finish setting up your shop.',
  suspended:'This business is suspended, so shoppers cannot see it or place new orders. You can still see your existing orders. Please contact Carriacou Connect support.'}[a.status]||'';
 return '<div class="appcard"><div class="aphead"><h3>'+esc(a.name)+'</h3>'+chip(a.status)+'</div><p>'+esc(msg)+'</p>'+
  (a.status_reason&&a.status!=='approved'?'<div class="notice '+(a.status==='changes_requested'?'':'err')+'"><b>Message from Carriacou Connect:</b> '+esc(a.status_reason)+'</div>':'')+
  '<p class="muted">Applied '+esc(fdate(a.created_at))+(a.status_changed_at?' · last update '+esc(fdate(a.status_changed_at)):'')+(a.application&&a.application.tier?' · asked for the '+esc(CC.TIER_LABEL[a.application.tier]||a.application.tier)+' plan':'')+(a.status==='approved'||a.status==='suspended'?' · current plan '+esc(CC.TIER_LABEL[a.tier]||a.tier):'')+'</p>'+
  (a.status==='approved'||a.status==='suspended'?'<p><a class="btn" href="dashboard-vendor.html?v='+encodeURIComponent(a.vendor_id)+'">Open vendor dashboard</a></p>':'')+'</div>';
}
async function boot(){
 if(!CC.configured){R.innerHTML='<h1>Sell on Carriacou Connect</h1><div class="notice">Accounts are not switched on in this preview.</div>';return}
 const sb=await CC.client();if(!sb){R.innerHTML='<h1>Sell on Carriacou Connect</h1><div class="notice">Accounts are not switched on in this preview.</div>';return}
 const user=await CC.getUser();
 const intro='<span class="kicker">For businesses in Carriacou, Petite Martinique and Grenada</span><h1>Sell on Carriacou Connect</h1><p class="lead">Tell us about your business. We review every application before your shop is shown to shoppers. It is free to apply, and plans are in test mode (nothing is billed).</p><ol class="apsteps"><li><b>Apply</b> with your business details</li><li><b>We review</b> and approve, or ask for changes</li><li><b>Set up</b> your products, delivery and tax, then go live</li></ol>';
 if(!user){R.innerHTML=intro+'<div class="notice">To apply you need an account. Your application is linked to it so you can check its status.</div><p class="apcta"><a class="btn" href="signup.html?next=apply.html">Create an account</a> <a class="btn ghost" href="login.html?next=apply.html">Sign in</a></p><p class="muted"><a href="vendor-terms.html">Read the Vendor Terms (draft)</a></p>';return}
 const draw=async(flash,wantNew)=>{
  const r=await sb.rpc('my_applications');
  if(r.error){R.innerHTML='<h1>Sell on Carriacou Connect</h1><div class="notice err">'+esc(nice(r.error))+'</div>';return}
  const apps=r.data||[],open=apps.find(a=>a.can_edit),others=apps.filter(a=>a!==open&&!a.is_sample);
  const fl=flash?'<div class="notice ok" role="status">'+esc(flash)+'</div>':'';
  if(open){
   R.innerHTML='<span class="kicker">Application status</span><h1>'+esc(open.name)+'</h1>'+fl+statusCard(open)+'<h2>Your application</h2>'+form(open,true)+(others.length?'<h2>Your other businesses</h2>'+others.map(statusCard).join(''):'');
   wire(R,open,true,m=>draw(m));return}
  if(others.length&&!wantNew){
   R.innerHTML='<span class="kicker">Application status</span><h1>Your businesses</h1>'+fl+others.map(statusCard).join('')+'<p><button class="btn ghost" id="apnew" type="button">Apply for another business</button></p>';
   $('#apnew').onclick=()=>draw('',true);return}
  R.innerHTML=intro+fl+form(null,false);wire(R,null,false,m=>draw(m));
 };
 await draw('');
}
boot().catch(e=>{console.error(e);R.innerHTML='<div class="notice err">Something went wrong. Please refresh.</div>'});
})();
