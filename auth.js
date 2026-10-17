// Accounts + dashboards (Supabase). Page chosen by <body data-page=...>.
(function(){
const {esc,xcd,configured,TIER_LABEL,TIER_LIMIT}=window.CC;
const $=s=>document.querySelector(s);
const CATS={food:'Food & Spices',crafts:'Crafts & Art',fashion:'Fashion & Textiles',beauty:'Beauty & Wellness',sea:'Sea & Boating',home:'Home & Garden'};
const PENDING='cconnect_pending_vendor';
const say=(el,msg,ok)=>{el.className=ok?'notice ok':'notice err';el.textContent=msg;el.hidden=!msg};
const main=()=>document.querySelector('main');
function offline(){main().innerHTML='<h1>Accounts are not switched on yet</h1><div class="notice">This preview is running in sample mode because Supabase is not configured. See README.txt (Supabase setup) to enable sign-up, login and the dashboards. <a href="browse.html">Browse the sample marketplace</a></div>'}
async function ctx(){ // {sb,user,profile}
 const sb=await window.CC.client();if(!sb)return null;
 const user=await window.CC.getUser();let profile=null;
 if(user){const r=await sb.from('profiles').select('*').eq('id',user.id).maybeSingle();profile=r.data}
 return {sb,user,profile};
}
const home=p=>p&&p.role==='vendor'?'dashboard-vendor.html':'dashboard-consumer.html';
async function createVendor(sb,user,v){
 return sb.from('vendors').insert({owner_id:user.id,name:v.name,description:v.description||'',location:v.location||''}).select().single();
}
const vendorFields=`<label>Business name<input id="bname" maxlength="80" required></label><label>Location (e.g. Hillsborough)<input id="bloc" maxlength="80"></label><label>About your business<textarea id="bdesc" rows="3" maxlength="500"></textarea></label><p class="muted">New businesses start on the <strong>Lite</strong> plan (up to 10 products).</p>`;

const pages={
async signup(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(c.user){location.href=home(c.profile);return}
 const f=$('#f'),msg=$('#msg'),vf=$('#vfields');vf.innerHTML=vendorFields;
 const sync=()=>{const v=f.role.value==='vendor';vf.hidden=!v;$('#bname').required=v};f.addEventListener('change',sync);sync();
 f.onsubmit=async e=>{e.preventDefault();say(msg,'');const btn=f.querySelector('button');btn.disabled=true;
  const role=f.role.value,biz={name:$('#bname').value.trim(),description:$('#bdesc').value.trim(),location:$('#bloc').value.trim()};
  const {data,error}=await c.sb.auth.signUp({email:f.email.value.trim(),password:f.password.value,options:{data:{role,full_name:f.fullname.value.trim()},emailRedirectTo:location.origin+location.pathname.replace(/[^/]*$/,'')+'login.html'}});
  if(error){say(msg,error.message);btn.disabled=false;return}
  if(role==='vendor')localStorage.setItem(PENDING,JSON.stringify(biz));
  if(data.session){location.href=home({role})}
  else{f.hidden=true;say(msg,'Almost done! Check your email and click the confirmation link, then log in. '+(role==='vendor'?'Your business profile will be created on first login.':''),true);msg.insertAdjacentHTML('beforeend',' <a href="login.html">Go to login</a>')}}
},
async login(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(c.user){location.href=home(c.profile);return}
 const f=$('#f'),msg=$('#msg');
 f.onsubmit=async e=>{e.preventDefault();say(msg,'');const btn=f.querySelector('button');btn.disabled=true;
  const {error}=await c.sb.auth.signInWithPassword({email:f.email.value.trim(),password:f.password.value});
  if(error){say(msg,error.message);btn.disabled=false;return}
  const c2=await ctx();location.href=home(c2.profile)};
 $('#forgot').onclick=async e=>{e.preventDefault();const em=f.email.value.trim();if(!em){say(msg,'Type your email above first.');return}
  const {error}=await c.sb.auth.resetPasswordForEmail(em,{redirectTo:location.origin+location.pathname.replace(/[^/]*$/,'')+'account.html'});
  say(msg,error?error.message:'Password reset email sent (if that address has an account).',!error)};
},
async account(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(!c.user){location.href='login.html';return}
 const p=c.profile||{role:'consumer'};
 $('#acct').innerHTML=`<p><strong>Email:</strong> ${esc(c.user.email)}<br><strong>Account type:</strong> ${esc(p.role)}<br><a href="${home(p)}">Go to my dashboard</a></p>
 <h2>Profile</h2><form id="pf"><label>Full name<input id="fn" value="${esc(p.full_name||'')}" maxlength="80"></label><label>Phone<input id="ph" value="${esc(p.phone||'')}" maxlength="30"></label><button class="btn">Save profile</button></form><div id="m1" class="notice" hidden></div>
 <h2>Change password</h2><form id="pw"><label>New password (min 8 characters)<input id="np" type="password" minlength="8" autocomplete="new-password" required></label><button class="btn alt">Update password</button></form><div id="m2" class="notice" hidden></div>
 <p><button class="btn alt" id="lo">Log out</button></p>`;
 $('#pf').onsubmit=async e=>{e.preventDefault();const {error}=await c.sb.from('profiles').update({full_name:$('#fn').value.trim()||null,phone:$('#ph').value.trim()||null}).eq('id',c.user.id);say($('#m1'),error?error.message:'Saved.',!error)};
 $('#pw').onsubmit=async e=>{e.preventDefault();const {error}=await c.sb.auth.updateUser({password:$('#np').value});say($('#m2'),error?error.message:'Password updated.',!error);if(!error)$('#np').value=''};
 $('#lo').onclick=async()=>{await c.sb.auth.signOut();location.href='index.html'};
},
async consumer(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(!c.user){location.href='login.html';return}
 const p=c.profile||{};
 const r=await c.sb.from('orders').select('id,status,total_xcd,created_at,vendors(name)').eq('consumer_id',c.user.id).order('created_at',{ascending:false});
 const rows=(r.data||[]);
 $('#dash').innerHTML=`<h2>My profile</h2><p><strong>${esc(p.full_name||'(no name set)')}</strong><br>${esc(c.user.email)}<br>Phone: ${esc(p.phone||'-')}<br><a href="account.html">Edit profile / password</a></p>
 <h2>Order history</h2>${rows.length?`<table><tr><th>Date</th><th>Vendor</th><th>Status</th><th>Total</th></tr>${rows.map(o=>`<tr><td>${esc(new Date(o.created_at).toLocaleDateString())}</td><td>${esc(o.vendors&&o.vendors.name||'')}</td><td>${esc(o.status)}</td><td>${xcd(o.total_xcd)}</td></tr>`).join('')}</table>`:'<div class="notice">No orders yet. Checkout and ordering arrive in a later version (v0.3). <a href="browse.html">Browse products</a></div>'}`;
},
async vendordash(){
 if(!configured)return offline();
 const c=await ctx();if(!c)return offline();
 if(!c.user){location.href='login.html';return}
 const {sb,user,profile}=c;
 if(!profile||profile.role!=='vendor'){$('#dash').innerHTML='<div class="notice">This dashboard is for vendor accounts. <a href="dashboard-consumer.html">Go to your consumer dashboard</a>. To sell, create a new vendor account with a different email.</div>';return}
 let vr=await sb.from('vendors').select('*').eq('owner_id',user.id).limit(1).maybeSingle();
 let vendor=vr.data;
 if(!vendor){let pend=null;try{pend=JSON.parse(localStorage.getItem(PENDING))}catch(e){}
  if(pend&&pend.name){const r=await createVendor(sb,user,pend);if(!r.error){vendor=r.data;localStorage.removeItem(PENDING)}}}
 if(!vendor){
  $('#dash').innerHTML=`<h2>Create your business profile</h2><form id="bf">${vendorFields}<button class="btn">Create business (Lite plan)</button></form><div id="bm" class="notice" hidden></div>`;
  $('#bf').onsubmit=async e=>{e.preventDefault();const r=await createVendor(sb,user,{name:$('#bname').value.trim(),description:$('#bdesc').value.trim(),location:$('#bloc').value.trim()});if(r.error)say($('#bm'),r.error.message);else location.reload()};return}
 const draw=async()=>{
  const pr=await sb.from('products').select('*').eq('vendor_id',vendor.id).order('created_at',{ascending:false});
  const prods=pr.data||[],lim=TIER_LIMIT[vendor.tier],used=prods.length,full=lim!=null&&used>=lim;
  const pct=lim?Math.min(100,Math.round(used/lim*100)):0;
  const ord=await sb.from('orders').select('id,status,total_xcd,created_at').eq('vendor_id',vendor.id).order('created_at',{ascending:false}).limit(20);
  $('#dash').innerHTML=`<h2>${esc(vendor.name)} <span class="badge t-${esc(TIER_LABEL[vendor.tier].replace('+',''))}">${esc(TIER_LABEL[vendor.tier])}</span></h2>
  <p class="muted">${esc(vendor.location||'')} ${vendor.description?'· '+esc(vendor.description):''}</p>
  <p><strong>Products: ${used} of ${lim==null?'unlimited':lim}</strong>${lim?`<span class="meter"><span style="width:${pct}%"></span></span>`:''}${full?'<br><span class="err-text">Limit reached. Delete a product or upgrade your plan (upgrades coming soon).</span>':''}</p>
  <h3 id="ftitle">Add a product</h3>
  <form id="pf"><input type="hidden" id="pid"><label>Name<input id="pn" maxlength="120" required></label><label>Description<textarea id="pd" rows="3" maxlength="1000"></textarea></label>
  <label>Price (EC$)<input id="pp" type="number" min="0" step="0.01" required></label>
  <label>Category<select id="pc">${Object.entries(CATS).map(([k,v])=>`<option value="${k}">${esc(v)}</option>`).join('')}</select></label>
  <label>Image URL (optional, https://…)<input id="pi" type="url" placeholder="https://"></label>
  <label class="chk"><input type="checkbox" id="pa" checked> Active (visible to shoppers)</label>
  <button class="btn" id="psave">Add product</button> <button type="button" class="btn alt" id="pcancel" hidden>Cancel edit</button></form><div id="pm" class="notice" hidden></div>
  <h3>Your products</h3>${prods.length?`<table><tr><th>Product</th><th>Price</th><th>Status</th><th></th></tr>${prods.map(p=>`<tr><td>${esc(p.name)}<div class="muted">${esc(CATS[p.category]||p.category)}</div></td><td>${xcd(p.price_xcd)}</td><td>${p.active?'Active':'Hidden'}</td><td><button class="btn alt" data-e="${p.id}">Edit</button> <button class="btn" data-d="${p.id}">Delete</button></td></tr>`).join('')}</table>`:'<p>No products yet.</p>'}
  <h3>Orders</h3>${(ord.data||[]).length?`<table><tr><th>Date</th><th>Status</th><th>Total</th></tr>${ord.data.map(o=>`<tr><td>${esc(new Date(o.created_at).toLocaleDateString())}</td><td>${esc(o.status)}</td><td>${xcd(o.total_xcd)}</td></tr>`).join('')}</table>`:'<div class="notice">No orders yet. Order management arrives in v0.3 with checkout.</div>'}`;
  const f=$('#pf'),m=$('#pm');
  const reset=()=>{f.reset();$('#pid').value='';$('#ftitle').textContent='Add a product';$('#psave').textContent='Add product';$('#pcancel').hidden=true;$('#pa').checked=true};
  if(full){$('#psave').disabled=true}
  $('#pcancel').onclick=()=>{reset();$('#psave').disabled=full};
  f.onsubmit=async e=>{e.preventDefault();say(m,'');
   const row={name:$('#pn').value.trim(),description:$('#pd').value.trim(),price_xcd:parseFloat($('#pp').value),category:$('#pc').value,image_url:$('#pi').value.trim()||null,active:$('#pa').checked};
   if(row.image_url&&!/^https?:\/\//i.test(row.image_url)){say(m,'Image URL must start with http:// or https://');return}
   const id=$('#pid').value;
   const r=id?await sb.from('products').update(row).eq('id',id):await sb.from('products').insert({...row,vendor_id:vendor.id});
   if(r.error){say(m,r.error.message);return}
   await draw()};
  document.querySelectorAll('[data-e]').forEach(b=>b.onclick=()=>{const p=prods.find(x=>x.id===b.dataset.e);$('#pid').value=p.id;$('#pn').value=p.name;$('#pd').value=p.description;$('#pp').value=p.price_xcd;$('#pc').value=p.category;$('#pi').value=p.image_url||'';$('#pa').checked=p.active;$('#ftitle').textContent='Edit product';$('#psave').textContent='Save changes';$('#psave').disabled=false;$('#pcancel').hidden=false;f.scrollIntoView()});
  document.querySelectorAll('[data-d]').forEach(b=>b.onclick=async()=>{if(!confirm('Delete this product?'))return;const r=await sb.from('products').delete().eq('id',b.dataset.d);if(r.error)say(m,r.error.message);else draw()});
 };
 await draw();
}
};
const k=document.body.dataset.page;
Promise.resolve(pages[k]()).catch(e=>{console.error(e);main().insertAdjacentHTML('beforeend','<div class="notice err">Something went wrong. Please refresh.</div>')});
})();
