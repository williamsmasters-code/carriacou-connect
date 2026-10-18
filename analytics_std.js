// Standard-tier analytics (v1.1): profit per product, trends (MoM / YoY), peak days+hours, seasonality, staff + POS + cash-up,
// customers, campaign results, tax + license summary. Needs supabase/standard_analytics.sql. No chart libraries: inline SVG.
// Plan and role are enforced INSIDE the database functions; the locked previews below are only for friendliness.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,TZ='America/Grenada';
const A=()=>CC.analytics;
const money=n=>'EC$'+(Number(n)||0).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});
const pctTxt=p=>p==null?'n/a':(p>0?'+':'')+Number(p).toFixed(1)+'%';
const arrow=p=>p==null?'':p>0?'▲':p<0?'▼':'■';
const cls=p=>p==null?'':p>0?'up':p<0?'down':'';
const DOW=['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],DOWL=['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
const MON=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const fmtT=new Intl.DateTimeFormat('en-GB',{timeZone:TZ,hour:'2-digit',minute:'2-digit',hour12:false});
const fmtDM=new Intl.DateTimeFormat('en-GB',{timeZone:TZ,day:'2-digit',month:'short',year:'numeric'});
const hh=h=>String(h).padStart(2,'0')+':00';
const STD=['standard','plus','pro','enterprise'];
const TIERNAME={standard:'Standard',plus:'Plus+',pro:'Pro',enterprise:'Enterprise'};
const kpi=(l,v,sub,c)=>`<div class="kpi ${c||''}"><span>${esc(l)}</span><b>${v}</b>${sub?`<small>${sub}</small>`:''}</div>`;
const empty=(ic,t)=>`<div class="empty small"><div class="empty-ic" aria-hidden="true">${ic}</div><p>${t}</p></div>`;
const NOTAX='Summary for your records, not official tax advice.';
function csv(headers,rows,numeric){ // numeric: set of column indexes written as plain numbers. Formula-injection guard is in csvCell.
 const c=A().csvCell;return '\ufeff'+[headers.map(h=>c(h)).join(',')].concat(rows.map(r=>r.map((v,i)=>c(numeric&&numeric.includes(i)&&v!==''&&v!=null?Number(v).toFixed(2):v,numeric&&numeric.includes(i)&&v!==''&&v!=null)).join(','))).join('\r\n')+'\r\n'}
// ---- inline SVG charts ----
function bars(items,o){ // items [{label,v,hl,tip}], o:{w,h,unit,fmt,every}
 o=o||{};const W=o.w||640,H=o.h||190,L=46,B=24,T=10,iw=W-L-6,ih=H-B-T,n=items.length,bw=iw/n,gap=Math.min(5,bw*.22);
 const max=Math.max(...items.map(i=>i.v),0);if(!max)return '';
 const nice=(()=>{const p=Math.pow(10,Math.floor(Math.log10(max)));const f=max/p;return (f<=1?1:f<=2?2:f<=5?5:10)*p})();
 let s=`<svg class="an-chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(o.aria||'Bar chart')}" preserveAspectRatio="xMidYMid meet">`;
 [0,.5,1].forEach(f=>{const y=T+ih-ih*f;s+=`<line x1="${L}" x2="${W-6}" y1="${y}" y2="${y}" class="gl"/><text x="${L-6}" y="${y+4}" text-anchor="end" class="ax">${esc((o.fmt?o.fmt(nice*f):Math.round(nice*f).toLocaleString('en-US')))}</text>`});
 items.forEach((p,i)=>{const h=Math.max(p.v>0?2:0,ih*p.v/nice),x=L+i*bw+gap/2;
  s+=`<rect x="${x.toFixed(2)}" y="${(T+ih-h).toFixed(2)}" width="${Math.max(1,bw-gap).toFixed(2)}" height="${h.toFixed(2)}" rx="${Math.min(4,bw/3).toFixed(1)}" class="bar${p.hl?' hl':''}${p.alt?' alt':''}"><title>${esc(p.tip||p.label)}</title></rect>`;
  if(!o.every||i%o.every===0)s+=`<text x="${(L+i*bw+bw/2).toFixed(1)}" y="${H-8}" text-anchor="middle" class="ax">${esc(p.label)}</text>`});
 return s+'</svg>';
}
function heat(grid){ // grid [{dow,hour,orders}] -> 7 rows x 24 columns
 const m={};let max=0;grid.forEach(g=>{m[g.dow+'_'+g.hour]=g.orders;max=Math.max(max,g.orders)});if(!max)return '';
 const L=34,T=4,cw=24,ch=20,W=L+24*cw,H=T+7*ch+20;
 let s=`<svg class="an-chart an-heat" viewBox="0 0 ${W} ${H}" role="img" aria-label="Orders by weekday and hour, Grenada time. Darker means more orders." preserveAspectRatio="xMidYMid meet">`;
 for(let d=1;d<=7;d++){s+=`<text x="${L-6}" y="${T+(d-1)*ch+ch/2+4}" text-anchor="end" class="ax">${DOW[d-1]}</text>`;
  for(let h=0;h<24;h++){const v=m[d+'_'+h]||0;const op=v?(.18+.82*v/max):0;
   s+=`<rect x="${L+h*cw+1}" y="${T+(d-1)*ch+1}" width="${cw-2}" height="${ch-2}" rx="3" class="hc" style="fill-opacity:${op.toFixed(2)}"><title>${DOWL[d-1]} ${hh(h)}: ${v} order${v===1?'':'s'}</title></rect>${v?`<text x="${L+h*cw+cw/2}" y="${T+(d-1)*ch+ch/2+4}" text-anchor="middle" class="hv${op>.55?' lt':''}">${v}</text>`:''}`}}
 [0,3,6,9,12,15,18,21].forEach(h=>{s+=`<text x="${L+h*cw+cw/2}" y="${H-5}" text-anchor="middle" class="ax">${hh(h)}</text>`});
 return s+'</svg>';
}
const nice=m=>{m=(m&&m.message)||String(m||'');
 if(/PLAN_REQUIRED/.test(m))return {locked:true};
 if(/Could not find the function|schema cache|does not exist|PGRST202|404/.test(m))return {off:true};
 return {msg:m.replace(/^PLAN_REQUIRED: /,'')}};
const errBox=e=>{const n=nice(e);return n.off?'<div class="notice">Standard analytics is not switched on yet. In Supabase, open the SQL Editor and run <code>supabase/standard_analytics.sql</code> (see README.txt), then refresh.</div>':n.locked?'<div class="notice">This report needs the Standard plan or higher.</div>':'<div class="notice err">Could not load this report: '+esc(n.msg)+'</div>'};

// ---- locked preview for Lite (static example numbers, clearly labelled, no database call) ----
const LOCKS=[
 ['Profit per product','Enter what each product costs you and see profit and margin per product.','<svg viewBox="0 0 160 50" class="lk-svg"><rect x="8" y="10" width="20" height="34" rx="4"/><rect x="38" y="22" width="20" height="22" rx="4"/><rect x="68" y="4" width="20" height="40" rx="4"/><rect x="98" y="28" width="20" height="16" rx="4"/><rect x="128" y="16" width="20" height="28" rx="4"/></svg>','Example: profit EC$1,240 · margin 41%'],
 ['Sales trends','Month-over-month and year-over-year comparison.','<svg viewBox="0 0 160 50" class="lk-svg"><polyline points="6,40 36,30 66,34 96,18 126,22 154,8" fill="none" stroke-width="4" stroke-linecap="round"/></svg>','Example: +12.4% vs last month · +31.0% vs last year'],
 ['Peak days and hours','Busiest weekdays and hours (Grenada time) in a heat map.','<svg viewBox="0 0 160 50" class="lk-svg"><rect x="6" y="6" width="22" height="16" rx="3" opacity=".3"/><rect x="34" y="6" width="22" height="16" rx="3" opacity=".9"/><rect x="62" y="6" width="22" height="16" rx="3" opacity=".5"/><rect x="6" y="28" width="22" height="16" rx="3" opacity=".7"/><rect x="34" y="28" width="22" height="16" rx="3" opacity=".2"/><rect x="62" y="28" width="22" height="16" rx="3"/></svg>','Example: Saturday 11:00 is your busiest hour'],
 ['Seasonality','Tourist season (Dec-Apr) compared with the off-season.','<svg viewBox="0 0 160 50" class="lk-svg"><rect x="8" y="8" width="60" height="36" rx="6"/><rect x="88" y="26" width="60" height="18" rx="6" opacity=".5"/></svg>','Example: EC$210/day in season, EC$95/day off-season'],
 ['Staff sales, POS shifts and cash-up','Who handled which orders and POS charges, and a daily cash-up.','<svg viewBox="0 0 160 50" class="lk-svg"><circle cx="30" cy="18" r="10"/><circle cx="80" cy="18" r="10" opacity=".6"/><circle cx="130" cy="18" r="10" opacity=".3"/><rect x="14" y="34" width="32" height="8" rx="4"/><rect x="64" y="34" width="32" height="8" rx="4" opacity=".6"/><rect x="114" y="34" width="32" height="8" rx="4" opacity=".3"/></svg>','Example: Anna completed 14 orders, EC$820'],
 ['Customers','New and returning customers, and your top customers.','<svg viewBox="0 0 160 50" class="lk-svg"><circle cx="50" cy="25" r="20"/><circle cx="110" cy="25" r="20" opacity=".4"/></svg>','Example: 18 new · 12 returning · 40% repeat rate'],
 ['Campaign results','Sales, discounts given and customers for every campaign.','<svg viewBox="0 0 160 50" class="lk-svg"><rect x="8" y="30" width="26" height="14" rx="3"/><rect x="44" y="18" width="26" height="26" rx="3"/><rect x="80" y="8" width="26" height="36" rx="3"/><rect x="116" y="22" width="26" height="22" rx="3"/></svg>','Example: SPICE10 brought 23 orders, EC$1,430'],
 ['Tax and license summary','Tax collected by period, license expiry reminder, CSV and PDF download.','<svg viewBox="0 0 160 50" class="lk-svg"><rect x="20" y="4" width="50" height="42" rx="5"/><rect x="28" y="14" width="34" height="4" rx="2" fill="#fff"/><rect x="28" y="24" width="34" height="4" rx="2" fill="#fff"/><rect x="28" y="34" width="20" height="4" rx="2" fill="#fff"/></svg>','Example: tax EC$312.40 this quarter']];
function locked(el,o){
 const next=(o.plan&&o.plan.next_tier)||'standard',own=o.isOwner;
 el.innerHTML=`<section class="an-std"><div class="an-stdhead"><h3>Standard analytics <span class="badge t-Standard">Standard and up</span></h3></div>
 <div class="notice lockedmsg" role="note">🔒 These reports are part of the <b>Standard</b> plan (and Plus+, Pro, Enterprise). ${own?'<button class="btn" type="button" id="lkup">Upgrade to see them</button>':'Ask the business owner to upgrade the plan.'}</div>
 <div class="lk-grid">${LOCKS.map(l=>`<div class="lk-card" aria-disabled="true"><div class="lk-art" aria-hidden="true">${l[2]}</div><h4>${esc(l[0])}</h4><p>${esc(l[1])}</p><p class="lk-ex"><small>${esc(l[3])} <em>(example only)</em></small></p><span class="lk-lock" aria-hidden="true">🔒</span></div>`).join('')}</div></section>`;
 const b=el.querySelector('#lkup');if(b)b.onclick=()=>o.onUpgrade?o.onUpgrade():(location.href='tiers.html');
}

async function mount(el,o){
 const {sb,vendor}=o;const tier=(o.plan&&o.plan.tier)||vendor.tier;
 if(!STD.includes(tier)){locked(el,o);return}
 const from=o.from,to=o.to,a={p_vendor:vendor.id,p_from:from,p_to:to},anchor={p_vendor:vendor.id,p_anchor:to},perms=new Set(o.perms||[]);
 const secs=[['profit','Profit per product'],['trends','Sales trends'],['peak','Peak days and hours'],['season','Seasonality'],['staff','Staff, POS shifts and cash-up'],['cust','Customers'],['camp','Campaign results'],['tax','Tax and license']];
 el.innerHTML=`<section class="an-std"><div class="an-stdhead"><h3>Standard analytics <span class="badge t-${esc(TIERNAME[tier].replace('+',''))}">${esc(TIERNAME[tier])}</span></h3><p class="muted">Same date range as above (<b>${esc(from)}</b> to <b>${esc(to)}</b>). Sales exclude cancelled and refunded orders. Days and hours use Grenada time.</p></div>
 ${secs.map(([k,t])=>`<div class="an-card" id="as-${k}"><h4>${esc(t)}</h4><div class="asb"><p class="muted">Loading…</p></div></div>`).join('')}</section>`;
 const body=k=>el.querySelector('#as-'+k+' .asb');
 const guard=async(k,fn)=>{try{await fn(body(k))}catch(e){body(k).innerHTML=errBox(e)}};
 const call=async(fn,args)=>{const r=await sb.rpc(fn,args);if(r.error)throw r.error;return r.data};
 // a PLAN_REQUIRED answer from the database always wins over what this page assumed
 const first=await sb.rpc('vendor_profit_report',a);
 if(first.error&&nice(first.error).locked){locked(el,o);return}
 const jobs=[];
 // ---------- 1. profit ----------
 jobs.push(guard('profit',async b=>{
  if(first.error)throw first.error;const R=first.data,T=R.totals,P=R.products;
  const cov=T.items_sold?Math.round(T.items_costed/T.items_sold*100):0;
  b.innerHTML=`<div class="kpis">${kpi('Profit',T.items_costed?money(T.profit_xcd):'n/a','revenue minus cost, items with a cost')}${kpi('Margin',T.margin_pct==null?'n/a':T.margin_pct+'%','profit / revenue')}${kpi('Cost of goods',money(T.cost_xcd),T.items_costed+' of '+T.items_sold+' items have a cost ('+cov+'%)')}${kpi('Revenue',money(T.revenue_xcd),'after discounts, all items')}</div>
  ${R.products_without_cost?`<div class="notice">${R.products_without_cost} active product${R.products_without_cost===1?' has':'s have'} no cost price yet. Add it in the product form (Products tab) or in the <b>cost_price</b> column of a bulk upload. Orders placed <i>before</i> a cost was entered stay without a cost, so they are left out of profit.</div>`:''}
  ${P.length?`<table><tr><th>Product</th><th>Sold</th><th>Revenue</th><th>Cost</th><th>Profit</th><th>Margin</th></tr>${P.map(p=>`<tr><td>${esc(p.name)}</td><td>${p.qty}${p.qty_costed&&p.qty_costed<p.qty?` <small class="muted">(${p.qty_costed} with cost)</small>`:''}</td><td>${money(p.revenue_xcd)}</td><td>${p.cost_xcd==null?'<span class="muted">no cost</span>':money(p.cost_xcd)}</td><td class="${p.profit_xcd!=null&&p.profit_xcd<0?'neg':''}">${p.profit_xcd==null?'<span class="muted">n/a</span>':money(p.profit_xcd)}</td><td>${p.margin_pct==null?'<span class="muted">n/a</span>':p.margin_pct+'%'}</td></tr>`).join('')}</table>
  <p><button class="btn alt" type="button" id="pfcsv">Export CSV</button></p>`:empty('💰','No sales in this period.')}`;
  const bt=b.querySelector('#pfcsv');if(bt)bt.onclick=()=>A().download('CC-profit-'+from+'_to_'+to+'.csv',csv(['Product','Units sold','Units with cost','Revenue (EC$)','Cost (EC$)','Profit (EC$)','Margin %'],P.map(p=>[p.name,p.qty,p.qty_costed,p.revenue_xcd,p.cost_xcd==null?'':p.cost_xcd,p.profit_xcd==null?'':p.profit_xcd,p.margin_pct==null?'':p.margin_pct]),[3,4,5]));
 }));
 // ---------- 2. trends ----------
 jobs.push(guard('trends',async b=>{
  const R=await call('vendor_sales_trends',anchor),c=R.current;
  const am=R.anchor_month.slice(0,7),months=R.months.map(m=>({label:MON[Number(m.month.slice(5,7))-1]+(m.month.slice(5,7)==='01'||m===R.months[0]?" '"+m.month.slice(2,4):''),v:Number(m.revenue_xcd),hl:m.month===R.anchor_month,tip:m.month.slice(0,7)+': '+money(m.revenue_xcd)+', '+m.orders+' order'+(m.orders===1?'':'s')}));
  b.innerHTML=`<p class="muted">Month shown: <b>${esc(am)}</b>${R.partial?` (so far: the first ${R.days_compared} days are compared with the first ${R.days_compared} days of the earlier months)`:' (full months compared)'}.</p>
  <div class="kpis">${kpi(am,money(c.revenue_xcd),c.orders+' order'+(c.orders===1?'':'s'))}${kpi('vs previous month',`<span class="${cls(R.mom_pct)}">${arrow(R.mom_pct)} ${pctTxt(R.mom_pct)}</span>`,R.previous_month.month.slice(0,7)+': '+money(R.previous_month.revenue_xcd))}${kpi('vs same month last year',`<span class="${cls(R.yoy_pct)}">${arrow(R.yoy_pct)} ${pctTxt(R.yoy_pct)}</span>`,R.previous_year.month.slice(0,7)+': '+money(R.previous_year.revenue_xcd))}</div>
  ${months.some(m=>m.v>0)?bars(months,{aria:'Revenue per month, last 12 months',fmt:v=>Math.round(v).toLocaleString('en-US')}):empty('📈','No sales in the last 12 months yet.')}
  ${R.mom_pct==null||R.yoy_pct==null?'<p class="muted">n/a means the earlier period had no sales to compare with.</p>':''}`;
 }));
 // ---------- 3. peak ----------
 jobs.push(guard('peak',async b=>{
  const R=await call('vendor_peak_times',a);
  if(!R.total_orders){b.innerHTML=empty('🕒','No sales in this period.');return}
  const bd=R.by_dow.slice().sort((x,y)=>y.orders-x.orders||y.dow-x.dow)[0],bh=R.by_hour.slice().sort((x,y)=>y.orders-x.orders||x.hour-y.hour)[0];
  b.innerHTML=`<div class="kpis">${kpi('Busiest day',DOWL[bd.dow-1],bd.orders+' order'+(bd.orders===1?'':'s')+' · '+money(bd.revenue_xcd))}${kpi('Busiest hour',hh(bh.hour)+'–'+hh((bh.hour+1)%24),bh.orders+' order'+(bh.orders===1?'':'s')+' (Grenada time)')}${kpi('Orders counted',R.total_orders,'placed in this period')}</div>
  <div class="an-grid"><div><h5>By weekday</h5>${bars(R.by_dow.map(d=>({label:DOW[d.dow-1],v:d.orders,hl:d.dow===bd.dow,tip:DOWL[d.dow-1]+': '+d.orders+' orders, '+money(d.revenue_xcd)})),{w:320,h:170,aria:'Orders by weekday'})}</div>
  <div><h5>By hour</h5>${bars(R.by_hour.map(d=>({label:String(d.hour),v:d.orders,hl:d.hour===bh.hour,tip:hh(d.hour)+': '+d.orders+' orders, '+money(d.revenue_xcd)})),{w:480,h:170,every:3,aria:'Orders by hour of day'})}</div></div>
  <h5>Weekday and hour together</h5><div class="heatwrap">${heat(R.grid)}</div><p class="muted">Based on when each order was placed (Grenada time, America/Grenada).</p>`;
 }));
 // ---------- 3b. seasonality ----------
 jobs.push(guard('season',async b=>{
  const R=await call('vendor_seasonality',anchor),T=R.seasons.find(s=>s.season==='tourist'),O=R.seasons.find(s=>s.season==='off');
  if(!(Number(T.revenue_xcd)+Number(O.revenue_xcd))){b.innerHTML=`<p class="muted">Window: ${esc(R.from)} to ${esc(R.to)} (24 months).</p>`+empty('🌴','No sales in the last 24 months yet.');return}
  const bm=R.by_month.map(m=>({label:MON[m.month-1],v:Number(m.revenue_per_day_xcd)||0,alt:m.tourist,tip:MON[m.month-1]+': '+money(m.revenue_per_day_xcd)+' per day ('+money(m.revenue_xcd)+', '+m.orders+' orders over '+m.days+' days)'}));
  const ratio=Number(O.revenue_per_day_xcd)>0?Number(T.revenue_per_day_xcd)/Number(O.revenue_per_day_xcd):null;
  b.innerHTML=`<p class="muted">Last 24 months (${esc(R.from)} to ${esc(R.to)}). Tourist season = December to April; off-season = May to November. Compared per day, because the seasons are different lengths.</p>
  <div class="kpis">${kpi('Tourist season / day',money(T.revenue_per_day_xcd),money(T.revenue_xcd)+' · '+T.orders+' orders · '+T.days+' days')}${kpi('Off-season / day',money(O.revenue_per_day_xcd),money(O.revenue_xcd)+' · '+O.orders+' orders · '+O.days+' days')}${kpi('Season vs off-season',ratio==null?'n/a':ratio.toFixed(2)+'×','revenue per day')}</div>
  ${bars(bm,{aria:'Average revenue per day by calendar month; tourist months highlighted',fmt:v=>Math.round(v).toLocaleString('en-US')})}<p class="legend"><span class="sw alt"></span> tourist months (Dec–Apr) <span class="sw"></span> off-season</p>`;
 }));
 // ---------- 4. staff, shifts, cash-up ----------
 jobs.push(guard('staff',async b=>{
  const R=await call('vendor_staff_report',a);
  const ROLE={admin:'Owner',subadmin:'Sub-admin',staff:'Staff'};
  const nm=m=>esc(m.name)+(m.role?` <small class="muted">${esc(ROLE[m.role]||m.role)}${m.status==='suspended'?', suspended':''}</small>`:'');
  const day=to;
  b.innerHTML=`${CC.TESTBANNER}<h5>Sales by team member</h5>${R.members.length?`<table><tr><th>Who</th><th>Orders accepted</th><th>Orders completed</th><th>Completed value</th><th>Cancelled</th><th>POS charges</th><th>POS paid (test)</th></tr>${R.members.map(m=>`<tr><td>${nm(m)}</td><td>${m.orders_accepted}</td><td>${m.orders_completed}</td><td>${money(m.orders_completed_xcd)}</td><td>${m.orders_cancelled}</td><td>${m.pos_charges} <small class="muted">(${m.pos_paid} paid)</small></td><td>${money(m.pos_paid_xcd)}</td></tr>`).join('')}</table>`:empty('👥','No team activity in this period.')}
  <p class="muted">Orders handled = status changes made by that person. POS charges before v1.1 were not tagged with who made them and show as "Not recorded". The POS is test mode (play money).</p>
  <h5>POS shifts</h5>${R.shifts.length?`<table><tr><th>Day</th><th>Who</th><th>From</th><th>To</th><th>Charges</th><th>Paid</th><th>Cancelled</th></tr>${R.shifts.map(s=>`<tr><td>${esc(s.day)}</td><td>${nm(s)}</td><td>${esc(fmtT.format(new Date(s.first_at)))}</td><td>${esc(fmtT.format(new Date(s.last_at)))}</td><td>${s.charges}</td><td>${s.paid} · ${money(s.paid_xcd)}</td><td>${s.cancelled}</td></tr>`).join('')}</table>`:empty('🧾','No POS charges in this period.')}
  <p><button class="btn alt" type="button" id="stcsv" ${R.members.length?'':'disabled'}>Export CSV</button></p>
  <h5>Daily cash-up</h5><form class="an-custom" id="cuf"><label>Day<input type="date" id="cud" value="${esc(day)}" max="${esc(A().todayGD())}"></label><button class="btn alt" type="submit">Show</button></form><div id="cubox"><p class="muted">Loading…</p></div>`;
  const stc=b.querySelector('#stcsv');if(stc)stc.onclick=()=>A().download('CC-staff-'+from+'_to_'+to+'.csv',csv(['Who','Role','Orders accepted','Orders completed','Completed value (EC$)','Orders cancelled','POS charges','POS paid','POS paid value (EC$, test)'],R.members.map(m=>[m.name,m.role||'',m.orders_accepted,m.orders_completed,m.orders_completed_xcd,m.orders_cancelled,m.pos_charges,m.pos_paid,m.pos_paid_xcd]),[4,8]));
  const cu=async d=>{const cb=b.querySelector('#cubox');cb.innerHTML='<p class="muted">Loading…</p>';
   try{const C=await call('vendor_cashup',{p_vendor:vendor.id,p_day:d});
    cb.innerHTML=`<p><b>${esc(C.day)}</b> (Grenada day). Only things the system records are shown. Cash is the value of orders completed that day that were to be paid in person; the system does not record the cash actually handed over, so count your till against this figure.</p>
    <div class="kpis">${kpi('Cash to collect',money(C.cash_expected_xcd),C.cash_orders+' completed order'+(C.cash_orders===1?'':'s')+', pay on pickup/delivery')}${kpi('Wallet (test) orders',money(C.wallet_order_xcd),C.wallet_order_payments+' payment'+(C.wallet_order_payments===1?'':'s'))}${kpi('POS charges paid (test)',money(C.pos_paid_xcd),C.pos_paid+' charge'+(C.pos_paid===1?'':'s'))}${kpi('Refunds (test)',money(C.refunds_xcd),C.refunds+' refund'+(C.refunds===1?'':'s'),'warn')}</div>
    <p class="muted">Wallet money in minus refunds for the day (test money): <b>${money(C.wallet_net_xcd)}</b>${Number(C.other_wallet_in_xcd)?' (includes '+money(C.other_wallet_in_xcd)+' of other test transfers received)':''}.</p>
    ${C.pos_by_member.length||C.cash_by_member.length?`<table><tr><th>Who</th><th>POS charges paid</th><th>Orders completed (cash)</th></tr>${[...new Set([...C.pos_by_member.map(x=>x.user_id),...C.cash_by_member.map(x=>x.user_id)])].map(u=>{const p=C.pos_by_member.find(x=>x.user_id===u),c2=C.cash_by_member.find(x=>x.user_id===u),m=p||c2;return `<tr><td>${nm(m)}</td><td>${p?p.charges+' · '+money(p.xcd):'-'}</td><td>${c2?c2.orders+' · '+money(c2.xcd):'-'}</td></tr>`}).join('')}</table>`:'<p class="muted">Nothing recorded for this day.</p>'}`}
   catch(e){cb.innerHTML=errBox(e)}};
  b.querySelector('#cuf').onsubmit=ev=>{ev.preventDefault();const d=b.querySelector('#cud').value;if(!A().validDate(d)||d>A().todayGD()){b.querySelector('#cubox').innerHTML='<div class="notice err">Choose a day that is not in the future.</div>';return}cu(d)};
  await cu(day);
 }));
 // ---------- 5. customers ----------
 jobs.push(guard('cust',async b=>{
  const R=await call('vendor_customer_report',{...a,p_limit:10});
  if(!R.customers){b.innerHTML=empty('🙋','No customers ordered in this period.');return}
  b.innerHTML=`<div class="kpis">${kpi('Customers',R.customers,R.orders+' order'+(R.orders===1?'':'s'))}${kpi('New',R.new_customers,money(R.new_revenue_xcd)+' · first order from you')}${kpi('Returning',R.returning_customers,money(R.returning_revenue_xcd)+' · ordered before')}${kpi('Repeat rate',R.repeat_rate_pct==null?'n/a':R.repeat_rate_pct+'%','returning, or 2+ orders now')}</div>
  <h5>Top customers by spend</h5><table><tr><th>#</th><th>Customer</th><th>Orders</th><th>Spent</th><th>Last order</th></tr>${R.top.map(t=>`<tr><td>${t.rank}</td><td>${esc(t.name)}${t.phone_hint?` <small class="muted">(${esc(t.phone_hint)})</small>`:''}${t.is_new?' <span class="cpst s-run">New</span>':''}</td><td>${t.orders}</td><td>${money(t.spent_xcd)}</td><td>${esc(fmtDM.format(new Date(t.last_order)))}</td></tr>`).join('')}</table>
  <p class="muted">Only people who ordered from your business are shown, using the name they gave on the order. Account details are never shown.</p>`;
 }));
 // ---------- 6. campaigns ----------
 jobs.push(guard('camp',async b=>{
  const R=await call('vendor_campaign_report',a);
  if(!R.campaigns.length){b.innerHTML=empty('📣','No campaigns yet. Create one in the Campaigns tab, then share its code.');return}
  const share=Number(R.all_revenue_xcd)>0?Math.round(Number(R.campaign_revenue_xcd)/Number(R.all_revenue_xcd)*100):0;
  b.innerHTML=`<div class="kpis">${kpi('Campaign orders',R.campaign_orders,'of '+R.all_orders+' orders ('+share+'% of revenue)')}${kpi('Campaign revenue',money(R.campaign_revenue_xcd),'after discounts')}${kpi('Discounts given',money(R.discount_given_xcd),'','warn')}</div>
  <table><tr><th>Campaign</th><th>Status</th><th>Orders</th><th>Revenue</th><th>Discounts</th><th>Customers</th><th>Avg order</th></tr>${R.campaigns.map(c=>`<tr><td><b>${esc(c.name)}</b>${c.code?` <small class="muted">${esc(c.code)}${c.discount_pct!=null?' · '+Number(c.discount_pct)+'% off':''}</small>`:''}</td><td><span class="cpst s-${c.status==='running'?'run':c.status==='paused'?'paused':c.status==='scheduled'?'sched':'ended'}">${esc(c.status)}</span></td><td>${c.orders}</td><td>${money(c.revenue_xcd)}</td><td>${money(c.discount_given_xcd)}</td><td>${c.customers}</td><td>${c.avg_order_xcd==null?'n/a':money(c.avg_order_xcd)}</td></tr>`).join('')}</table>
  <p class="muted">Orders count when they were placed in the date range and carry the campaign code. Sales come only from orders where the shopper entered the code at checkout.</p>`;
 }));
 // ---------- 7. tax ----------
 jobs.push(guard('tax',async b=>{
  const R=await call('vendor_tax_report',a),st=R.settings,canEdit=perms.has('vendor_edit');
  const dl=st.license_days_left;
  const lic=st.license_expiry==null?'':dl<0?`<div class="notice err" role="alert">Your license expired ${-dl} day${dl===-1?'':'s'} ago (${esc(st.license_expiry)}).</div>`:dl<=30?`<div class="notice">Your license expires in ${dl} day${dl===1?'':'s'} (${esc(st.license_expiry)}).</div>`:'';
  b.innerHTML=`<p class="notice" role="note"><b>${NOTAX}</b> Rates come from the settings below; check them with the Inland Revenue Division or your accountant.</p>${lic}
  <form id="taxf" class="formcard" novalidate><h5>Settings</h5>
   <div class="stockrow"><label>Tax rate (%)<input id="txr" type="number" min="0" max="100" step="0.01" inputmode="decimal" value="${st.tax_rate_pct==null?'':esc(st.tax_rate_pct)}" placeholder="e.g. 15" ${canEdit?'':'disabled'}></label>
   <label class="chk" style="align-self:end"><input type="checkbox" id="txi" ${st.tax_inclusive?'checked':''} ${canEdit?'':'disabled'}> My prices already include tax</label></div>
   <div class="stockrow"><label>License number<input id="txl" maxlength="60" value="${esc(st.license_number||'')}" ${canEdit?'':'disabled'}></label><label>License expiry<input id="txe" type="date" value="${esc(st.license_expiry||'')}" ${canEdit?'':'disabled'}></label></div>
   ${canEdit?'<button class="btn" id="txs">Save settings</button>':'<p class="muted">Only the business owner can change these settings.</p>'}<div id="txm" class="notice" hidden role="alert"></div></form>
  <p class="muted">The rate is saved on each order when it is placed, so changing the rate later does not rewrite old orders. Orders placed before you set a rate use your current rate. Tax-inclusive: tax = sales × rate ÷ (100 + rate). Tax-exclusive: tax = sales × rate ÷ 100 (the checkout does not add tax to the customer's total).</p>
  <div class="kpis">${kpi('Sales',money(R.sales_xcd),R.orders+' order'+(R.orders===1?'':'s')+', not cancelled or refunded')}${kpi('Tax (estimated)',money(R.tax_xcd),st.tax_rate_pct==null?'set a rate above':'at '+Number(st.tax_rate_pct)+'%'+(st.tax_inclusive?' included':' on top'))}${kpi('Included in prices',money(R.tax_inclusive_xcd))}${kpi('Not added at checkout',money(R.tax_exclusive_xcd))}</div>
  ${R.orders_without_rate?`<div class="notice">${R.orders_without_rate} order${R.orders_without_rate===1?' has':'s have'} no tax rate (none set yet), so no tax is counted for ${R.orders_without_rate===1?'it':'them'}.</div>`:''}
  ${R.by_month.length?`<table><tr><th>Month</th><th>Orders</th><th>Sales</th><th>Tax</th></tr>${R.by_month.map(m=>`<tr><td>${esc(String(m.month).slice(0,7))}</td><td>${m.orders}</td><td>${money(m.sales_xcd)}</td><td>${money(m.tax_xcd)}</td></tr>`).join('')}</table>`:empty('🧾','No sales in this period.')}
  <p><button class="btn alt" type="button" id="txcsv" ${R.rows.length?'':'disabled'}>Download CSV</button> <button class="btn alt" type="button" id="txpdf">Download PDF</button></p>
  ${R.truncated?`<p class="muted">The CSV and PDF list the newest ${R.limit} orders; totals above cover every order in the range.</p>`:''}<div id="txpm" class="notice" hidden></div>
  <p class="muted"><small>${NOTAX}</small></p>`;
  const tc=b.querySelector('#txcsv');if(tc)tc.onclick=()=>{const rows=R.rows.map(r=>[r.day,r.ref,r.total_xcd,r.rate_pct==null?'':r.rate_pct,r.inclusive?'included':'on top',r.tax_xcd==null?'':r.tax_xcd]);
   A().download('CC-tax-'+from+'_to_'+to+'.csv',csv(['Date (Grenada)','Order','Order total (EC$)','Tax rate %','Prices','Tax (EC$)'],rows,[2,5])+'\r\n'+A().csvCell(NOTAX)+'\r\n')};
  b.querySelector('#txpdf').onclick=()=>{if(CC.orderPdf&&CC.orderPdf.tax)CC.orderPdf.tax(R,{vendorName:vendor.name,from,to},b.querySelector('#txpdf'),b.querySelector('#txpm'));else{const m=b.querySelector('#txpm');m.className='notice err';m.textContent='The PDF tool did not load. Refresh the page.';m.hidden=false}};
  const f=b.querySelector('#taxf');
  if(canEdit)f.onsubmit=async ev=>{ev.preventDefault();const m=b.querySelector('#txm'),say=t=>{m.className='notice err';m.textContent=t;m.hidden=!t};
   const rate=b.querySelector('#txr').value.trim(),lic=b.querySelector('#txl').value.trim(),exp=b.querySelector('#txe').value;
   if(rate!==''&&!(Number(rate)>=0&&Number(rate)<=100))return say('The tax rate must be between 0 and 100.');
   if(exp&&!A().validDate(exp))return say('Choose a valid license expiry date.');
   const row={tax_rate_pct:rate===''?null:Number(rate),tax_inclusive:b.querySelector('#txi').checked,license_number:lic||null,license_expiry:exp||null};
   const btn=b.querySelector('#txs');btn.disabled=true;
   const ex=await sb.from('vendor_tax_settings').select('vendor_id').eq('vendor_id',vendor.id).maybeSingle();
   const r=ex.data?await sb.from('vendor_tax_settings').update(row).eq('vendor_id',vendor.id):await sb.from('vendor_tax_settings').insert({...row,vendor_id:vendor.id});
   if(r.error){say(/Could not find|schema cache|does not exist/.test(r.error.message)?'Tax settings need standard_analytics.sql to be run in Supabase first.':/row-level security/.test(r.error.message)?'Only the business owner on a Standard plan or higher can change these settings.':r.error.message);btn.disabled=false;return}
   const sx=el.closest('#anstd')||el;mount(sx,o);};
 }));
 await Promise.all(jobs);
}
CC.analyticsStd={mount};
})();
