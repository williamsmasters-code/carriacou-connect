// v1.17 shop layout switch.
// Public: CC.shopLayout.render(el, ctx, renderDefault) — if the shop is set to a CUSTOM layout, loads
//   /custom/<slug>/layout.css (optional) and /custom/<slug>/layout.js, then calls the layout's render(el, ctx).
//   Any problem (no SQL yet, missing file, script error, timeout, render throws) falls back to the default layout.
// Admin: CC.shopLayout.adminMount(el, sb, vendor) — default/custom switch (database only lets admins change it).
(function(){
const C=window.CC||(window.CC={});const esc=C.esc||(s=>String(s==null?'':s).replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';'));
const SLUG=/^[a-z0-9][a-z0-9-]{0,47}$/;
const REG=window.CC_LAYOUTS=window.CC_LAYOUTS||{};
// a custom layout.js calls CC.registerLayout('<slug>', {render(el, ctx){...}})
C.registerLayout=(slug,def)=>{REG[slug]=def};
const loadScript=(src,ms)=>new Promise((res,rej)=>{const s=document.createElement('script');s.src=src;s.async=true;let done=false;
 const t=setTimeout(()=>{if(!done){done=true;rej(new Error('timeout'))}},ms);
 s.onload=()=>{if(!done){done=true;clearTimeout(t);res()}};s.onerror=()=>{if(!done){done=true;clearTimeout(t);rej(new Error('missing '+src))}};document.head.appendChild(s)});
async function getLayout(vendorId){
 try{if(!C.configured)return {mode:'default'};const sb=await C.client();if(!sb)return {mode:'default'};
  const r=await sb.rpc('shop_layout',{p_vendor:vendorId});if(r.error||!r.data)return {mode:'default'};return r.data}catch(e){return {mode:'default'}}}
async function render(el,ctx,renderDefault){
 const L=await getLayout(ctx.shop.id);
 if(L.mode!=='custom'||!SLUG.test(L.slug||'')){renderDefault();return {mode:'default'}}
 const base='custom/'+L.slug+'/';let css=null;
 try{
  css=document.createElement('link');css.rel='stylesheet';css.href=base+'layout.css';css.dataset.customLayout=L.slug;
  css.onerror=()=>{css&&css.remove()};document.head.appendChild(css);   // css is optional
  if(!REG[L.slug])await loadScript(base+'layout.js',6000);
  const def=REG[L.slug];if(!def||typeof def.render!=='function')throw new Error('layout.js did not call CC.registerLayout("'+L.slug+'", …)');
  el.innerHTML='';el.classList.add('custom-layout','cl-'+L.slug);document.body.classList.add('has-custom-layout');
  await def.render(el,Object.assign({slug:L.slug,renderDefault},ctx));
  return {mode:'custom',slug:L.slug}
 }catch(e){
  console.warn('Custom layout "'+L.slug+'" failed, using the default layout:',e&&e.message||e);
  if(css)css.remove();el.classList.remove('custom-layout','cl-'+L.slug);document.body.classList.remove('has-custom-layout');el.innerHTML='';
  renderDefault();window.__layoutFallback=(window.__layoutFallback||0)+1;return {mode:'default',fallback:true,error:String(e&&e.message||e)}}
}
async function adminMount(el,sb,v){
 const draw=async(note,ok)=>{
  const r=await sb.rpc('shop_layout',{p_vendor:v.id});
  if(r.error){el.innerHTML='<h3>Shop layout</h3><p class="muted">Not switched on yet: run supabase/shop_layouts.sql in Supabase.</p>';return}
  const L=r.data||{mode:'default'};
  el.innerHTML=`<h3>Shop layout</h3>${note?`<div class="notice ${ok?'ok':'err'}" role="status">${esc(note)}</div>`:''}
  <p class="muted">Every shop uses the <b>default</b> layout. A <b>custom</b> layout is a bespoke design built by Carriacou Connect (paid service) and served from <code>/custom/&lt;key&gt;/layout.js</code>. If the custom file is missing or breaks, shoppers automatically see the default layout.</p>
  <form id="vl-f" novalidate><fieldset class="vl-mode"><legend>Layout</legend>
   <label class="chk"><input type="radio" name="vl-m" value="default"${L.mode!=='custom'?' checked':''}> <span>Default layout</span></label>
   <label class="chk"><input type="radio" name="vl-m" value="custom"${L.mode==='custom'?' checked':''}> <span>Custom layout</span></label></fieldset>
   <label>Custom layout key (folder under /custom/)<input id="vl-slug" maxlength="48" placeholder="e.g. pizza-palace" value="${esc(L.slug||'')}" autocomplete="off" spellcheck="false"></label>
   <label>Note (optional)<input id="vl-note" maxlength="300" placeholder="e.g. Iteration 2 approved by owner"></label>
   <p class="vl-acts"><button class="btn" type="submit">Save layout</button> <a class="btn ghost" href="vendor.html?id=${encodeURIComponent(v.id)}" target="_blank" rel="noopener">View shop page</a> <a class="btn ghost" href="admin.html#exits" id="vl-charge">Log a setup / design charge →</a></p>
   <p class="muted"><small>Charging for a custom layout is manual: use “Charge a platform service” (Setup / photo service) on the Funds &amp; exits tab. Nothing is charged automatically.</small></p></form>`;
  el.querySelector('#vl-f').onsubmit=async e=>{e.preventDefault();const m=el.querySelector('[name=vl-m]:checked').value,s=el.querySelector('#vl-slug').value.trim().toLowerCase();
   if(m==='custom'&&!SLUG.test(s))return draw('Enter a layout key: lowercase letters, numbers and dashes (it must match the folder name).',false);
   const x=await sb.rpc('admin_set_vendor_layout',{p_vendor:v.id,p_mode:m,p_slug:s||null,p_note:el.querySelector('#vl-note').value.trim()||null});
   if(x.error)return draw(x.error.message,false);await draw(m==='custom'?'Custom layout "'+s+'" switched on for '+v.name+'.':'Default layout switched on for '+v.name+'.',true)};
 };
 await draw();
}
C.shopLayout={render,adminMount,getLayout};
})();
