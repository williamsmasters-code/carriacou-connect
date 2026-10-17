// Vendor analytics, BASIC tier (v0.8, every plan). Needs supabase/analytics.sql. No chart libraries: inline SVG + CSS.
// All numbers come from SECURITY INVOKER database functions that only return the signed-in vendor's own data.
// Day boundaries are Grenada local days (America/Grenada, UTC-4, no daylight saving).
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,TZ='America/Grenada';
const money=n=>'EC$'+(Number(n)||0).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});
const fmtD=new Intl.DateTimeFormat('en-CA',{timeZone:TZ,year:'numeric',month:'2-digit',day:'2-digit'});
const fmtT=new Intl.DateTimeFormat('en-GB',{timeZone:TZ,year:'numeric',month:'short',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});
const todayGD=()=>fmtD.format(new Date());                                   // 'YYYY-MM-DD' in Grenada
const toD=s=>{const [y,m,d]=s.split('-').map(Number);return new Date(Date.UTC(y,m-1,d))};
const iso=d=>d.toISOString().slice(0,10);
const addDays=(s,n)=>{const d=toD(s);d.setUTCDate(d.getUTCDate()+n);return iso(d)};
const validDate=s=>/^\d{4}-\d{2}-\d{2}$/.test(s||'')&&iso(toD(s))===s;
function ranges(today){ // week starts Monday
 const dow=(toD(today).getUTCDay()+6)%7;
 return {today:[today,today],week:[addDays(today,-dow),today],month:[today.slice(0,8)+'01',today],last30:[addDays(today,-29),today]};
}
const PRESETS=[['today','Today'],['week','This week'],['month','This month'],['last30','Last 30 days'],['custom','Custom range']];
const METHOD={pay_on_pickup:'Pay on pickup',pay_on_delivery:'Pay on delivery',pay_with_wallet:'Wallet (test)'};
const WTYPE={order_payment:'Order payment',refund:'Refund',transfer:'Transfer',topup_test:'Test top-up',adjustment:'Adjustment'};
const SLAB=()=>CC.SLABEL||{};

