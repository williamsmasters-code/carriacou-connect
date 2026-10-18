// Vendor onboarding checklist + application-status screen for the vendor dashboard (v1.6). Needs supabase/vendor_onboarding.sql.
// "Live" rule (enforced by the database): the business is approved AND has at least one active product.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc;
const ITEMS={
 profile:['Business profile','Write a description (20+ characters), check your area, and add a logo.'],
 product:['First product with a photo','Add at least one active product that has a photo.'],
 delivery:['Pickup and delivery','Choose pickup, delivery or both, and set your delivery fee.'],
 tax:['VAT and tax','Confirm whether you are VAT registered (and your VAT number).'],
 payment:['Payment information','Tell Carriacou Connect how you take payment (e.g. cash on pickup, Connect Pay wallet in test mode).'],
 staff:['Invite a helper (optional)','Add a staff member or sub-admin if your plan has team seats.']};
const nice=m=>{m=(m&&m.message)||String(m||'');return /Could not find the function|schema cache|does not exist/i.test(m)?'Onboarding is not switched on yet (vendor_onboarding.sql has not been run in Supabase).':m};
function pendingHtml(v,own){
 const st=v.status,msg={pending:'Your application is being reviewed by Carriacou Connect. Your shop is not visible to shoppers yet.',changes_requested:'Carriacou Connect asked for changes to your application.',rejected:'Your application was not approved.'}[st]||'This business is waiting for approval.';
 return '<h2>'+esc(v.name)+'</h2><div class="notice '+(st==='rejected'?'err':'')+'" role="status"><b>'+esc(st==='pending'?'Waiting for review':st==='changes_requested'?'Changes requested':st==='rejected'?'Not approved':st)+'.</b> '+esc(msg)+(v.status_reason?' <br><b>Message:</b> '+esc(v.status_reason):'')+'</div>'+
  (own?'<p><a class="btn" href="apply.html">Application status'+(st==='pending'?'':' and edit')+'</a></p><p class="muted">You can already prepare products from this dashboard once you are approved. No email is sent, so check this page for updates.</p>':'<p class="muted">Only the business owner can edit the application.</p>');
}
async function shrinkUpload(sb,file,folder){
 if(!/^image\/(jpeg|png|webp)$/.test(file.type))throw new Error('Choose a JPG, PNG or WebP picture.');
 const r=await CC.photos.shrink(file);if(r.blob.size>2*1024*1024)throw new Error('Still over 2 MB after compression, try a smaller picture.');
 const ext=r.type==='image/png'?'png':'jpg',path=folder+'/logo-'+Date.now()+'.'+ext;
 const u=await sb.storage.from('product-images').upload(path,r.blob,{contentType:r.type,cacheControl:'31536000',upsert:false});if(u.error)throw u.error;
 return sb.storage.from('product-images').getPublicUrl(path).data.publicUrl;
}
function mount(box,o){
 if(!box)return;
 const {sb,vendor}=o;let st=null,open='',msg='',mok=true;
 const owner=!!o.isOwner,canEdit=!!(o.can&&o.can('vendor_edit'));
 async function load(){
  const r=await sb.rpc('vendor_onboarding_status',{p_vendor:vendor.id});
  if(r.error){box.innerHTML=/not switched on/.test(nice(r.error))?'':'<div class="notice err">'+esc(nice(r.error))+'</div>';return}
  st=r.data;draw();
 }
 function go(key){
  if(key==='profile'||key==='payment'){open=open===key?'':key;draw();return}
  if(key==='product')return o.goTab&&o.goTab('products');
  if(key==='delivery'||key==='tax')return o.goTab&&o.goTab('delivery');
  if(key==='staff')return o.goTab&&o.goTab('team');
 }
 function draw(){
  const items=st.items,all=st.done===st.total,live=st.live;
  const row=i=>{const L=ITEMS[i.key]||[i.key,''],tabOk={product:(o.TABS||[]).includes('products'),delivery:(o.TABS||[]).includes('delivery'),tax:(o.TABS||[]).includes('delivery'),staff:(o.TABS||[]).includes('team'),profile:canEdit,payment:canEdit}[i.key];
   return '<li class="ck'+(i.done?' done':'')+'" data-key="'+esc(i.key)+'"><span class="ckmark" aria-hidden="true">'+(i.done?'✓':'○')+'</span><div class="ckbody"><b>'+esc(L[0])+'</b>'+(i.optional?' <small class="muted">optional</small>':'')+'<small>'+esc(L[1])+'</small></div>'+
    (tabOk?'<button type="button" class="btn ghost sm" data-go="'+esc(i.key)+'">'+(i.done?'Review':'Do this')+'</button>':'<span class="muted ckna">'+(i.key==='staff'?'Needs a plan with team seats':'Owner only')+'</span>')+'</li>'};
  const body='<div class="ckhead"><div><h3>Set up your shop</h3><p class="muted">'+st.done+' of '+st.total+' steps done</p></div><div class="ckpct" aria-label="'+st.pct+' percent complete">'+st.pct+'%</div></div>'+
   '<div class="meter ckmeter" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="'+st.pct+'"><span style="width:'+st.pct+'%"></span></div>'+
   '<div class="cklive '+(live?'on':'off')+'" role="status">'+(live?'<b>Your shop is live.</b> Shoppers can see it and order from it.':'<b>Not live yet.</b> '+(st.can_go_live?'':'Add at least one <b>active</b> product to go live.'))+' <small class="muted">Go-live rule: approved and at least one active product. Everything else here helps shoppers trust you.</small></div>'+
   '<ul class="cklist">'+items.map(row).join('')+'</ul>'+
   (msg?'<div class="notice '+(mok?'ok':'err')+'" role="alert">'+esc(msg)+'</div>':'')+
   '<div id="ckedit"></div>';
  box.innerHTML='<section class="ckbox">'+(all&&live?'<details><summary><b>Setup complete ✓</b> <span class="muted">Your shop is live. Open to review.</span></summary>'+body+'</details>':body)+'</section>';
  box.querySelectorAll('[data-go]').forEach(b=>b.onclick=()=>go(b.dataset.go));
  if(open)editor();
 }
 async function editor(){
  const ed=box.querySelector('#ckedit');
  if(open==='profile'){
   ed.innerHTML='<form class="formcard ckform" id="ckpf"><h4>Business profile</h4><label>Description (shown to shoppers)<textarea id="ck-desc" rows="3" maxlength="500">'+esc(vendor.description||'')+'</textarea></label><label>Area<input id="ck-loc" maxlength="80" value="'+esc(vendor.location||'')+'"></label>'+
    '<div class="cklogo">'+(vendor.logo_url?'<img src="'+esc(vendor.logo_url)+'" alt="Current logo" width="64" height="64">':'<span class="muted">No logo yet</span>')+'</div><label>Logo (JPG, PNG or WebP)<input type="file" id="ck-logo" accept="image/jpeg,image/png,image/webp"></label><div id="ck-m" class="notice" hidden></div><button class="btn" type="submit">Save profile</button> <button class="btn ghost" type="button" id="ck-x">Close</button></form>';
   ed.querySelector('#ck-x').onclick=()=>{open='';draw()};
   ed.querySelector('#ckpf').onsubmit=async e=>{e.preventDefault();const m=ed.querySelector('#ck-m');const bt=e.target.querySelectorAll('button');bt.forEach(b=>b.disabled=true);
    try{const upd={description:ed.querySelector('#ck-desc').value.trim(),location:ed.querySelector('#ck-loc').value.trim()};
     if(upd.location.length<2)throw new Error('Enter your area.');
     const f=ed.querySelector('#ck-logo').files[0];if(f)upd.logo_url=await shrinkUpload(sb,f,(await CC.getUser()).id);
     const r=await sb.from('vendors').update(upd).eq('id',vendor.id).select().maybeSingle();if(r.error)throw r.error;
     Object.assign(vendor,r.data);msg='Profile saved.';mok=true;open='';await load()}
    catch(er){m.className='notice err';m.textContent=nice(er);m.hidden=false;bt.forEach(b=>b.disabled=false)}};
  }else if(open==='payment'){
   ed.innerHTML='<form class="formcard ckform" id="ckpay"><h4>Payment information</h4><p class="muted">Private: only you and Carriacou Connect staff see this. Never put card numbers or passwords here.</p><label>How do you take payment?<textarea id="ck-pay" rows="3" maxlength="500" placeholder="e.g. Cash on pickup; Connect Pay wallet (test)"></textarea></label><div id="ck-m" class="notice" hidden></div><button class="btn" type="submit">Save</button> <button class="btn ghost" type="button" id="ck-x">Close</button></form>';
   ed.querySelector('#ck-x').onclick=()=>{open='';draw()};
   const g=await sb.rpc('get_vendor_payment_info',{p_vendor:vendor.id});if(!g.error&&g.data&&ed.querySelector('#ck-pay'))ed.querySelector('#ck-pay').value=g.data.payment_info||'';
   ed.querySelector('#ckpay').onsubmit=async e=>{e.preventDefault();const m=ed.querySelector('#ck-m');e.target.querySelectorAll('button').forEach(b=>b.disabled=true);
    const r=await sb.rpc('set_vendor_payment_info',{p_vendor:vendor.id,p_text:ed.querySelector('#ck-pay').value});
    if(r.error){m.className='notice err';m.textContent=nice(r.error);m.hidden=false;e.target.querySelectorAll('button').forEach(b=>b.disabled=false);return}
    msg='Payment information saved.';mok=true;open='';await load()};
  }
 }
 document.querySelectorAll('.dtabs button').forEach(b=>b.addEventListener('click',()=>setTimeout(()=>{if(box.isConnected&&!open)load()},700)));
 return load();
}
CC.onboarding={mount,pendingHtml};
})();
