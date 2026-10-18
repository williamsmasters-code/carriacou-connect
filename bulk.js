// v1.0 bulk product upload / export (window.CC.bulk). CSV required, .xlsx via the browser's own unzip (no library).
(function(){
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const COLS=['sku','name','description','category','price_xcd','stock_qty','low_stock_threshold','cost_price','active','image_url'];
const CATS={food:'Food & Spices',crafts:'Crafts & Art',fashion:'Fashion & Textiles',beauty:'Beauty & Wellness',sea:'Sea & Boating',home:'Home & Garden'};
const MAX_ROWS=20000,MAX_BYTES=8*1024*1024,BATCH=200,CHECK_BATCH=500;
const TEMPLATE='sku,name,description,category,price_xcd,stock_qty,low_stock_threshold,cost_price,active,image_url\r\n'+
 'NUT-100,"Example: Nutmeg, whole (100 g)","Freshly picked Carriacou nutmeg, whole, 100 g bag",food,12.50,40,5,8.00,yes,\r\n'+
 'BSK-001,Example: Woven market basket,Hand-woven basket in local palm leaf,crafts,45.00,6,2,28.00,yes,https://example.com/images/basket.jpg\r\n'+
 'SUN-250,Example: Reef-safe sunscreen 250 ml,,beauty,32.00,,,,yes,\r\n';
// ---------- CSV ----------
function detectDelim(t){let inq=false,c=0,s=0,tb=0;for(let i=0;i<t.length&&i<4000;i++){const ch=t[i];if(ch==='"')inq=!inq;else if(!inq){if(ch==='\n'||ch==='\r')break;if(ch===',')c++;else if(ch===';')s++;else if(ch==='\t')tb++}}return tb>c&&tb>s?'\t':s>c?';':','}
function parseCSV(text){
 if(text.charCodeAt(0)===0xFEFF)text=text.slice(1);
 const d=detectDelim(text),rows=[];let row=[],f='',inq=false,i=0;const n=text.length;
 while(i<n){const ch=text[i];
  if(inq){if(ch==='"'){if(text[i+1]==='"'){f+='"';i+=2;continue}inq=false;i++;continue}f+=ch;i++;continue}
  if(ch==='"'&&f===''){inq=true;i++;continue}
  if(ch===d){row.push(f);f='';i++;continue}
  if(ch==='\r'||ch==='\n'){if(ch==='\r'&&text[i+1]==='\n')i++;row.push(f);f='';rows.push(row);row=[];i++;continue}
  f+=ch;i++}
 if(f!==''||row.length){row.push(f);rows.push(row)}
 return rows}
const csvCell=(v,guard)=>{let s=v==null?'':String(v);if(guard&&/^[=+\-@\t\r]/.test(s)&&!/^-?\d+(\.\d+)?$/.test(s))s="'"+s;return /[",\r\n;]/.test(s)||/^\s|\s$/.test(s)?'"'+s.replace(/"/g,'""')+'"':s};
const toCSV=(rows,guard)=>rows.map(r=>r.map(v=>csvCell(v,guard)).join(',')).join('\r\n')+'\r\n';
// ---------- XLSX (zip + XML, using DecompressionStream) ----------
async function inflate(buf){const ds=new DecompressionStream('deflate-raw');const w=ds.writable.getWriter();w.write(buf);w.close();return new Uint8Array(await new Response(ds.readable).arrayBuffer())}
async function unzip(ab){
 const u8=new Uint8Array(ab),dv=new DataView(ab);let e=-1;
 for(let i=u8.length-22;i>=Math.max(0,u8.length-66000);i--)if(dv.getUint32(i,true)===0x06054b50){e=i;break}
 if(e<0)throw new Error('This does not look like an .xlsx file.');
 let n=dv.getUint16(e+10,true),p=dv.getUint32(e+16,true);const files={};
 for(let k=0;k<n;k++){if(dv.getUint32(p,true)!==0x02014b50)break;
  const meth=dv.getUint16(p+10,true),cs=dv.getUint32(p+20,true),nl=dv.getUint16(p+28,true),el=dv.getUint16(p+30,true),cl=dv.getUint16(p+32,true),lo=dv.getUint32(p+42,true);
  const name=new TextDecoder().decode(u8.subarray(p+46,p+46+nl));p+=46+nl+el+cl;
  files[name]=async()=>{const ln=dv.getUint16(lo+26,true),le=dv.getUint16(lo+28,true),s=lo+30+ln+le,raw=u8.subarray(s,s+cs);return meth===0?raw:meth===8?await inflate(raw):Promise.reject(new Error('Unsupported zip compression'))}}
 return files}
const colIdx=r=>{let n=0;for(const ch of r.replace(/[0-9]/g,''))n=n*26+ch.charCodeAt(0)-64;return n-1};
async function parseXLSX(ab){
 if(typeof DecompressionStream==='undefined')throw new Error('This browser cannot open .xlsx files. Save the sheet as CSV (UTF-8) and upload that instead.');
 const z=await unzip(ab),txt=async n=>z[n]?new TextDecoder().decode(await z[n]()):null;
 const xml=s=>new DOMParser().parseFromString(s,'application/xml');
 let shared=[];const ss=await txt('xl/sharedStrings.xml');
 if(ss)shared=[...xml(ss).getElementsByTagName('si')].map(si=>[...si.getElementsByTagName('t')].filter(t=>!t.closest||!t.closest('rPh')).map(t=>t.textContent).join(''));
 let sheet='xl/worksheets/sheet1.xml';
 const wb=await txt('xl/workbook.xml'),rels=await txt('xl/_rels/workbook.xml.rels');
 if(wb&&rels){const sh=xml(wb).getElementsByTagName('sheet')[0];if(sh){const rid=sh.getAttribute('r:id')||sh.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships','id');
  const rel=[...xml(rels).getElementsByTagName('Relationship')].find(r=>r.getAttribute('Id')===rid);if(rel){let t=rel.getAttribute('Target');t=t.replace(/^\/?(xl\/)?/,'');sheet='xl/'+t}}}
 const sx=await txt(sheet);if(!sx)throw new Error('Could not find a worksheet in that file.');
 const out=[];
 for(const r of xml(sx).getElementsByTagName('row')){const row=[];
  for(const c of r.getElementsByTagName('c')){const ref=c.getAttribute('r'),i=ref?colIdx(ref):row.length,t=c.getAttribute('t');let v='';
   const ve=c.getElementsByTagName('v')[0];
   if(t==='s')v=shared[+(ve&&ve.textContent)]||'';else if(t==='inlineStr')v=[...c.getElementsByTagName('t')].map(x=>x.textContent).join('');else if(ve)v=ve.textContent;
   if(t==='b')v=v==='1'?'yes':'no';
   while(row.length<i)row.push('');row[i]=v}
  const ri=+r.getAttribute('r');if(ri)while(out.length<ri-1)out.push([]);out.push(row)}
 return out}
// ---------- columns, cleaning, validation (mirrors bulk_upsert_products on the server; the server re-checks everything) ----------
const ALIAS={sku:'sku',code:'sku',item_code:'sku',product_code:'sku',item_sku:'sku',
 name:'name',product:'name',product_name:'name',title:'name',item:'name',item_name:'name',
 description:'description',desc:'description',details:'description',
 category:'category',cat:'category',
 price_xcd:'price_xcd',price:'price_xcd',price_ec:'price_xcd',price_ecd:'price_xcd',price_xcd_:'price_xcd',unit_price:'price_xcd',
 stock_qty:'stock_qty',stock:'stock_qty',qty:'stock_qty',quantity:'stock_qty',in_stock:'stock_qty',
 low_stock_threshold:'low_stock_threshold',low_stock:'low_stock_threshold',low_stock_alert:'low_stock_threshold',reorder_level:'low_stock_threshold',
 cost_price:'cost_price',cost:'cost_price',
 active:'active',visible:'active',enabled:'active',status:'active',
 image_url:'image_url',image:'image_url',image_link:'image_url',photo:'image_url',photo_url:'image_url',picture:'image_url'};
const hkey=h=>String(h==null?'':h).replace(/^\uFEFF/,'').trim().toLowerCase().replace(/\(.*?\)/g,m=>'_'+m.slice(1,-1)).replace(/[^a-z0-9]+/g,'_').replace(/^_+|_+$/g,'');
const CATMAP=(()=>{const m={};for(const [k,v] of Object.entries(CATS)){m[k]=k;m[v.toLowerCase()]=k;m[v.toLowerCase().replace(/&/g,'and')]=k;m[v.toLowerCase().split(' & ')[0]]=k}
 Object.assign(m,{spices:'food',grocery:'food',produce:'food',art:'crafts',clothing:'fashion',textiles:'fashion',wellness:'beauty',boating:'sea',marine:'sea',garden:'home',household:'home'});return m})();
const unguard=s=>/^'[=+\-@]/.test(s)?s.slice(1):s;
function money(s){s=String(s).trim().replace(/^(ec\$|xcd|\$)\s*/i,'').replace(/\s+/g,'');if(/^\d{1,3}(,\d{3})+(\.\d+)?$/.test(s))s=s.replace(/,/g,'');else if(/^\d+,\d{1,2}$/.test(s))s=s.replace(',','.');return s}
function whole(s){s=String(s).trim().replace(/\s+/g,'');if(/^\d{1,3}(,\d{3})+$/.test(s))s=s.replace(/,/g,'');if(/^\d+\.0+$/.test(s))s=s.replace(/\.0+$/,'');return s}
function yn(s){const v=String(s).trim().toLowerCase();return ['true','yes','y','1','active','visible'].includes(v)?'yes':['false','no','n','0','hidden','inactive'].includes(v)?'no':v}
function cleanRow(r){const o={};for(const c of COLS)o[c]=r[c]==null?'':String(r[c]);
 for(const c of ['sku','name','category','image_url'])o[c]=unguard(o[c].trim());o.description=unguard(o.description.trim());
 o.category=CATMAP[o.category.toLowerCase().replace(/\s+/g,' ')]||o.category.toLowerCase();
 o.price_xcd=money(o.price_xcd);o.cost_price=money(o.cost_price);o.stock_qty=whole(o.stock_qty);o.low_stock_threshold=whole(o.low_stock_threshold);o.active=o.active.trim()===''?'':yn(o.active);return o}
function check(o,hasCost){ // returns {error,warns[]}
 const w=[];let e=null;const nm=o.name;
 if(!nm||nm.length<2||nm.length>120)e='Name must be 2 to 120 characters';
 else if(o.description.length>1000)e='Description is longer than 1000 characters';
 else if(!CATS[o.category])e='Category must be one of: food, crafts, fashion, beauty, sea, home';
 else if(o.price_xcd==='')e='Price is required';
 else if(!/^\d{1,7}(\.\d{1,2})?$/.test(o.price_xcd))e='Price must be a number like 12.50 (up to 2 decimals)';
 else if(+o.price_xcd>1000000)e='Price is over EC$1,000,000';
 else if(o.stock_qty!==''&&(!/^\d{1,7}$/.test(o.stock_qty)||+o.stock_qty>1000000))e='Stock must be a whole number from 0 to 1,000,000';
 else if(o.low_stock_threshold!==''&&(!/^\d{1,7}$/.test(o.low_stock_threshold)||+o.low_stock_threshold>1000000))e='Low-stock level must be a whole number from 0 to 1,000,000';
 else if(o.cost_price!==''&&(!/^\d{1,7}(\.\d{1,2})?$/.test(o.cost_price)||+o.cost_price>1000000))e='Cost price must be a number like 8.00 (up to 2 decimals)';
 else if(o.active!==''&&!['yes','no'].includes(o.active))e='Active must be yes or no';
 else if(o.sku&&(o.sku.length>64||/[\u0000-\u001f\u007f]/.test(o.sku)))e='SKU must be 1 to 64 characters';
 else if(o.image_url&&(!/^https:\/\/\S+$/i.test(o.image_url)||o.image_url.length>2000))e='Image link must start with https://';
 if(!e){if(/^example:/i.test(nm))w.push('Looks like a template example row');}
 return {error:e,warns:w}}
// parse file text/rows -> {rows:[{row,data,error,warns,status}], ignored:[], problems:[]}
function build(table,opts){
 opts=opts||{};const problems=[];
 let hi=table.findIndex(r=>r.some(c=>String(c).trim()!==''));
 if(hi<0)return {fatal:'The file is empty.'};
 const head=table[hi].map(hkey),map={},ignored=[];
 head.forEach((h,i)=>{if(!h)return;const k=ALIAS[h];if(k&&!(k in map))map[k]=i;else if(!k)ignored.push(String(table[hi][i]).trim());else problems.push('Column "'+String(table[hi][i]).trim()+'" repeats '+k+' and is ignored.')});
 const missing=['name','category','price_xcd'].filter(k=>!(k in map));
 if(missing.length)return {fatal:'Your file is missing the required column'+(missing.length>1?'s':'')+': '+missing.join(', ')+'. Download the template to see the expected columns.',ignored};
 const body=table.slice(hi+1);if(body.length>MAX_ROWS+50)return {fatal:'That file has more than '+MAX_ROWS.toLocaleString()+' rows. Split it into smaller files.'};
 const rows=[];const seen=new Map();
 body.forEach((cells,bi)=>{if(!cells||cells.every(c=>String(c==null?'':c).trim()===''))return;
  const raw={};for(const k of COLS)raw[k]=k in map?(cells[map[k]]==null?'':cells[map[k]]):'';
  const data=cleanRow(raw),line=hi+bi+2,ck=check(data,!!opts.hasCost);let err=ck.error;const warns=ck.warns.slice();
  if(!err){const key=data.sku?'s:'+data.sku.toLowerCase():'n:'+data.name.toLowerCase();if(seen.has(key))err='Duplicate of row '+seen.get(key)+' in this file';else seen.set(key,line)}
  rows.push({row:line,data,error:err,warns,status:err?'error':'ok',msg:err||''})});
 if(rows.length>MAX_ROWS)return {fatal:'That file has more than '+MAX_ROWS.toLocaleString()+' rows. Split it into smaller files.'};
 if(!rows.length)return {fatal:'The file has a header but no product rows.',ignored};
 if(!opts.hasCost&&'cost_price' in map&&rows.some(r=>r.data.cost_price!==''))problems.push('The cost_price column is read but not stored yet: it will be ignored for now.');
 return {rows,ignored,problems,present:Object.keys(map)}}
// ---------- UI ----------
const dl=(name,text,type,bom)=>{const b=new Blob([bom?'\uFEFF'+text:text],{type:type||'text/csv;charset=utf-8'});const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(a.href),4000)};
const fmt=n=>Number(n).toLocaleString();
const STLABEL={ok:'Ready',created:'Will add',updated:'Will update',skipped:'Skipped',error:'Problem',plan_limit:'Over plan limit',done_created:'Added',done_updated:'Updated',failed:'Failed'};
function mount(root,o){ // o: {sb, vendor, getUsage:()=>({used,limit,tierLabel}), upgradeHref, onDone, hasCost}
 const sb=o.sb,vendor=o.vendor;
 root.innerHTML=`<div class="bk">
  <p class="muted">Add or update hundreds or thousands of products in one go from a spreadsheet. Save it as <b>CSV (UTF-8)</b> or <b>.xlsx</b>. Photos are added afterwards in the product editor (an optional https <code>image_url</code> column is accepted for products that have no photo yet).</p>
  <div class="bk-row"><button type="button" class="btn alt" id="bk-tpl">Download template (CSV)</button> <button type="button" class="btn ghost" id="bk-exp">Export my products (CSV)</button> <span id="bk-expm" class="muted" role="status"></span></div>
  <details class="bk-help"><summary>Column guide</summary><ul>
   <li><b>name</b>, <b>category</b>, <b>price_xcd</b> are required.</li>
   <li><b>category</b>: ${Object.entries(CATS).map(([k,v])=>`<code>${esc(k)}</code> (${esc(v)})`).join(', ')}</li>
   <li><b>sku</b>: your own item code (optional, unique in your business). It is how "update" finds an existing product; without it the product name is used.</li>
   <li><b>stock_qty</b>: blank = not tracked. <b>low_stock_threshold</b>: blank = 5. <b>active</b>: yes/no, blank = yes. <b>cost_price</b> is optional and not stored yet.</li>
   <li>When updating, blank optional cells leave the current value alone.</li></ul></details>
  <div class="bk-drop"><label class="btn" for="bk-file" id="bk-pick" tabindex="0">Choose file…</label><input type="file" id="bk-file" class="sr" accept=".csv,.txt,.xlsx,text/csv" aria-label="Choose a CSV or Excel file"> <span id="bk-fname" class="muted">No file chosen</span></div>
  <div id="bk-msg" class="notice" role="status" hidden></div>
  <div id="bk-body"></div></div>`;
 const $=s=>root.querySelector(s);
 let st=null; // {name,rows,ignored,mode,checking,importing,results,choice,cancel}
 const say=(t,cls)=>{const m=$('#bk-msg');m.hidden=!t;m.className='notice'+(cls?' '+cls:'');m.textContent=t||''};
 $('#bk-tpl').onclick=()=>dl('products_template.csv',TEMPLATE,'text/csv;charset=utf-8',true);
 $('#bk-pick').onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();$('#bk-file').click()}};
 $('#bk-exp').onclick=async()=>{const b=$('#bk-exp'),m=$('#bk-expm');b.disabled=true;m.textContent='Preparing…';
  try{const all=[];for(let from=0;;from+=1000){const r=await sb.from('products').select('*').eq('vendor_id',vendor.id).order('created_at',{ascending:true}).order('id',{ascending:true}).range(from,from+999);
    if(r.error)throw r.error;all.push(...(r.data||[]));m.textContent='Read '+fmt(all.length)+' products…';if(!r.data||r.data.length<1000)break}
   const rows=[COLS].concat(all.map(p=>[p.sku||'',p.name,p.description||'',p.category,Number(p.price_xcd).toFixed(2),p.stock_qty==null?'':p.stock_qty,p.low_stock_threshold==null?'':p.low_stock_threshold,p.cost_price==null?'':p.cost_price,p.active?'yes':'no',p.image_url||'']));
   dl('my_products_'+new Date().toISOString().slice(0,10)+'.csv',toCSV(rows,true),'text/csv;charset=utf-8',true);m.textContent=all.length?'Exported '+fmt(all.length)+' products. Edit and re-upload with "Update existing".':'You have no products yet: the file contains just the headings.'}
  catch(e){m.textContent='Export failed: '+(e&&e.message||e)}finally{b.disabled=false}};
 $('#bk-file').onchange=async e=>{const f=e.target.files[0];e.target.value='';if(!f)return;await load(f)};
 async function load(f){
  say('');st=null;$('#bk-body').innerHTML='';$('#bk-fname').textContent=f.name;
  if(f.size>MAX_BYTES){say('That file is bigger than '+Math.round(MAX_BYTES/1048576)+' MB. Split it into smaller files.','err');return}
  const t0=performance.now();let table;
  try{if(/\.xlsx$/i.test(f.name)||f.type==='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')table=await parseXLSX(await f.arrayBuffer());
   else if(/\.xls$/i.test(f.name)){say('Old .xls files are not supported. In Excel choose Save As, then CSV UTF-8 (or .xlsx).','err');return}
   else{let ab=await f.arrayBuffer(),text;try{text=new TextDecoder('utf-8',{fatal:true}).decode(ab)}catch(_){text=new TextDecoder('windows-1252').decode(ab)}table=parseCSV(text)}}
  catch(err){say(err&&err.message||'Could not read that file.','err');return}
  const b=build(table,{hasCost:!!o.hasCost});
  if(b.fatal){say(b.fatal,'err');return}
  st={name:f.name,rows:b.rows,ignored:b.ignored,problems:b.problems,mode:'add',choice:'first',parseMs:Math.round(performance.now()-t0),shown:100,filter:'all',results:null};
  window.__bulkParseMs=st.parseMs;
  await check_();}
 const usage=()=>o.getUsage?o.getUsage():{used:0,limit:null,tierLabel:''};
 // dry run against the database to learn add/update/skip, then apply the plan cap locally in file order
 async function check_(){
  const my=st;my.checking=true;my.progress=0;draw();
  const ok=my.rows.filter(r=>!r.error);let last=null;
  for(const r of my.rows){r.status=r.error?'error':'ok';r.msg=r.error||'';r.code=''}
  try{for(let i=0;i<ok.length;i+=CHECK_BATCH){
    const chunk=ok.slice(i,i+CHECK_BATCH);
    const r=await sb.rpc('bulk_upsert_products',{p_vendor:vendor.id,p_rows:chunk.map(x=>({row:x.row,...x.data})),p_mode:my.mode,p_dry_run:true});
    if(my!==st)return;
    if(r.error)throw r.error;last=r.data;
    r.data.results.forEach((res,j)=>{const x=chunk[j];x.status=res.status;x.msg=res.message||'';x.code=res.code||''});
    my.progress=Math.min(ok.length,i+CHECK_BATCH);draw()}
   my.cap=last&&last.cap||null;
   // cap, in file order (each dry-run batch only knew the room at the start)
   const u=usage(),lim=u.limit==null?null:u.limit,room=lim==null?null:Math.max(0,lim-u.used);my.room=room;
   let creates=0;for(const r of my.rows)if(r.status==='created'||r.code==='plan_limit'){creates++;if(room!=null&&creates>room){r.status='plan_limit';r.code='plan_limit';r.msg='Not added: your '+(u.tierLabel||'current')+' plan allows '+lim+' products and you have '+u.used+'.'}else if(r.status==='plan_limit'){r.status='created';r.code='';r.msg=''}}
   my.overBy=room==null?0:Math.max(0,creates-room);
   my.checkError=null}
  catch(e){my.checkError=e&&e.message||String(e);
   if(/Could not find the function|schema cache/i.test(my.checkError))my.checkError='Bulk upload is not switched on in the database yet. Run supabase/photos.sql in Supabase (see README), then try again.'}
  my.checking=false;draw()}
 const counts=r=>{const c={total:r.length,ok:0,err:0,warn:0,add:0,upd:0,skip:0,cap:0};for(const x of r){if(x.status==='error')c.err++;else{c.ok++;if(x.warns.length)c.warn++}if(x.status==='created')c.add++;else if(x.status==='updated')c.upd++;else if(x.status==='skipped')c.skip++;else if(x.status==='plan_limit')c.cap++}return c};
 const pillFor=x=>{const s=x.status==='ok'?'ok':x.status;const t=STLABEL[x.final||s]||s;const cls=x.final==='failed'||s==='error'||s==='plan_limit'?'bad':s==='skipped'?'mut':s==='ok'?'ok':'good';return `<span class="bk-pill ${cls}">${esc(t)}</span>`};
 function draw(){
  const B=$('#bk-body');if(!st){B.innerHTML='';return}
  const c=counts(st.rows),u=usage(),lim=u.limit,room=st.room;
  if(st.checking){B.innerHTML=`<div class="bk-sum"><b>${fmt(c.total)}</b> rows read in ${st.parseMs} ms. Checking against your catalog… ${fmt(st.progress||0)} of ${fmt(c.ok)}</div><div class="bk-bar"><i style="width:${c.ok?Math.round((st.progress||0)/c.ok*100):100}%"></i></div>`;return}
  if(st.importing||st.results){drawImport(B,c);return}
  const filtered=st.rows.filter(r=>st.filter==='all'||(st.filter==='errors'&&(r.status==='error'||r.status==='plan_limit'))||(st.filter==='warn'&&r.warns.length)||(st.filter==='ready'&&(r.status==='created'||r.status==='updated'||r.status==='ok'))||(st.filter==='skipped'&&r.status==='skipped'));
  const show=filtered.slice(0,st.shown);
  const importN=c.add+c.upd-0;
  const willAdd=st.overBy&&st.choice==='first'?Math.min(c.add,room):c.add;
  const blocked=st.overBy>0&&st.choice==='none';
  const sendCount=(st.overBy&&st.choice==='none')?0:c.add+c.upd;
  B.innerHTML=`<div class="bk-sum"><b>${esc(st.name)}</b> · ${fmt(c.total)} rows read in ${st.parseMs} ms</div>
   ${st.checkError?`<div class="notice err">${esc(st.checkError)}</div>`:''}
   ${st.problems.concat(st.ignored.length?['Ignored columns: '+st.ignored.join(', ')]:[]).map(p=>`<div class="notice">${esc(p)}</div>`).join('')}
   <fieldset class="bk-mode"><legend>What should this upload do?</legend>
    ${[['add','Add new products only','Rows that already exist (same sku, or same name when there is no sku) are skipped.'],['update','Update existing products only','Matched by sku, otherwise by name. Rows that are not found are skipped.'],['upsert','Update existing and add new','Updates matches, adds the rest.']].map(([k,t,d])=>`<label class="chk opt"><input type="radio" name="bkmode" value="${k}"${st.mode===k?' checked':''}> <span><b>${t}</b><small>${d}</small></span></label>`).join('')}</fieldset>
   <div class="bk-chips"><span class="bk-chip"><b>${fmt(c.ok)}</b> valid</span><span class="bk-chip ${c.err?'bad':''}"><b>${fmt(c.err)}</b> with problems</span><span class="bk-chip ${c.warn?'warn':''}"><b>${fmt(c.warn)}</b> warnings</span><span class="bk-chip good"><b>${fmt(c.add)}</b> to add</span><span class="bk-chip good"><b>${fmt(c.upd)}</b> to update</span>${c.skip?`<span class="bk-chip"><b>${fmt(c.skip)}</b> skipped</span>`:''}${c.cap?`<span class="bk-chip bad"><b>${fmt(c.cap)}</b> over plan limit</span>`:''}</div>
   ${st.overBy>0?`<div class="notice err bk-cap" role="alert"><b>This upload would exceed your plan limit by ${fmt(st.overBy)}.</b> Your ${esc(u.tierLabel||'')} plan allows ${fmt(lim)} products and you have ${fmt(u.used)}, so there is room for ${fmt(room)} more.
     <label class="chk opt"><input type="radio" name="bkcap" value="first"${st.choice==='first'?' checked':''}> <span><b>Add only the first ${fmt(room)} new product${room===1?'':'s'}</b><small>${st.mode==='upsert'?'Updates are still applied. ':''}The remaining ${fmt(st.overBy)} are left out. They are listed in the error report.</small></span></label>
     <label class="chk opt"><input type="radio" name="bkcap" value="none"${st.choice==='none'?' checked':''}> <span><b>Import nothing</b><small>Upgrade your plan first${o.upgradeHref?` (<a href="${esc(o.upgradeHref)}">see plans</a>)`:''}, or trim the file.</small></span></label></div>`:''}
   <div class="bk-filter"><label>Show <select id="bk-f">${[['all','All rows'],['errors','Problems'],['warn','Warnings'],['ready','Ready'],['skipped','Skipped']].map(([k,t])=>`<option value="${k}"${st.filter===k?' selected':''}>${t}</option>`).join('')}</select></label> <span class="muted">${fmt(filtered.length)} row${filtered.length===1?'':'s'}</span></div>
   <div class="bk-tablew"><table class="bk-table"><thead><tr><th>Row</th><th>Status</th><th>Name</th><th>SKU</th><th>Category</th><th>Price</th><th>Stock</th><th>Note</th></tr></thead><tbody>${show.map(r=>`<tr class="${r.status==='error'||r.status==='plan_limit'?'bad':r.warns.length?'warn':''}"><td>${r.row}</td><td>${pillFor(r)}</td><td>${esc(r.data.name)}</td><td>${esc(r.data.sku)}</td><td>${esc(r.data.category)}</td><td>${esc(r.data.price_xcd)}</td><td>${esc(r.data.stock_qty)}</td><td>${esc([r.msg].concat(r.warns).filter(Boolean).join('. '))}</td></tr>`).join('')}</tbody></table></div>
   ${filtered.length>show.length?`<p><button type="button" class="btn ghost" id="bk-more">Show ${Math.min(200,filtered.length-show.length)} more (${fmt(filtered.length-show.length)} hidden)</button></p>`:''}
   <div class="bk-go"><button type="button" class="btn" id="bk-import" ${sendCount?'':'disabled'}>${sendCount?`Import ${fmt(sendCount)} row${sendCount===1?'':'s'}`:blocked?'Nothing will be imported':'Nothing to import'}</button> <button type="button" class="btn ghost" id="bk-clear">Cancel</button>${(c.err||c.skip||c.cap)?' <button type="button" class="btn ghost" id="bk-rep0">Download problem report</button>':''}</div>
   <p class="muted">${sendCount?`${fmt(willAdd)} added, ${fmt(c.upd)} updated.`:''} Rows with problems are never imported. Importing runs in batches of ${BATCH}; it is safe to run the same file again in "add new only" mode.</p>`;
  B.querySelectorAll('input[name=bkmode]').forEach(i=>i.onchange=()=>{st.mode=i.value;st.shown=100;check_()});
  B.querySelectorAll('input[name=bkcap]').forEach(i=>i.onchange=()=>{st.choice=i.value;draw()});
  const f=$('#bk-f');if(f)f.onchange=()=>{st.filter=f.value;st.shown=100;draw()};
  const mo=$('#bk-more');if(mo)mo.onclick=()=>{st.shown+=200;draw()};
  $('#bk-clear').onclick=()=>{st=null;$('#bk-fname').textContent='No file chosen';say('');draw()};
  const rp=$('#bk-rep0');if(rp)rp.onclick=()=>report();
  $('#bk-import').onclick=()=>doImport()}
 function report(){const rows=st.rows.filter(r=>r.status==='error'||r.status==='skipped'||r.status==='plan_limit'||r.final==='failed');
  const out=[['row','status','message'].concat(COLS)].concat(rows.map(r=>[r.row,r.final==='failed'?'failed':r.status==='plan_limit'?'not added (plan limit)':r.status,[r.msg].concat(r.warns).filter(Boolean).join('. ')].concat(COLS.map(k=>r.data[k]))));
  dl('bulk_upload_report.csv',toCSV(out,true),'text/csv;charset=utf-8',true)}
 async function doImport(){
  const my=st;let send=my.rows.filter(r=>r.status==='created'||r.status==='updated');
  if(my.overBy&&my.choice==='none')return;
  my.importing=true;my.cancel=false;my.done=0;my.total=send.length;my.res={created:0,updated:0,skipped:0,errors:0};
  for(const r of my.rows){r.final=''}
  draw();
  for(let i=0;i<send.length;i+=BATCH){
   if(my.cancel){my.stopped='Stopped by you after '+fmt(my.done)+' of '+fmt(my.total)+' rows. Rows already imported stay in your catalog.';break}
   const chunk=send.slice(i,i+BATCH);
   let r;try{r=await sb.rpc('bulk_upsert_products',{p_vendor:vendor.id,p_rows:chunk.map(x=>({row:x.row,...x.data})),p_mode:my.mode,p_dry_run:false})}catch(e){r={error:e}}
   if(r.error){my.stopped='Stopped at row '+chunk[0].row+': '+(r.error.message||r.error)+'. Rows before this batch were imported. Fix the problem and upload the file again in "add new only" mode: rows that are already in are skipped.';chunk.forEach(x=>x.final='failed');break}
   r.data.results.forEach((res,j)=>{const x=chunk[j];x.msg=res.message||'';if(res.status==='created'||res.status==='updated'){x.final='done_'+res.status;x.status=res.status==='created'?'created':'updated'}else if(res.status==='error'){x.final='failed';x.status='error';x.msg=res.message||'Could not import';if(res.code==='plan_limit')x.status='plan_limit'}else{x.final='';x.status='skipped'}});
   my.res.created+=r.data.created;my.res.updated+=r.data.updated;my.res.skipped+=r.data.skipped;my.res.errors+=r.data.errors;
   my.done+=chunk.length;drawImport($('#bk-body'),counts(my.rows))}
  my.importing=false;my.results=my.res;draw();
  if(o.onDone)try{o.onDone(my.res)}catch(e){}}
 function drawImport(B,c){
  const my=st,pct=my.total?Math.round(my.done/my.total*100):100;
  if(my.importing){B.innerHTML=`<div class="bk-sum"><b>Importing…</b> ${fmt(my.done)} of ${fmt(my.total)} rows</div><div class="bk-bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}"><i style="width:${pct}%"></i></div><p class="muted">Please keep this page open.</p><button type="button" class="btn ghost" id="bk-stop">Stop after this batch</button>`;const s=$('#bk-stop');if(s)s.onclick=()=>{my.cancel=true;s.disabled=true;s.textContent='Stopping…'};return}
  const r=my.results||my.res,bad=my.rows.filter(x=>x.status==='error'||x.status==='plan_limit'||x.final==='failed').length;
  B.innerHTML=`<div class="bk-done ${my.stopped||r.errors?'warn':'ok'}"><h4>${my.stopped?'Import stopped':'Import finished'}</h4>
   <div class="bk-chips"><span class="bk-chip good"><b>${fmt(r.created)}</b> added</span><span class="bk-chip good"><b>${fmt(r.updated)}</b> updated</span><span class="bk-chip"><b>${fmt(my.rows.filter(x=>x.status==='skipped').length)}</b> skipped</span><span class="bk-chip ${bad?'bad':''}"><b>${fmt(bad)}</b> not imported</span></div>
   ${my.stopped?`<div class="notice err">${esc(my.stopped)}</div>`:''}
   <p>${r.created?'Add photos to your new products from the product list (Edit).':''}</p>
   <div class="bk-go">${bad?'<button type="button" class="btn alt" id="bk-rep">Download error report (CSV)</button> ':''}<button type="button" class="btn" id="bk-new">Upload another file</button></div></div>`;
  const rp=$('#bk-rep');if(rp)rp.onclick=()=>report();$('#bk-new').onclick=()=>{st=null;$('#bk-fname').textContent='No file chosen';draw()}}
 return {load,parseCSV,build}}
window.CC=window.CC||{};window.CC.bulk={mount,parseCSV,parseXLSX,build,toCSV,TEMPLATE,COLS,cleanRow,check};
})();