// ---- CSV (RFC 4180 quoting + spreadsheet formula-injection guard) ----
function csvCell(v,numeric){
 let s=v==null?'':String(v);
 if(numeric)return /^-?\d+(\.\d+)?$/.test(s)?s:'"'+s.replace(/"/g,'""')+'"';
 s=s.replace(/\r\n|\r|\n/g,' ');                                            // keep one record per line
 if(/^[=+\-@\t\r\u0009\u000d\uff1d\uff0b\uff0d\uff20]/.test(s.replace(/^[ \u00a0]+/,'')))s="'"+s;      // =, +, -, @, tab, CR (and full-width forms) after optional spaces
 return '"'+s.replace(/"/g,'""')+'"';
}
function toCsv(rows){
 const head=['Date (Grenada time)','Day','Type','Reference','Method / kind','Status','Amount (EC$)','Note'];
 const lines=[head.map(h=>csvCell(h)).join(',')];
 rows.forEach(r=>{
  const type=r.kind==='order'?'Order':'Wallet (test)';
  const how=r.kind==='order'?(METHOD[r.method]||r.method):(WTYPE[r.method]||r.method);
  const st=r.kind==='order'?(SLAB()[r.status]||r.status)+(r.payment_status&&r.payment_status!=='unpaid'?' / '+r.payment_status:''):(r.status==='in'?'money in':'money out');
  lines.push([csvCell(fmtT.format(new Date(r.at))),csvCell(r.day),csvCell(type),csvCell(r.ref),csvCell(how),csvCell(st),csvCell(Number(r.amount_xcd).toFixed(2),true),csvCell(r.note)].join(','));
 });
 return '\ufeff'+lines.join('\r\n')+'\r\n';
}
function download(name,text){
 const b=new Blob([text],{type:'text/csv;charset=utf-8'}),u=URL.createObjectURL(b),a=document.createElement('a');
 a.href=u;a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(u),1500);
}

// ---- chart: daily revenue bars (inline SVG). Over 92 days the bars become weeks. ----
function chart(daily){
 let pts=daily.map(d=>({label:d.day,rev:Number(d.revenue_xcd)||0,n:Number(d.orders)||0}));
 let unit='day';
 if(pts.length>92){unit='week';const w=[];for(let i=0;i<pts.length;i+=7){const g=pts.slice(i,i+7);w.push({label:g[0].label,rev:g.reduce((s,x)=>s+x.rev,0),n:g.reduce((s,x)=>s+x.n,0)})}pts=w}
 const max=Math.max(...pts.map(p=>p.rev),0);
 if(!max)return '<div class="empty small"><div class="empty-ic" aria-hidden="true">📊</div><p>No sales in this period yet.</p></div>';
 const W=640,H=200,L=44,B=26,T=10,iw=W-L-6,ih=H-B-T,bw=iw/pts.length,gap=Math.min(4,bw*.25);
 const nice=(()=>{const p=Math.pow(10,Math.floor(Math.log10(max)));const f=max/p;return (f<=1?1:f<=2?2:f<=5?5:10)*p})();
 let s=`<svg class="an-chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Revenue per ${unit}, highest ${esc(money(max))}" preserveAspectRatio="xMidYMid meet">`;
 [0,.5,1].forEach(f=>{const y=T+ih-ih*f;s+=`<line x1="${L}" x2="${W-6}" y1="${y}" y2="${y}" class="gl"/><text x="${L-6}" y="${y+4}" text-anchor="end" class="ax">${esc(Math.round(nice*f).toLocaleString('en-US'))}</text>`});
 pts.forEach((p,i)=>{const h=Math.max(p.rev>0?2:0,ih*p.rev/nice),x=L+i*bw+gap/2;
  s+=`<rect x="${x.toFixed(2)}" y="${(T+ih-h).toFixed(2)}" width="${Math.max(1,bw-gap).toFixed(2)}" height="${h.toFixed(2)}" rx="${Math.min(4,bw/3).toFixed(1)}" class="bar"><title>${esc(p.label)}${unit==='week'?' (week)':''}: ${esc(money(p.rev))}, ${p.n} order${p.n===1?'':'s'}</title></rect>`});
 const ticks=pts.length<=7?pts.map((_,i)=>i):[0,Math.floor((pts.length-1)/2),pts.length-1];
 ticks.forEach(i=>{const x=L+i*bw+bw/2;s+=`<text x="${x.toFixed(1)}" y="${H-8}" text-anchor="${i===0&&pts.length>7?'start':i===pts.length-1&&pts.length>7?'end':'middle'}" class="ax">${esc(pts[i].label.slice(5))}</text>`});
 return s+'</svg>';
}

const state={preset:'month',from:null,to:null};
let seq=0;

async function mount(el,o){
 const {sb,onEdit}=o;const my=++seq;
 const today=todayGD(),R=ranges(today);
 if(state.preset!=='custom'){[state.from,state.to]=R[state.preset]||R.month}
 else if(!state.from||!state.to){[state.from,state.to]=R.month}
 el.innerHTML='<h3>Sales analytics</h3><p class="muted">Basic analytics, included in every plan. Days are Grenada local days (America/Grenada). Cancelled orders are not counted as sales; refunded orders are shown separately.</p><div id="anbox"><p class="muted">Loading…</p></div>';
 const box=el.querySelector('#anbox');
 const head=()=>`<div class="ofilter an-presets" role="group" aria-label="Date range">${PRESETS.map(([k,l])=>`<button type="button" data-p="${k}" class="${state.preset===k?'on':''}">${esc(l)}</button>`).join('')}</div>
  <form class="an-custom" id="ancust" ${state.preset==='custom'?'':'hidden'}><label>From<input type="date" id="anfrom" value="${esc(state.from)}" max="${today}"></label><label>To<input type="date" id="anto" value="${esc(state.to)}" max="${today}"></label><button class="btn alt" type="submit">Apply</button></form>
  <p class="muted an-range">Showing <b>${esc(state.from)}</b> to <b>${esc(state.to)}</b></p><div id="anmsg" class="notice err" hidden role="alert"></div>`;
 async function load(){
  box.innerHTML=head()+'<p class="muted">Loading…</p>';wire();
  const a={p_from:state.from,p_to:state.to};
  const [sum,top,pay,low,wal,tx]=await Promise.all([sb.rpc('vendor_sales_summary',a),sb.rpc('vendor_top_products',{...a,p_limit:5}),sb.rpc('vendor_payment_breakdown',a),sb.rpc('vendor_low_stock'),sb.rpc('vendor_wallet_overview'),sb.rpc('vendor_transactions',{...a,p_limit:1000})]);
  if(my!==seq)return;
  const bad=[sum,top,pay,low,wal,tx].find(r=>r.error);
  if(bad){const m=bad.error.message||'';
   const missing=/Could not find the function|schema cache|does not exist|PGRST202|404/.test(m);
   box.innerHTML=head()+(missing?'<div class="notice">Analytics is not switched on yet. In Supabase, open the SQL Editor and run <code>supabase/analytics.sql</code> (see README.txt), then refresh this page.</div>':'<div class="notice err">Could not load analytics: '+esc(m)+'</div>');wire();return}
  const S=sum.data,T=top.data,P=pay.data,L=low.data||[],W=wal.data,X=tx.data;
  const kpi=(l,v,sub,cls)=>`<div class="kpi ${cls||''}"><span>${esc(l)}</span><b>${v}</b>${sub?`<small>${sub}</small>`:''}</div>`;
  const bestIds=new Set((T.best||[]).map(x=>x.product_id));
  const worst=(T.worst||[]).filter(x=>!bestIds.has(x.product_id));
  const prow=x=>`<tr><td>${esc(x.name)}</td><td>${x.qty}</td><td>${money(x.revenue_xcd)}</td></tr>`;
  const tot=(P.methods||[]).reduce((s,m)=>s+Number(m.revenue_xcd),0);
  const methods=(P.methods||[]).map(m=>{const pct=tot?Math.round(Number(m.revenue_xcd)/tot*100):0;return `<tr><td>${esc(METHOD[m.method]||m.method)}</td><td>${m.orders}</td><td>${money(m.revenue_xcd)}</td><td class="an-share"><span class="meter"><span style="width:${pct}%"></span></span> ${pct}%</td></tr>`}).join('');
  const rows=(X&&X.rows)||[];
  const wl=W&&W.has_wallet?`<div class="an-wallet"><b>${CC.cents(W.balance_cents)}</b><small>Business wallet balance · code ${esc(W.wallet_code)}</small></div>`:'<p class="muted">No business wallet yet. It is created the first time you open <a href="wallet.html">Business wallet</a> or receive a wallet payment.</p>';
  box.innerHTML=head()+`
  <div class="kpis">${kpi('Orders',S.orders,S.open_orders?S.open_orders+' still open':'all finished')}${kpi('Revenue',money(S.revenue_xcd),'excludes cancelled and refunded')}${kpi('Average order',money(S.avg_order_xcd),S.items_sold+' item'+(S.items_sold==1?'':'s')+' sold')}${kpi('Refunded',money(S.refunded_xcd),S.refunded_orders+' order'+(S.refunded_orders==1?'':'s'),'warn')}${kpi('Cancelled',money(S.cancelled_xcd),S.cancelled_orders+' order'+(S.cancelled_orders==1?'':'s'),'mute')}</div>
  <div class="an-card"><h4>Revenue per day</h4>${chart(S.daily||[])}</div>
  <div class="an-grid">
   <div class="an-card"><h4>Best sellers</h4>${(T.best||[]).length?`<table><tr><th>Product</th><th>Sold</th><th>Revenue</th></tr>${T.best.map(prow).join('')}</table>`:'<div class="empty small"><p>No sales in this period.</p></div>'}</div>
   <div class="an-card"><h4>Slowest sellers</h4>${worst.length?`<table><tr><th>Product</th><th>Sold</th><th>Revenue</th></tr>${worst.map(prow).join('')}</table>`:`<div class="empty small"><p>${(T.best||[]).length?'Every active product is already listed in the best sellers.':'You have no active products yet.'}</p></div>`}</div>
  </div>
  <div class="an-grid">
   <div class="an-card"><h4>Payment methods</h4><table><tr><th>Method</th><th>Orders</th><th>Revenue</th><th>Share</th></tr>${methods}</table>
    <p class="an-refunds"><b>Refunds</b> ${P.refunds.orders} order${P.refunds.orders==1?'':'s'} · ${money(P.refunds.amount_xcd)} returned</p></div>
   <div class="an-card"><h4>Wallet and money to come</h4>${CC.TESTBANNER}${wl}
    <ul class="an-pend"><li><span>Awaiting payment on pickup or delivery</span><b>${money(W&&W.awaiting_cash_xcd)}</b></li><li><span>Wallet-paid, order still open</span><b>${money(W&&W.open_wallet_paid_xcd)}</b></li></ul>
    <p class="muted">Test wallet only. Payouts to a real bank account do not exist yet.</p></div>
  </div>
  <div class="an-card"><h4>Low stock alerts</h4>${L.length?`<ul class="an-low">${L.map(p=>`<li class="${p.stock_qty===0?'out':''}"><span><b>${esc(p.name)}</b> <small>alert at ${p.low_stock_threshold} or fewer</small></span><span class="an-q">${p.stock_qty===0?'Out of stock':p.stock_qty+' left'}</span><button class="btn ghost" type="button" data-edit="${esc(p.id)}">Update stock</button></li>`).join('')}</ul>`:'<div class="empty small"><div class="empty-ic" aria-hidden="true">📦</div><p>Nothing is running low. To track stock, enter a stock quantity when you add or edit a product.</p></div>'}</div>
  <div class="an-card"><div class="an-txhead"><h4>Transaction history</h4><button class="btn alt" type="button" id="ancsv" ${rows.length?'':'disabled'}>Export CSV</button></div>
   ${rows.length?`<table class="an-tx"><tr><th>Date</th><th>Type</th><th>Reference</th><th>Detail</th><th>Amount</th></tr>${rows.map(r=>{const o=r.kind==='order';const amt=Number(r.amount_xcd);
    return `<tr><td>${esc(fmtT.format(new Date(r.at)))}</td><td>${o?'Order':'Wallet <small>(test)</small>'}</td><td>${esc(r.ref)}</td><td>${o?esc(METHOD[r.method]||r.method)+' · '+esc(SLAB()[r.status]||r.status)+(r.payment_status==='refunded'?' · refunded':''):esc(WTYPE[r.method]||r.method)+(r.note?' · '+esc(r.note):'')}</td><td class="${!o&&amt<0?'neg':''}">${money(amt)}</td></tr>`}).join('')}</table>
   ${X.truncated?`<p class="muted">Showing the newest ${X.limit} entries. The CSV has the same entries; choose a shorter date range to see older ones.</p>`:''}`:'<div class="empty small"><div class="empty-ic" aria-hidden="true">🧾</div><p>No orders or wallet activity in this period.</p></div>'}</div>`;
  wire();
  const cb=box.querySelector('#ancsv');if(cb)cb.onclick=()=>download('CC-transactions-'+state.from+'_to_'+state.to+'.csv',toCsv(rows));
  box.querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>onEdit&&onEdit(b.dataset.edit));
 }
 function wire(){
  box.querySelectorAll('[data-p]').forEach(b=>b.onclick=()=>{const k=b.dataset.p;state.preset=k;if(k!=='custom'){[state.from,state.to]=ranges(todayGD())[k];load()}else{box.querySelector('#ancust').hidden=false;box.querySelectorAll('[data-p]').forEach(x=>x.classList.toggle('on',x.dataset.p==='custom'))}});
  const f=box.querySelector('#ancust');
  if(f)f.onsubmit=e=>{e.preventDefault();const a=f.querySelector('#anfrom').value,z=f.querySelector('#anto').value,m=box.querySelector('#anmsg');
   const err=!validDate(a)||!validDate(z)?'Choose both a start and an end date.':z<a?'The end date is before the start date.':z>todayGD()?'The end date cannot be in the future.':(toD(z)-toD(a))/864e5>731?'Choose a range of two years or less.':'';
   if(err){m.textContent=err;m.hidden=false;return}
   state.preset='custom';state.from=a;state.to=z;load()};
 }
 await load();
}
CC.analytics={mount,toCsv,csvCell,ranges,todayGD,chart};
})();
