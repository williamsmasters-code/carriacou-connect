// Order PDF export (v0.7). Runs entirely in the browser with the vendored jsPDF (vendor/jspdf.umd.min.js, MIT).
// Only uses data the signed-in user can already read (orders, items, history, notes via RLS). Nothing is sent anywhere.
(function(){
const CC=window.CC;if(!CC)return;
const LIBSRC=(function(){const s=document.currentScript;return s&&s.src?s.src.replace(/[^/]*$/,'')+'vendor/jspdf.umd.min.js':'vendor/jspdf.umd.min.js'})();
let libP=null;
function lib(){
 if(window.jspdf&&window.jspdf.jsPDF)return Promise.resolve(window.jspdf.jsPDF);
 if(libP)return libP;
 libP=new Promise((res,rej)=>{const s=document.createElement('script');s.src=LIBSRC;s.onload=()=>window.jspdf&&window.jspdf.jsPDF?res(window.jspdf.jsPDF):rej(new Error('PDF library missing'));s.onerror=()=>{libP=null;rej(new Error('Could not load the PDF library'))};document.head.appendChild(s)});
 return libP;
}
// Standard PDF fonts only cover WinAnsi (Latin-1 plus a few symbols): map smart punctuation, replace anything else with '?', drop control chars.
const MAP={'\u2018':"'",'\u2019':"'",'\u201C':'"','\u201D':'"','\u2013':'-','\u2014':'-','\u2022':'-','\u2026':'...','\u00A0':' ','\u20AC':'EUR ','\u2192':'->','\u2190':'<-','\u2713':'v'};
function clean(s){
 s=String(s==null?'':s).replace(/\r\n?/g,'\n').replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g,'');
 let o='';for(const ch of s){const c=ch.codePointAt(0);if(ch==='\n'||ch==='\t')o+=ch==='\t'?' ':ch;else if(MAP[ch])o+=MAP[ch];else if(c>=32&&c<=126||c>=161&&c<=255)o+=ch;else if(c>255&&/\p{M}/u.test(ch)){}else o+='?'}
 return o;
}
const money=n=>CC.cents(Math.round((Number(n)||0)*100));
function dt(d){try{const x=new Date(d);if(isNaN(x))return String(d||'');const p=n=>String(n).padStart(2,'0');return x.getFullYear()+'-'+p(x.getMonth()+1)+'-'+p(x.getDate())+' '+p(x.getHours())+':'+p(x.getMinutes())}catch(e){return ''}}
function fname(base){return String(base||'order').replace(/[^A-Za-z0-9._-]+/g,'_').slice(0,60)+'.pdf'}
const payStatusLabel=o=>({paid:'Paid',refunded:'Refunded',unpaid:'Unpaid'})[o.payment_status]||(o.payment_status?String(o.payment_status):'Not recorded');
const isWallet=o=>o.payment_method==='pay_with_wallet';

// small layout helper around a jsPDF document
function Doc(JsPDF,title){
 const d=new JsPDF({unit:'pt',format:'a4',compress:true});
 d.setProperties({title:clean(title),creator:'Carriacou Connect',subject:'Order export'});
 const W=d.internal.pageSize.getWidth(),H=d.internal.pageSize.getHeight(),M=42,CW=W-2*M,BOT=H-56;
 const S={y:M};
 const NAVY=[11,60,74],GOLD=[244,185,66],GREY=[100,110,115],INK=[20,30,35];
 const api={d,W,H,M,CW,S,NAVY,GREY,INK,
  newPage(){d.addPage();S.y=M+14;running()},
  need(h){if(S.y+h>BOT)api.newPage()},
  font(sz,style,col){d.setFont('helvetica',style||'normal');d.setFontSize(sz);d.setTextColor(...(col||INK))},
  lines(t,w,sz){d.setFontSize(sz||10);return d.splitTextToSize(clean(t)||'',w)},
  // wrapped paragraph that can break across pages
  para(t,x,w,sz,style,col,lh){api.font(sz,style,col);lh=lh||sz*1.35;const ls=api.lines(t,w,sz);for(const l of ls){api.need(lh);d.text(l,x,S.y+sz);S.y+=lh}},
  h2(t){api.need(34);S.y+=10;api.font(12,'bold',NAVY);d.text(clean(t),M,S.y+12);S.y+=17;d.setDrawColor(...GOLD);d.setLineWidth(1.5);d.line(M,S.y,M+CW,S.y);S.y+=8},
  kv(k,v,x,w){api.font(8,'bold',GREY);d.text(clean(k).toUpperCase(),x,S.y+8);api.font(10,'normal',INK);const ls=api.lines(v||'-',w,10);let yy=S.y+22;ls.forEach(l=>{d.text(l,x,yy);yy+=13});return yy-S.y}
 };
 function running(){api.font(8,'normal',GREY);d.text('Carriacou Connect - '+clean(title),M,M-8)}
 return api;
}
function header(P,sub,ref){
 const {d,W,M,NAVY}=P;
 d.setFillColor(...NAVY);d.rect(0,0,W,78,'F');d.setFillColor(...[244,185,66]);d.rect(0,78,W,4,'F');
 d.setFillColor(244,185,66);d.circle(M+16,39,16,'F');d.setFillColor(255,255,255);d.triangle(M+16,25,M+27,48,M+16,48,'F');d.triangle(M+14,29,M+5,48,M+14,48,'F');
 P.font(20,'bold',[255,255,255]);d.text('Carriacou Connect',M+42,36);
 P.font(9,'normal',[200,230,235]);d.text('Marketplace  |  '+clean(sub),M+42,53);
 if(ref){P.font(16,'bold',[255,255,255]);d.text(clean(ref),W-M,40,{align:'right'})}
 P.S.y=100;
}
function footers(P,sample){
 const {d,W,H,M,GREY}=P,n=d.getNumberOfPages();
 const stamp='Generated '+dt(new Date())+' (local time) by Carriacou Connect';
 for(let i=1;i<=n;i++){d.setPage(i);d.setDrawColor(200,205,208);d.setLineWidth(.5);d.line(M,H-46,W-M,H-46);
  P.font(8,'normal',GREY);d.text(stamp,M,H-34);d.text('Page '+i+' of '+n,W-M,H-34,{align:'right'});
  if(sample){P.font(7.5,'bold',[180,90,0]);d.text('Sample/Test data: SAMPLE or TEST MODE (play money) involved. Not a real invoice or receipt.',M,H-22)}}
}

function table(P,cols,rows,opts){
 // cols: [{t,w(fraction),align}]; rows: arrays of strings. Header repeats after a page break.
 const {d,M,CW}=P;opts=opts||{};const fs=opts.size||9;const pad=4;
 const xs=[];let x=M;cols.forEach(c=>{xs.push(x);x+=c.w*CW});
 const head=()=>{P.need(22);d.setFillColor(233,242,244);d.rect(M,P.S.y,CW,18,'F');P.font(8,'bold',P.NAVY);
  cols.forEach((c,i)=>{const tx=c.align==='right'?xs[i]+c.w*CW-pad:xs[i]+pad;d.text(clean(c.t).toUpperCase(),tx,P.S.y+12,{align:c.align==='right'?'right':'left'})});P.S.y+=18};
 head();
 rows.forEach((r,ri)=>{
  P.font(fs,r.bold?'bold':'normal',P.INK);
  const cells=r.map((v,i)=>d.splitTextToSize(clean(v)||'',cols[i].w*CW-2*pad));
  const lh=fs*1.3,h=Math.max(...cells.map(c=>c.length))*lh+6;
  if(P.S.y+h>P.H-56){P.newPage();head();P.font(fs,'normal',P.INK)}
  if(ri%2)d.setFillColor(248,250,251),d.rect(M,P.S.y,CW,h,'F');
  P.font(fs,r.bold?'bold':'normal',P.INK);
  cells.forEach((c,i)=>{const tx=cols[i].align==='right'?xs[i]+cols[i].w*CW-pad:xs[i]+pad;c.forEach((l,li)=>d.text(l,tx,P.S.y+3+fs+li*lh,{align:cols[i].align==='right'?'right':'left'}))});
  P.S.y+=h});
 d.setDrawColor(210,215,218);d.setLineWidth(.5);d.line(M,P.S.y,M+CW,P.S.y);P.S.y+=4;
}

// ---- single order ----
// o: order row (+order_items, optional order_status_history), ex: {role:'consumer'|'vendor', vendorName, vendorLocation, notes:[], history:[], sample, notesError}
async function buildOrder(o,ex){
 const JsPDF=await lib();const role=ex.role==='vendor'?'vendor':'consumer';
 const on=clean(o.order_number||'Order');
 const P=Doc(JsPDF,'Order '+on);const {d,M,CW}=P;
 header(P,role==='vendor'?'Order details (vendor copy)':'Order details (customer copy)','Order '+on);
 const test=isWallet(o);
 // summary blocks
 const colW=CW/2-8;const y0=P.S.y;
 let h1=P.kv('Order number',on,M,colW);
 let h2=P.kv('Date placed',dt(o.created_at),M+CW/2+8,colW);P.S.y=y0+Math.max(h1,h2)+8;
 const y1=P.S.y;
 h1=P.kv('Status',CC.SLABEL[o.status]||o.status,M,colW);
 h2=P.kv('Vendor',ex.vendorName||'Vendor',M+CW/2+8,colW);P.S.y=y1+Math.max(h1,h2)+8;
 const y2=P.S.y;
 const ful=o.fulfilment==='delivery'?'Delivery':'Pickup';
 h1=P.kv(role==='vendor'?'Customer':'Contact',[o.contact_name||'(no name)',o.contact_phone||''].filter(Boolean).join('\n'),M,colW);
 h2=P.kv('Fulfilment',ful,M+CW/2+8,colW);P.S.y=y2+Math.max(h1,h2)+8;
 const y3=P.S.y;
 const addr=o.fulfilment==='delivery'?(o.delivery_address||'-'):('Collect from '+(ex.vendorName||'the vendor')+(ex.vendorLocation?', '+ex.vendorLocation:''));
 h1=P.kv(o.fulfilment==='delivery'?'Delivery address':'Pickup',addr,M,colW);
 h2=P.kv('Payment',CC.payText(o).replace(/ \(TEST, play money\)/,'')+(test?' - TEST MODE (play money)':'')+'\nStatus: '+payStatusLabel(o)+(test&&o.payment_status==='paid'?' (TEST MODE)':'')+(o.paid_at?'\nPaid '+dt(o.paid_at):''),M+CW/2+8,colW);P.S.y=y3+Math.max(h1,h2)+6;
 if(o.notes){P.h2('Order instructions');P.para(o.notes,M,CW,10)}
 // items
 P.h2('Items');
 const items=o.order_items||[];
 const rows=items.map(i=>[i.product_name,String(i.quantity),money(i.unit_price_xcd),money(i.line_total_xcd!=null?i.line_total_xcd:Number(i.unit_price_xcd)*Number(i.quantity))]);
 if(!rows.length)rows.push(['(no items)','','','']);
 table(P,[{t:'Item',w:.5},{t:'Qty',w:.1,align:'right'},{t:'Unit price',w:.2,align:'right'},{t:'Line total',w:.2,align:'right'}],rows);
 // totals
 P.need(70);P.S.y+=4;const tx=M+CW,lx=M+CW-190;
 const tl=(a,b,bold)=>{P.font(bold?12:10,bold?'bold':'normal',bold?P.NAVY:P.INK);P.d.text(a,lx,P.S.y+11);P.d.text(b,tx,P.S.y+11,{align:'right'});P.S.y+=bold?20:15};
 tl('Subtotal',money(o.subtotal_xcd));tl('Delivery fee',money(o.delivery_fee_xcd||0));
 d.setDrawColor(...P.NAVY);d.setLineWidth(1);d.line(lx,P.S.y+1,tx,P.S.y+1);P.S.y+=5;tl('Total (XCD)',money(o.total_xcd),true);
 if(test){P.font(8,'bold',[180,90,0]);d.text('TEST MODE - paid with play money, no real funds',tx,P.S.y+8,{align:'right'});P.S.y+=14}
 // timeline
 P.h2('Status history');
 const hist=(ex.history&&ex.history.length?ex.history:o.order_status_history||[]).slice().sort((a,b)=>new Date(a.changed_at)-new Date(b.changed_at));
 const trows=hist.length?hist.map(h=>[dt(h.changed_at),CC.SLABEL[h.to_status]||h.to_status]):[[dt(o.created_at),'Placed']];
 table(P,[{t:'When',w:.3},{t:'Status',w:.7}],trows);
 // notes
 P.h2('Order notes (customer and vendor)');
 if(ex.notesError)P.para('Notes could not be loaded when this PDF was made.',M,CW,9,'italic',P.GREY);
 else if(!(ex.notes||[]).length)P.para('No notes on this order.',M,CW,9,'italic',P.GREY);
 else (ex.notes||[]).forEach(n=>{
  const who=(n.author_name||(n.author_role==='vendor'?'Vendor':'Customer'))+' ('+(n.author_role==='vendor'?'vendor':'customer')+')';
  P.need(30);P.font(8,'bold',P.NAVY);d.text(clean(who)+'  -  '+dt(n.created_at),M,P.S.y+8);P.S.y+=12;P.para(n.body,M+8,CW-8,10);P.S.y+=4});
 footers(P,ex.sample||test);
 return {doc:d,filename:fname(on)};
}

// ---- vendor summary of the orders currently shown ----
async function buildSummary(list,ex){
 const JsPDF=await lib();
 const P=Doc(JsPDF,'Order summary');const {d,M,CW}=P;
 header(P,'Vendor order summary',null);
 P.font(14,'bold',P.NAVY);d.text(clean(ex.vendorName||'Vendor'),M,P.S.y+8);P.S.y+=20;
 P.font(9,'normal',P.GREY);d.text(clean(list.length+' order'+(list.length===1?'':'s')+(ex.filterLabel?' - filter: '+ex.filterLabel:'')),M,P.S.y+8);P.S.y+=20;
 const rows=list.map(o=>[o.order_number,dt(o.created_at),CC.SLABEL[o.status]||o.status,(o.contact_name||'-'),(o.fulfilment==='delivery'?'Delivery':'Pickup'),(isWallet(o)?'Wallet (TEST) ':'')+payStatusLabel(o),money(o.total_xcd)]);
 if(!rows.length)rows.push(['(no orders)','','','','','','']);
 table(P,[{t:'Order',w:.13},{t:'Date',w:.17},{t:'Status',w:.12},{t:'Customer',w:.19},{t:'Fulfil.',w:.1},{t:'Payment',w:.14},{t:'Total',w:.15,align:'right'}],rows,{size:8});
 const live=list.filter(o=>o.status!=='cancelled');const sum=live.reduce((a,o)=>a+Math.round((Number(o.total_xcd)||0)*100),0);
 P.need(40);P.S.y+=6;P.font(11,'bold',P.NAVY);d.text('Total of non-cancelled orders (XCD)',M,P.S.y+11);d.text(CC.cents(sum),M+CW,P.S.y+11,{align:'right'});P.S.y+=18;
 P.font(8,'normal',P.GREY);d.text(clean(live.length+' of '+list.length+' orders counted; cancelled orders excluded.'),M,P.S.y+8);
 const test=list.some(isWallet);
 footers(P,ex.sample||test);
 return {doc:d,filename:fname('CC-orders-'+new Date().toISOString().slice(0,10))};
}

// ---- tax summary (v1.1): summary for the vendor's own records, NOT official tax advice ----
async function buildTax(R,ex){
 const JsPDF=await lib();
 const P=Doc(JsPDF,'Tax summary');const {d,M,CW}=P;
 header(P,'Tax and license summary',null);
 P.font(14,'bold',P.NAVY);d.text(clean(ex.vendorName||'Business'),M,P.S.y+8);P.S.y+=20;
 P.font(9,'normal',P.GREY);d.text(clean('Period '+ex.from+' to '+ex.to+' (Grenada local days)'),M,P.S.y+8);P.S.y+=16;
 P.para('Summary for your records, not official tax advice. Check amounts and rules with the Inland Revenue Division or your accountant.',M,CW,8.5,'bold',[180,90,0]);P.S.y+=4;
 const st=R.settings||{};
 P.h2('Settings used');
 table(P,[{t:'Item',w:.4},{t:'Value',w:.6}],[
  ['Tax rate',st.tax_rate_pct==null?'Not set':Number(st.tax_rate_pct)+'%'],
  ['Prices',st.tax_rate_pct==null?'-':(st.tax_inclusive?'Include tax (tax = sales x rate / (100 + rate))':'Exclude tax (tax = sales x rate / 100; the platform does not add tax at checkout)')],
  ['License number',st.license_number||'Not set'],['License expiry',st.license_expiry?(st.license_expiry+(st.license_days_left!=null?(st.license_days_left<0?' (EXPIRED)':' ('+st.license_days_left+' days left)'):'')):'Not set']]);
 P.h2('Totals');
 table(P,[{t:'Item',w:.6},{t:'Amount (XCD)',w:.4,align:'right'}],[
  ['Orders counted (not cancelled, not refunded)',String(R.orders)],['Sales',money(R.sales_xcd)],['Sales with a tax rate',money(R.taxed_sales_xcd)],
  ['Tax (estimated from your rate)',money(R.tax_xcd)],['  of which prices include tax',money(R.tax_inclusive_xcd)],['  of which prices exclude tax',money(R.tax_exclusive_xcd)],
  ['Orders with no tax rate (not taxed here)',String(R.orders_without_rate)]]);
 if((R.by_month||[]).length){P.h2('By month');table(P,[{t:'Month',w:.3},{t:'Orders',w:.2,align:'right'},{t:'Sales',w:.25,align:'right'},{t:'Tax',w:.25,align:'right'}],R.by_month.map(m=>[String(m.month).slice(0,7),String(m.orders),money(m.sales_xcd),money(m.tax_xcd)]))}
 const rows=(R.rows||[]).slice(0,400);
 if(rows.length){P.h2('Orders'+(R.rows.length>rows.length?' (first '+rows.length+' of '+R.rows.length+'; use the CSV for all)':''));
  table(P,[{t:'Date',w:.17},{t:'Order',w:.2},{t:'Total',w:.2,align:'right'},{t:'Rate',w:.18,align:'right'},{t:'Tax',w:.25,align:'right'}],rows.map(r=>[r.day,r.ref,money(r.total_xcd),r.rate_pct==null?'-':Number(r.rate_pct)+'%'+(r.inclusive?' incl.':' excl.'),r.tax_xcd==null?'-':money(r.tax_xcd)]),{size:8})}
 footers(P,!!ex.test);
 return {doc:d,filename:fname('CC-tax-summary-'+ex.from+'_to_'+ex.to)};
}


// ---- generic report PDF (v1.3 Advanced/Premium analytics): spec = {title, sub, vendorName, period, warn, kvs:[[k,v]], sections:[{h, para, table:{cols,rows,size}}], foot} ----
async function buildReport(spec,ex){
 const JsPDF=await lib();
 const P=Doc(JsPDF,spec.title);const {d,M,CW}=P;
 header(P,spec.sub||spec.title,null);
 P.font(14,'bold',P.NAVY);d.text(clean(ex.vendorName||'Business'),M,P.S.y+8);P.S.y+=20;
 if(spec.period){P.font(9,'normal',P.GREY);d.text(clean(spec.period),M,P.S.y+8);P.S.y+=16}
 if(spec.warn){P.para(spec.warn,M,CW,8.5,'bold',[180,90,0]);P.S.y+=4}
 if((spec.kvs||[]).length){table(P,[{t:'Item',w:.55},{t:'Value',w:.45,align:'right'}],spec.kvs.map(r=>[String(r[0]),String(r[1])]))}
 (spec.sections||[]).forEach(sc=>{
  P.h2(sc.h);
  if(sc.para)P.para(sc.para,M,CW,9,'normal',P.GREY);
  if(sc.table){const rows=(sc.table.rows||[]).slice(0,600);table(P,sc.table.cols,rows.length?rows:[sc.table.cols.map((_,i)=>i===0?'(nothing to show)':'')],{size:sc.table.size||9});
   if((sc.table.rows||[]).length>rows.length)P.para('Showing the first '+rows.length+' rows; use the CSV for all.',M,CW,8,'italic',P.GREY)}});
 if(spec.foot){P.S.y+=6;P.para(spec.foot,M,CW,8,'italic',P.GREY)}
 footers(P,!!ex.test);
 return {doc:d,filename:fname(spec.file||'CC-report')};
}

// fetch the extra rows the current user is already allowed to read
async function extras(sb,o){
 const ex={};
 try{const r=await sb.from('order_notes').select('*').eq('order_id',o.id).order('created_at',{ascending:true});if(r.error)ex.notesError=true;else ex.notes=r.data||[]}catch(e){ex.notesError=true}
 if(!o.order_status_history){try{const r=await sb.from('order_status_history').select('*').eq('order_id',o.id);if(!r.error)ex.history=r.data||[]}catch(e){}}
 return ex;
}
async function run(builder,btn,msgEl){
 const label=btn?btn.textContent:'';
 if(btn){btn.disabled=true;btn.textContent='Preparing PDF…'}
 try{const r=await builder();r.doc.save(r.filename);if(msgEl){msgEl.className='notice ok';msgEl.textContent='Saved '+r.filename;msgEl.hidden=false}}
 catch(e){console.warn('PDF failed',e);if(msgEl){msgEl.className='notice err';msgEl.textContent='Could not make the PDF: '+(e&&e.message||e);msgEl.hidden=false}}
 finally{if(btn){btn.disabled=false;btn.textContent=label}}
}
CC.orderPdf={
 order:async(sb,o,base,btn,msgEl)=>run(async()=>buildOrder(o,Object.assign({},base,await extras(sb,o))),btn,msgEl),
 summary:async(list,base,btn,msgEl)=>run(()=>buildSummary(list,base),btn,msgEl),
 tax:async(rep,base,btn,msgEl)=>run(()=>buildTax(rep,base),btn,msgEl),
 report:async(spec,base,btn,msgEl)=>run(()=>buildReport(spec,base||{}),btn,msgEl),
 clean
};
})();
