// v1.0 multi-photo uploader for the vendor product form (window.CC.photos). No dependencies.
(function(){
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
// photos per product by plan (display copy; the database trigger is the real gatekeeper). Same numbers as tier_limits.max_photos.
const TIER_PHOTOS={lite:1,standard:1,plus:3,pro:3,enterprise:5};
const TIER_NAME={lite:'Lite',standard:'Standard',plus:'Plus+',pro:'Pro',enterprise:'Enterprise'};
const nextBetter=t=>{const cur=TIER_PHOTOS[t]||1;for(const k of ['lite','standard','plus','pro','enterprise'])if(TIER_PHOTOS[k]>cur)return {k,name:TIER_NAME[k],n:TIER_PHOTOS[k]};return null};
// Resize to max 1200px and re-encode (keeps PNG transparency as PNG, otherwise JPEG ~0.82).
async function shrink(file){
 const url=URL.createObjectURL(file);
 try{const im=await new Promise((ok,no)=>{const i=new Image();i.onload=()=>ok(i);i.onerror=()=>no(new Error('Could not read that image.'));i.src=url});
  const M=1200,k=Math.min(1,M/Math.max(im.naturalWidth,im.naturalHeight)),w=Math.max(1,Math.round(im.naturalWidth*k)),h=Math.max(1,Math.round(im.naturalHeight*k));
  const cv=document.createElement('canvas');cv.width=w;cv.height=h;const cx=cv.getContext('2d');
  const png=file.type==='image/png';if(!png){cx.fillStyle='#fff';cx.fillRect(0,0,w,h)}
  cx.drawImage(im,0,0,w,h);
  let type=png?'image/png':'image/jpeg',blob=await new Promise(r=>cv.toBlob(r,type,.82));
  if(png&&blob&&blob.size>1.8*1024*1024){type='image/jpeg';cx.globalCompositeOperation='destination-over';cx.fillStyle='#fff';cx.fillRect(0,0,w,h);blob=await new Promise(r=>cv.toBlob(r,type,.82))}
  if(!blob)throw new Error('Could not process that image.');
  return {blob,type,w,h}}
 finally{URL.revokeObjectURL(url)}}
// v1.19 EXIF hint (advisory only, never blocks): true = JPEG has camera Make/Model, false = JPEG without it, null = unknown (PNG/WebP/unreadable).
async function exifCamera(file){
 try{if(!/jpe?g/i.test(file.type))return null;const b=new DataView(await file.slice(0,131072).arrayBuffer());if(b.getUint16(0)!==0xFFD8)return null;let o=2;
  while(o+4<b.byteLength){const m=b.getUint16(o);if((m&0xFF00)!==0xFF00)return false;const L=b.getUint16(o+2);
   if(m===0xFFE1&&b.getUint32(o+4)===0x45786966){const t=o+10,le=b.getUint16(t)===0x4949,g16=x=>b.getUint16(x,le),g32=x=>b.getUint32(x,le);
    const ifd=t+g32(t+4),n=g16(ifd);for(let i=0;i<n;i++){const e=ifd+2+i*12,tag=g16(e);if((tag===0x010F||tag===0x0110)&&g32(e+4)>1)return true}return false}
   if(m===0xFFDA)return false;o+=2+L}return false}catch(e){return null}}
// o: {max, tier, upgradeHref (null = tell them to ask the owner), enabled}
function uploader(root,o){
 let max=o.max||1,items=[],initial=[],seq=0,busy=false;
 const S={};
 const room=()=>Math.max(0,max-items.length);
 root.innerHTML=`<div class="up-head"><span class="lbl">Product photos <small>(JPG, PNG or WebP, up to 2 MB each)</small></span><span class="up-count" id="upcount" aria-live="polite"></span></div>
  <div class="pgrid" id="pgrid"></div><input type="file" id="pfile" accept="image/jpeg,image/png,image/webp" multiple class="sr" aria-label="Choose product photos">
  <div id="upmsg" class="muted" role="status"></div><div id="upnote"></div>
  <div class="realph" id="realphw" hidden><label class="chk"><input type="checkbox" id="realph"> <span><b>These are real photos of this product taken by my shop</b> <small>(required for new photos)</small></span></label><p class="muted small">No stock, AI-generated or borrowed images. Food must show the actual dish as served. <a href="vendor-terms.html#photos" target="_blank" rel="noopener">Photo rule</a></p><div id="exifhint"></div></div>`;
 const $=s=>root.querySelector(s);
 const msg=(t,err)=>{const m=$('#upmsg');m.className=err?'err-text':'muted';m.textContent=t||''};
 function render(){
  const n=items.length,over=n>max;
  $('#upcount').innerHTML=`<b>${n} of ${max}</b> photo${max===1?'':'s'}${over?' <span class="up-over">over your plan</span>':''}`;
  $('#pgrid').innerHTML=items.map((it,i)=>`<div class="ptile" data-i="${i}"><div class="pimg"><img src="${esc(it.url)}" alt="Photo ${i+1} of ${n}${i===0?' (cover)':''}">${i===0?'<span class="pcover">Cover</span>':''}${it.blob?'<span class="pnew">New</span>':''}</div>
   <div class="pbar"><button type="button" data-act="left" aria-label="Move photo ${i+1} left" ${i===0?'disabled':''}>◀</button><button type="button" data-act="cover" aria-label="Make photo ${i+1} the cover" title="Set as cover" ${i===0?'disabled':''}>★</button><button type="button" data-act="right" aria-label="Move photo ${i+1} right" ${i===n-1?'disabled':''}>▶</button><button type="button" data-act="del" aria-label="Remove photo ${i+1}" title="Remove">✕</button></div></div>`).join('')
   +(room()>0&&!busy?`<label class="ptile padd" for="pfile" id="uppicklbl" tabindex="0"><span class="padd-in"><b>+</b><span>${n?'Add photo':'Choose photo'+(max>1?'s':'')}</span></span></label>`:'');
  const nb=nextBetter(o.tier);let note='';
  if(over)note=`<div class="notice">This product has ${n} photos but your plan allows ${max}. Your photos are kept, but you can't add more until you remove some${nb?' or upgrade':''}.</div>`;
  else if(room()===0)note=`<div class="up-full">You've used all ${max} photo slot${max===1?'':'s'} your ${esc(TIER_NAME[o.tier]||'current')} plan allows per product.${nb?(o.upgradeHref?` <a href="${esc(o.upgradeHref)}">Upgrade to ${esc(nb.name)}</a> for up to ${nb.n}.`:` Ask the business owner to upgrade to ${esc(nb.name)} for up to ${nb.n}.`):''}</div>`;
  else if(max>1&&n>0)note=`<div class="muted up-hint">The first photo is the cover shoppers see in lists. Use ◀ ▶ to reorder or ★ to pick the cover.</div>`;
  $('#upnote').innerHTML=note;
  const nw=items.some(x=>x.blob);$('#realphw').hidden=!nw;if(!nw)$('#realph').checked=false;
  const nc=items.filter(x=>x.blob&&x.camera===false).length;$('#exifhint').innerHTML=nc?`<p class="notice exifhint" role="note">Hint: ${nc} new photo${nc===1?' has':'s have'} no camera information. That can happen with edited or screenshot images. Please make sure ${nc===1?'it is a real photo':'they are real photos'} of your own product. (This is only a hint; it does not block saving.)</p>`:'';
  if(S.onChange)S.onChange(items)}
 const lbl=()=>{const l=$('#uppicklbl');if(l)l.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();$('#pfile').click()}}};
 $('#pgrid').addEventListener('click',e=>{const b=e.target.closest('button[data-act]');if(!b||b.disabled)return;const t=b.closest('.ptile'),i=+t.dataset.i,a=b.dataset.act;
  if(a==='left'||a==='right'){const j=a==='left'?i-1:i+1;[items[i],items[j]]=[items[j],items[i]]}
  else if(a==='cover'){const [x]=items.splice(i,1);items.unshift(x)}
  else if(a==='del'){const [x]=items.splice(i,1);if(x.blob)URL.revokeObjectURL(x.url);msg('Photo removed. Save to apply.')}
  render();lbl();const nb=$('#pgrid').querySelector(`.ptile[data-i="${a==='del'?Math.min(i,items.length-1):a==='left'?i-1:a==='cover'?0:i+1}"] button[data-act="${a==='del'?'del':a}"]`);if(nb&&!nb.disabled)nb.focus()});
 $('#pfile').onchange=async e=>{const files=[...e.target.files];e.target.value='';if(!files.length)return;
  msg('');const r0=room();if(r0===0){msg(`Your plan allows ${max} photo${max===1?'':'s'} per product.`,true);return}
  const take=files.slice(0,r0),skipped=files.length-take.length;busy=true;render();const errs=[];let added=0;
  for(const file of take){
   if(!/^image\/(jpeg|png|webp)$/.test(file.type)){errs.push(file.name+': please choose a JPG, PNG or WebP image.');continue}
   if(file.size>12*1024*1024){errs.push(file.name+': too large, choose one under 12 MB.');continue}
   try{const r=await shrink(file);if(r.blob.size>2*1024*1024)throw new Error('still over 2 MB after compression, try a smaller picture.');
    items.push({key:++seq,blob:r.blob,type:r.type,url:URL.createObjectURL(r.blob),camera:await exifCamera(file)});added++}
   catch(err){errs.push(file.name+': '+(err.message||'could not read that image.'))}}
  busy=false;render();lbl();
  const parts=[];if(added)parts.push(added+' photo'+(added===1?'':'s')+' added (resized). They upload when you save.');if(skipped)parts.push(skipped+' skipped: your plan allows '+max+' per product.');
  msg(parts.concat(errs).join(' '),errs.length>0&&!added)};
 S.setMax=m=>{max=m||1;render();lbl()};
 S.setTier=t=>{o.tier=t};
 S.set=urls=>{items.forEach(x=>{if(x.blob)URL.revokeObjectURL(x.url)});items=(urls||[]).map(u=>({key:++seq,url:u}));initial=items.map(x=>x.url);msg('');render();lbl()};
 S.urls=()=>items.map(x=>x.url);
 S.confirmed=()=>!!$('#realph').checked;
 S.exif=urls=>items.map((x,i)=>x.blob&&x.camera!=null?{url:urls[i],camera:x.camera}:null).filter(Boolean);
 S.count=()=>items.length;
 S.hasNew=()=>items.some(x=>x.blob);
 S.dirty=()=>items.some(x=>x.blob)||items.length!==initial.length||items.some((x,i)=>x.url!==initial[i]);
 S.removed=()=>initial.filter(u=>!items.some(x=>x.url===u));
 // upload new photos, return the final ordered list of public urls. up(blob,type) -> url. Rolls back its uploads on failure.
 S.commit=async(up,rm,progress)=>{const done=[];let k=0;const total=items.filter(x=>x.blob).length;
  try{const out=[];for(const it of items){if(it.blob){k++;if(progress)progress(`Uploading photo ${k} of ${total}…`);const u=await up(it.blob,it.type);done.push(u);out.push(u)}else out.push(it.url)}return {urls:out,uploaded:done}}
  catch(err){for(const u of done){try{await rm(u)}catch(e){}}throw err}};
 S.focus=()=>{const l=$('#uppicklbl');if(l)l.focus()};
 render();lbl();
 return S}
window.CC=window.CC||{};window.CC.photos={uploader,shrink,exifCamera,TIER_PHOTOS,TIER_NAME,nextBetter};
})();
