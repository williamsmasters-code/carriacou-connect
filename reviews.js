// v1.19 Ratings and reviews (window.CC.reviews). Needs supabase/reviews.sql. Text and stars only: no photos, no uploads.
// Every comment and reply is plain text and is escaped here before display (white-space: pre-line keeps line breaks).
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc;
const fd=d=>{try{return new Date(d).toLocaleDateString('en-GB',{timeZone:'America/Grenada',day:'numeric',month:'short',year:'numeric'})}catch(e){return ''}};
const nice=e=>{const m=(e&&e.message)||String(e||'');if(/Could not find|schema cache|does not exist/i.test(m))return 'Reviews are not switched on yet (reviews.sql has not been run in Supabase).';return m};
const starsTxt=n=>'★★★★★'.slice(0,Math.round(n||0))+'☆☆☆☆☆'.slice(0,5-Math.round(n||0));
const stars=(n,label)=>'<span class="stars" role="img" aria-label="'+esc(label||((n?(+n).toFixed(1):'0')+' out of 5 stars'))+'"><span aria-hidden="true">'+starsTxt(n)+'</span></span>';
const avg=v=>v==null?'–':(+v).toFixed(1);
const IMGRX=/<\s*(img|picture|svg|iframe)\b|!\[[^\]]*\]\s*\(|\[\s*img\s*\]|data:\s*image\/|\.(jpe?g|png|gif|webp|bmp|svg|heic|heif|avif|tiff?|ico)(\?\S*)?(\s|$|[)"'>\]])/i;
const noImg=t=>IMGRX.test(t||'')?'Photos and images are not allowed in reviews or replies: text only, please remove the image or image link.':null;
function starInput(name,label,val,req){return '<fieldset class="starin"><legend>'+esc(label)+(req?'':' <small>(optional)</small>')+'</legend><div class="starrow">'+
 [1,2,3,4,5].map(i=>'<label class="starbtn"><input type="radio" name="'+name+'" value="'+i+'"'+(val===i?' checked':'')+'><span aria-hidden="true">★</span><span class="sr">'+i+' star'+(i>1?'s':'')+'</span></label>').join('')+
 (req?'':'<label class="starbtn clear"><input type="radio" name="'+name+'" value=""'+(val?'':' checked')+'><span>None</span></label>')+'</div></fieldset>'}
const breakdown=s=>'<div class="rv-bars">'+[5,4,3,2,1].map(k=>{const c=+(s.breakdown||{})[k]||0,p=s.count?Math.round(c*100/s.count):0;return '<div class="rv-bar"><span>'+k+' ★</span><span class="rv-track" aria-hidden="true"><i style="width:'+p+'%"></i></span><span>'+c+'</span></div>'}).join('')+'</div>';
function reviewHtml(r,o){
 return '<article class="rv" data-id="'+esc(r.id)+'"><header class="rv-h">'+stars(r.rating)+' <b>'+esc(r.author)+'</b> <span class="badge rv-ver">Verified buyer</span> <span class="muted">'+esc(fd(r.created_at))+(r.edited_at?' · edited':'')+'</span></header>'+
 (r.service_rating?'<p class="rv-svc muted">Shop service: '+stars(r.service_rating,'Shop service '+r.service_rating+' out of 5')+'</p>':'')+
 (r.comment?'<p class="rv-c">'+esc(r.comment)+'</p>':'')+
 (r.status==='hidden'?'<p class="notice err small">Hidden by Carriacou Connect'+(r.hidden_reason?': '+esc(r.hidden_reason):'')+'</p>':'')+
 (r.reply?'<div class="rv-reply"><b>Reply from the shop</b><p>'+esc(r.reply.body)+'</p></div>':'')+
 (o&&o.actions!==false?'<div class="rv-act">'+(o.signedIn&&!r.mine?'<button type="button" class="btn ghost sm" data-help="'+esc(r.id)+'" aria-pressed="'+(r.voted?'true':'false')+'">👍 Helpful'+(r.helpful?' ('+r.helpful+')':'')+'</button>':(r.helpful?'<span class="muted">'+r.helpful+' found this helpful</span>':''))+
 (o.signedIn&&!r.mine?' <button type="button" class="btn ghost sm" data-rep="'+esc(r.id)+'">Report</button>':'')+'</div><div class="rv-repf" id="rep-'+esc(r.id)+'"></div>':'')+
 (o&&o.reply?'<div class="rv-replyf">'+o.reply(r)+'</div>':'')+'</article>'}
function reportForm(box,submit,choices){box.innerHTML='<form class="rv-rf" novalidate>'+(choices?'<label>Reason<select name="why">'+choices.map(c=>'<option value="'+esc(c[0])+'">'+esc(c[1])+'</option>').join('')+'</select></label>':'')+'<label>What is wrong?'+(choices?' <small>(optional for photo reports)</small>':'')+'<input name="note" maxlength="300" placeholder="e.g. rude language, not about the product"></label><div class="rv-btns"><button class="btn" type="submit">Send report</button><button class="btn ghost" type="button" data-x>Cancel</button></div><p class="rv-rm" role="status"></p></form>';
 const f=box.querySelector('form');f.querySelector('[data-x]').onclick=()=>box.innerHTML='';
 f.onsubmit=async e=>{e.preventDefault();const r=await submit(f.why?f.why.value:null,f.note.value.trim());const m=f.querySelector('.rv-rm');if(r.error){m.className='rv-rm err-text';m.textContent=nice(r.error);return}box.innerHTML='<p class="notice ok">Thank you. Carriacou Connect will check it.</p>'}}

// ---------- product page ----------
async function productMount(el,o){
 const {sb,productId}=o;let sort='new',user=null;try{user=await CC.getUser()}catch(e){}
 el.innerHTML='<section class="rvs" id="reviews" aria-labelledby="rvh"><h2 id="rvh">Ratings and reviews</h2><div id="rv-body"><p class="muted">Loading reviews…</p></div></section>';
 const B=el.querySelector('#rv-body');
 async function load(){
  const r=await sb.rpc('review_list',{p_product:productId,p_sort:sort,p_limit:50,p_offset:0});
  if(r.error){B.innerHTML='<p class="muted">'+esc(nice(r.error))+'</p>';return}
  const s=r.data.summary,list=r.data.reviews||[];
  let el2=[];if(user){const e=await sb.rpc('review_eligible',{p_product:productId});if(!e.error)el2=e.data||[]}
  B.innerHTML='<div class="rv-grid"><aside class="rv-side"><div class="rv-sum">'+(s.count?'<p class="rv-big">'+avg(s.avg)+' <small>out of 5</small></p>'+stars(s.avg)+'<p class="muted">'+s.count+' verified review'+(s.count===1?'':'s')+'</p>'+breakdown(s):'<p class="muted">No reviews yet.</p>')+'</div>'+
   '<div id="rv-write" class="rv-write"></div>'+
   '<div class="rv-listrep"><button type="button" class="btn ghost sm" id="rv-lrep">Report this listing</button><div id="rv-lrepf"></div></div></aside>'+
   '<div class="rv-main">'+(list.length?'<div class="rv-tools"><label>Sort <select id="rv-sort"><option value="new"'+(sort==='new'?' selected':'')+'>Newest</option><option value="helpful"'+(sort==='helpful'?' selected':'')+'>Most helpful</option></select></label></div>':'')+
   '<div class="rv-list">'+list.map(x=>reviewHtml(x,{signedIn:!!user})).join('')+'</div></div></div>';
  const W=B.querySelector('#rv-write');
  if(!user)W.innerHTML='<p class="muted">Only verified buyers can review. <a href="login.html?next='+encodeURIComponent(location.pathname.split('/').pop()+location.search)+'">Sign in</a> to review a product you bought.</p>';
  else if(!el2.length)W.innerHTML='<p class="muted">You can review this product after an order with it is completed or delivered.</p>';
  else{const it=el2.find(x=>!x.review)||el2.find(x=>x.review&&x.review.can_edit);
   if(!it)W.innerHTML='<p class="muted">Thanks, you have reviewed this product. Reviews can be edited for 30 days.</p>';
   else writeForm(W,it)}
  const so=B.querySelector('#rv-sort');if(so)so.onchange=()=>{sort=so.value;load()};
  B.querySelectorAll('[data-help]').forEach(b=>b.onclick=async()=>{b.disabled=true;const x=await sb.rpc('review_helpful_toggle',{p_review:b.dataset.help});b.disabled=false;if(x.error){alert(nice(x.error));return}
   b.setAttribute('aria-pressed',x.data.voted?'true':'false');b.textContent='👍 Helpful'+(x.data.helpful?' ('+x.data.helpful+')':'')});
  B.querySelectorAll('[data-rep]').forEach(b=>b.onclick=()=>reportForm(B.querySelector('#rep-'+CSS.escape(b.dataset.rep)),(w,n)=>sb.rpc('review_report',{p_review:b.dataset.rep,p_reason:n})));
  const lr=B.querySelector('#rv-lrep');lr.onclick=()=>{if(!user){location.href='login.html?next='+encodeURIComponent(location.pathname.split('/').pop()+location.search);return}
   reportForm(B.querySelector('#rv-lrepf'),(w,n)=>sb.rpc('report_listing',{p_product:productId,p_reason:w,p_note:n||null,p_image_url:null}),[['photo_mismatch','Photo doesn\u2019t match / stock photo'],['other','Something else']])};
 }
 function writeForm(W,it){const r=it.review;
  W.innerHTML='<form class="rv-form formcard" id="rv-f" novalidate><h3>'+(r?'Edit your review':'Write a review')+'</h3><p class="muted small">Verified purchase: order '+esc(it.order_number||'')+' · '+esc(fd(it.ordered_at))+'</p>'+
   starInput('rv-r','Product rating',r&&r.rating,true)+starInput('rv-s','Shop service (delivery, communication)',r&&r.service_rating,false)+
   '<label>Comment <small>(optional, text only, up to 1000 characters)</small><textarea id="rv-c" maxlength="1000" rows="4" placeholder="What was it like?">'+esc(r&&r.comment||'')+'</textarea></label><p class="muted small" id="rv-cc"></p>'+
   '<p class="muted small">Text and stars only: photos and image links are not allowed. Please follow the <a href="vendor-terms.html#reviews" target="_blank" rel="noopener">review guidelines</a>.'+(r?' You can edit this review until '+esc(fd(new Date(new Date(r.created_at).getTime()+30*864e5)))+'.':' You can edit it for 30 days.')+'</p>'+
   '<button class="btn" type="submit">'+(r?'Save changes':'Post review')+'</button><p id="rv-m" role="status"></p></form>';
  const f=W.querySelector('#rv-f'),c=f.querySelector('#rv-c'),cc=f.querySelector('#rv-cc'),m=f.querySelector('#rv-m');
  const cnt=()=>{cc.textContent=c.value.length+' / 1000'};c.oninput=cnt;cnt();
  f.onsubmit=async e=>{e.preventDefault();const rt=f.querySelector('[name=rv-r]:checked'),sv=f.querySelector('[name=rv-s]:checked');
   const say=t=>{m.className='err-text';m.textContent=t};
   if(!rt){say('Choose a product rating (1 to 5 stars).');return}const bad=noImg(c.value);if(bad){say(bad);return}
   const x=await sb.rpc('review_submit',{p_order_item:it.order_item_id,p_rating:+rt.value,p_service_rating:sv&&sv.value?+sv.value:null,p_comment:c.value.trim()||null});
   if(x.error){say(nice(x.error));return}await load();const w=el.querySelector('#rv-write');if(w)w.insertAdjacentHTML('afterbegin','<p class="notice ok">'+(r?'Your review was updated.':'Thank you! Your review is posted.')+'</p>')}}
 await load();
}

// ---------- shop page: service rating ----------
async function shopMount(el,sb,vendorId){try{const r=await sb.rpc('shop_service_rating',{p_vendor:vendorId});if(r.error||!r.data||!r.data.review_count){el.innerHTML='';return}const d=r.data;
 el.innerHTML='<p class="rv-shop">'+(d.service_count?'<span>Shop service '+stars(d.service_avg)+' <b>'+avg(d.service_avg)+'</b> <span class="muted">('+d.service_count+')</span></span>':'')+'<span>Products '+stars(d.product_avg)+' <b>'+avg(d.product_avg)+'</b> <span class="muted">('+d.review_count+' review'+(d.review_count===1?'':'s')+')</span></span></p>'}catch(e){el.innerHTML=''}}

// ---------- vendor dashboard tab ----------
async function vendorMount(el,o){
 const {sb,vendor,me}=o,canReply=me&&['admin','subadmin'].includes(me.role);let flt='all';
 el.innerHTML='<p class="muted">Loading reviews…</p>';
 const r=await sb.rpc('vendor_reviews',{p_vendor:vendor.id});if(r.error){el.innerHTML='<div class="notice err">'+esc(nice(r.error))+'</div>';return}
 const d=r.data,s=d.summary,mx=Math.max(1,...d.trend.map(t=>t.count));
 const replyF=x=>canReply?'<details class="rv-rd"'+(x.reply?'':' open')+'><summary>'+(x.reply?'Edit your public reply':'Reply publicly')+'</summary><form data-rf="'+esc(x.id)+'" novalidate><label class="sr" for="rf-'+esc(x.id)+'">Reply</label><textarea id="rf-'+esc(x.id)+'" maxlength="1000" rows="3" placeholder="Thank the customer or explain what you will do. Text only.">'+esc(x.reply?x.reply.body:'')+'</textarea><button class="btn" type="submit">'+(x.reply?'Save reply':'Post reply')+'</button><p role="status" class="rfm"></p></form></details>':'';
 const draw=()=>{const L=d.reviews.filter(x=>flt==='all'||(flt==='low'&&x.rating<=2)||(flt==='noreply'&&!x.reply));
  el.innerHTML='<section class="rvv"><div class="rvv-head"><h3>Reviews</h3><div class="sgc-sum"><div><b>'+avg(s.avg)+' ★</b><span>product rating</span></div><div><b>'+avg(s.service_avg)+' ★</b><span>shop service ('+s.service_count+')</span></div><div><b>'+s.count+'</b><span>reviews</span></div><div><b>'+s.unreplied+'</b><span>without a reply</span></div></div></div>'+
  '<p class="muted small">Reviews come only from customers with a completed order. You can reply once publicly to each review (and edit your reply). You cannot delete reviews; if one breaks the guidelines, report it to Carriacou Connect.</p>'+
  (d.alerts.length?'<div class="notice err rvv-alert" role="alert"><b>⚠ '+d.alerts.length+' low rating'+(d.alerts.length===1?'':'s')+' in the last 30 days without a reply</b><ul>'+d.alerts.map(a=>'<li>'+stars(a.rating)+' '+esc(a.product_name)+' · '+esc(fd(a.created_at))+'</li>').join('')+'</ul></div>':'')+
  '<div class="rvv-grid"><aside><div class="formcard"><h4>Star breakdown</h4>'+breakdown(s)+'</div><div class="formcard"><h4>Last 6 months</h4><div class="rv-trend">'+d.trend.map(t=>'<div class="rv-tm"><span class="rv-tb" style="height:'+Math.round(t.count*100/mx)+'%" title="'+t.count+' reviews"></span><b>'+(t.avg==null?'–':avg(t.avg))+'</b><small>'+esc(t.month.slice(5))+'/'+esc(t.month.slice(2,4))+'</small></div>').join('')+'</div><p class="muted small">Bar = number of reviews; number = average stars.</p></div></aside>'+
  '<div><div class="rv-tools"><label>Show <select id="rvv-f"><option value="all">All reviews</option><option value="low">1-2 stars</option><option value="noreply">No reply yet</option></select></label></div>'+
  (L.length?L.map(x=>reviewHtml({...x,mine:false},{actions:false,reply:replyF}).replace('<header class="rv-h">','<header class="rv-h"><span class="rv-pn">'+esc(x.product_name)+'</span> ')).join(''):'<p class="muted">No reviews here yet.</p>')+'</div></div></section>';
  el.querySelector('#rvv-f').value=flt;el.querySelector('#rvv-f').onchange=e=>{flt=e.target.value;draw()};
  el.querySelectorAll('[data-rf]').forEach(f=>f.onsubmit=async e=>{e.preventDefault();const t=f.querySelector('textarea').value.trim(),m=f.querySelector('.rfm');m.className='rfm err-text';
   if(!t){m.textContent='Write a reply first.';return}const bad=noImg(t);if(bad){m.textContent=bad;return}
   const x=await sb.rpc('vendor_review_reply',{p_review:f.dataset.rf,p_body:t});if(x.error){m.textContent=nice(x.error);return}
   const rv=d.reviews.find(z=>z.id===f.dataset.rf);rv.reply={body:x.data.body,at:new Date().toISOString()};d.alerts=d.alerts.filter(a=>a.id!==rv.id);s.unreplied=d.reviews.filter(z=>!z.reply).length;draw();
   const n=el.querySelector('[data-id="'+CSS.escape(rv.id)+'"]');if(n)n.insertAdjacentHTML('beforeend','<p class="notice ok">Reply posted.</p>')})};
 draw();
}

// ---------- vendor dashboard: notices from Carriacou Connect ----------
async function noticesMount(el,sb,vendor){try{const r=await sb.rpc('vendor_notices_list',{p_vendor:vendor.id});if(r.error){el.innerHTML='';return}const d=r.data,un=d.notices.filter(n=>!n.read);
 if(!un.length&&!d.unconfirmed_photos&&!d.no_camera_data){el.innerHTML='';return}
 el.innerHTML='<div class="notice vnotice" role="status">'+(un.length?'<b>Message'+(un.length===1?'':'s')+' from Carriacou Connect</b><ul>'+un.map(n=>'<li>'+esc(n.message)+' <small class="muted">'+esc(fd(n.at))+'</small></li>').join('')+'</ul>':'')+
 (d.unconfirmed_photos?'<p><b>'+d.unconfirmed_photos+' photo'+(d.unconfirmed_photos===1?'':'s')+' not yet confirmed as real.</b> Open each product with Edit, check the photos and tick "These are real photos of this product taken by my shop".</p>':'')+
 (d.no_camera_data?'<p class="muted small">Hint: '+d.no_camera_data+' photo'+(d.no_camera_data===1?' has':'s have')+' no camera information. This is only a hint, not a decision. Make sure every photo shows your real product.</p>':'')+
 (un.length?'<button type="button" class="btn ghost sm" id="vn-ok">Mark as read</button>':'')+'</div>';
 const b=el.querySelector('#vn-ok');if(b)b.onclick=async()=>{await sb.rpc('vendor_notice_read',{p_vendor:vendor.id});noticesMount(el,sb,vendor)}}catch(e){el.innerHTML=''}}

// ---------- admin moderation queue ----------
async function adminMount(el,sb){let view='reviews',rf='reported',lf='open';
 const draw=async msg=>{el.innerHTML='<section class="rvm"><h2>Reviews and listing reports</h2><div class="dtabs" role="tablist"><button type="button" role="tab" data-v="reviews" class="'+(view==='reviews'?'on':'')+'">Reviews</button><button type="button" role="tab" data-v="listings" class="'+(view==='listings'?'on':'')+'">Listing photos</button></div><div id="rvm-msg"></div><div id="rvm-b"><p class="muted">Loading…</p></div></section>';
  el.querySelectorAll('[data-v]').forEach(b=>b.onclick=()=>{view=b.dataset.v;draw()});
  if(msg)el.querySelector('#rvm-msg').innerHTML='<div class="notice ok" role="status">'+esc(msg)+'</div>';
  const B=el.querySelector('#rvm-b');
  if(view==='reviews'){const r=await sb.rpc('admin_review_queue',{p_filter:rf});if(r.error){B.innerHTML='<div class="notice err">'+esc(nice(r.error))+'</div>';return}const d=r.data;
   B.innerHTML='<div class="rv-tools"><label>Show <select id="rvm-f"><option value="reported">Reported ('+d.open_reports+')</option><option value="hidden">Hidden ('+d.hidden+')</option><option value="all">All reviews</option></select></label></div>'+
   (d.items.length?'<div class="rvm-list">'+d.items.map(x=>'<div class="formcard rvm-item">'+reviewHtml(x,{actions:false})+'<p class="muted small">'+esc(x.product_name)+' · '+esc(x.vendor_name)+'</p>'+
    (x.reports.length?'<ul class="auditlist">'+x.reports.map(p=>'<li>'+esc(p.reason)+'<small>'+esc(fd(p.at))+' · '+esc(p.status)+'</small></li>').join('')+'</ul>':'')+
    '<form data-mod="'+esc(x.id)+'" class="rvm-f" novalidate><label>Reason <small>(required to hide)</small><input name="why" maxlength="300"></label><div class="rv-btns">'+(x.status==='visible'?'<button class="btn danger" type="submit" value="hide">Hide review</button>':'<button class="btn" type="submit" value="restore">Restore review</button>')+(x.open_reports?'<button class="btn ghost" type="submit" value="dismiss">Dismiss reports</button>':'')+'</div><p class="rfm err-text" role="status"></p></form></div>').join('')+'</div>':'<p class="muted">Nothing to review.</p>');
   B.querySelector('#rvm-f').value=rf;B.querySelector('#rvm-f').onchange=e=>{rf=e.target.value;draw()};
   B.querySelectorAll('[data-mod]').forEach(f=>f.onsubmit=async e=>{e.preventDefault();const a=(e.submitter&&e.submitter.value)||'hide',why=f.why.value.trim();
    if(a==='hide'&&why.length<3){f.querySelector('.rfm').textContent='Give a reason for hiding (at least 3 characters).';return}
    const x=await sb.rpc('admin_review_moderate',{p_review:f.dataset.mod,p_action:a,p_reason:why||null});if(x.error){f.querySelector('.rfm').textContent=nice(x.error);return}draw(({hide:'Review hidden.',restore:'Review restored.',dismiss:'Reports dismissed.'})[a])})}
  else{const r=await sb.rpc('admin_listing_queue',{p_filter:lf});if(r.error){B.innerHTML='<div class="notice err">'+esc(nice(r.error))+'</div>';return}const d=r.data;
   B.innerHTML='<div class="rv-tools"><label>Show <select id="rvm-lf"><option value="open">Open reports ('+d.open+')</option><option value="all">All reported listings</option></select></label></div><p class="muted small">Real-photos rule: stock, AI-generated or borrowed images are not allowed. The "no camera data" mark is only a hint.</p>'+
   (d.items.length?'<div class="rvm-list">'+d.items.map(x=>'<div class="formcard rvm-item"><h4>'+esc(x.product_name)+' <small class="muted">'+esc(x.vendor_name)+'</small>'+(x.admin_hidden?' <span class="badge sgc-void">Listing hidden</span>':'')+'</h4>'+
    '<div class="rvm-imgs">'+x.images.map(i=>'<figure class="rvm-img'+(i.hidden?' hid':'')+'"><img src="'+esc(i.url)+'" alt="Listing photo" loading="lazy"><figcaption>'+(i.hidden?'Hidden':i.confirmed_at?'Confirmed real '+esc(fd(i.confirmed_at)):'Not confirmed')+(i.exif_camera===false?' · no camera data (hint)':'')+'</figcaption>'+(i.hidden?'':'<button type="button" class="btn ghost sm" data-hi="'+esc(i.url)+'">Hide this image</button>')+'</figure>').join('')+'</div>'+
    '<ul class="auditlist">'+x.reports.map(p=>'<li>'+esc(p.reason==='photo_mismatch'?'Photo doesn\u2019t match / stock photo':'Other')+(p.note?': '+esc(p.note):'')+'<small>'+esc(fd(p.at))+' · '+esc(p.status)+'</small></li>').join('')+'</ul>'+
    '<form data-lm="'+esc(x.product_id)+'" class="rvm-f" novalidate><label>Note to the vendor <small>(shown in their dashboard; required to hide)</small><input name="note" maxlength="300" placeholder="e.g. Please upload a photo of your own dish."></label><div class="rv-btns"><button class="btn danger" type="submit" value="hide_listing">Hide listing</button><button class="btn ghost" type="submit" value="dismiss">Dismiss</button>'+(x.admin_hidden?'<button class="btn" type="button" data-rs>Allow listing again</button>':'')+'</div><p class="rfm err-text" role="status"></p></form></div>').join('')+'</div>':'<p class="muted">No listing reports.</p>');
   B.querySelector('#rvm-lf').value=lf;B.querySelector('#rvm-lf').onchange=e=>{lf=e.target.value;draw()};
   B.querySelectorAll('[data-lm]').forEach(f=>{const go=async(a,url)=>{const note=f.note.value.trim(),m=f.querySelector('.rfm');if(a!=='dismiss'&&note.length<3){m.textContent='Write a note to the vendor (at least 3 characters).';return}
     const x=await sb.rpc('admin_listing_moderate',{p_product:f.dataset.lm,p_action:a,p_image_url:url||null,p_note:note||null});if(x.error){m.textContent=nice(x.error);return}draw(({hide_image:'Image hidden. The vendor was told.',hide_listing:'Listing hidden. The vendor was told.',dismiss:'Report dismissed.'})[a])};
    f.onsubmit=e=>{e.preventDefault();go((e.submitter&&e.submitter.value)||'dismiss')};
    f.closest('.rvm-item').querySelectorAll('[data-hi]').forEach(b=>b.onclick=()=>go('hide_image',b.dataset.hi));
    const rs=f.querySelector('[data-rs]');if(rs)rs.onclick=async()=>{const x=await sb.rpc('admin_listing_restore',{p_product:f.dataset.lm});if(x.error){f.querySelector('.rfm').textContent=nice(x.error);return}draw('The shop can switch the listing on again.')}})}
 };
 await draw();
}

// ---------- featured ranking (see formula in reviews.sql) ----------
async function featuredSort(sb,products){try{const r=await sb.rpc('public_product_scores',{p_ids:products.map(p=>p.id)});if(r.error||!Array.isArray(r.data))return products;
 const rank=new Map(r.data.map((x,i)=>[x.id,i]));return products.slice().sort((a,b)=>(rank.has(a.id)?rank.get(a.id):1e9)-(rank.has(b.id)?rank.get(b.id):1e9))}catch(e){return products}}
CC.reviews={productMount,shopMount,vendorMount,noticesMount,adminMount,featuredSort,stars,noImg};
})();
