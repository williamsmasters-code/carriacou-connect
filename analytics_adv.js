// ADVANCED (Pro, Enterprise) and PREMIUM (Enterprise) vendor analytics, v1.3. Needs supabase/advanced_analytics.sql. No chart libraries: inline SVG.
// Plan and role are enforced INSIDE the database functions and table policies; the locked previews here are only for friendliness.
// Enterprise owners can choose which report cards show and in which order (saved in vendor_dashboard_prefs).
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,TZ='America/Grenada';
const S=()=>CC.analyticsStd,A=()=>CC.analytics;
const money=n=>'EC$'+(Number(n)||0).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});
const pct=p=>p==null?'n/a':Number(p).toFixed(1)+'%';
const DOWS=['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
const MON=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const RANK={lite:1,standard:2,plus:3,pro:4,enterprise:5};
const TIERNAME={lite:'Lite',standard:'Standard',plus:'Plus+',pro:'Pro',enterprise:'Enterprise'};
const kpi=(l,v,sub,c)=>`<div class="kpi ${c||''}"><span>${esc(l)}</span><b>${v}</b>${sub?`<small>${sub}</small>`:''}</div>`;
const empty=(ic,t)=>`<div class="empty small"><div class="empty-ic" aria-hidden="true">${ic}</div><p>${t}</p></div>`;
const num=n=>Number(n)||0;
const mlabel=m=>{m=String(m).slice(0,7);return MON[Number(m.slice(5,7))-1]+" '"+m.slice(2,4)};
const csv=(h,r,n)=>S().csv(h,r,n);
const dl=(name,text)=>A().download(name,text);
// the date as dd/mm/yyyy, mm/dd/yyyy from yyyy-mm-dd
const dmy=s=>s.slice(8,10)+'/'+s.slice(5,7)+'/'+s.slice(0,4),mdy=s=>s.slice(5,7)+'/'+s.slice(8,10)+'/'+s.slice(0,4);
const nice=m=>{m=(m&&m.message)||String(m||'');
 if(/PLAN_REQUIRED/.test(m))return {locked:true,msg:m.replace(/^PLAN_REQUIRED: /,'')};
 if(/Could not find the function|schema cache|does not exist|PGRST202|404|relation .* does not exist/.test(m))return {off:true};
 return {msg:m}};
const errBox=e=>{const n=nice(e);return n.off?'<div class="notice">Advanced analytics is not switched on yet. In Supabase, open the SQL Editor and run <code>supabase/advanced_analytics.sql</code> (see README.txt), then refresh.</div>':n.locked?'<div class="notice">🔒 '+esc(n.msg)+'.</div>':'<div class="notice err">Could not load this report: '+esc(n.msg)+'</div>'};
const STATUS={out:['Out of stock','bad'],reorder:['Reorder now','bad'],soon:['Order soon','warn'],ok:['OK','good'],no_sales:['No sales','mute']};
const pill=(k,l)=>`<span class="aa-pill ${k}">${esc(l)}</span>`;

// ---- inline SVG charts (bars come from the Standard module) ----
function pairs(items,o){ // items [{label,a,b,tip}]: a = first bar (sea), b = second bar (gold, coral when negative). Handles negatives.
 o=o||{};const W=640,H=210,L=52,B=26,T=10,iw=W-L-6,ih=H-B-T,n=items.length;if(!n)return '';
 const vals=items.flatMap(i=>[i.a,i.b]);const hi=Math.max(...vals,0),lo=Math.min(...vals,0);if(!hi&&!lo)return '';
 const nice1=v=>{if(!v)return 0;const p=Math.pow(10,Math.floor(Math.log10(Math.abs(v))));const f=Math.abs(v)/p;return Math.sign(v)*(f<=1?1:f<=2?2:f<=5?5:10)*p};
 const top=nice1(hi),bot=nice1(lo),span=(top-bot)||1,y=v=>T+ih*(top-v)/span,gw=iw/n,bw=Math.max(2,Math.min(26,gw/2-3));
 let s=`<svg class="an-chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(o.aria||'Bar chart')}" preserveAspectRatio="xMidYMid meet">`;
 [top,(top+bot)/2,bot].forEach(v=>{s+=`<line x1="${L}" x2="${W-6}" y1="${y(v)}" y2="${y(v)}" class="gl"/><text x="${L-6}" y="${y(v)+4}" text-anchor="end" class="ax">${esc(Math.round(v).toLocaleString('en-US'))}</text>`});
 items.forEach((it,i)=>{const cx=L+i*gw+gw/2;
  [[it.a,cx-bw-1,'bar'],[it.b,cx+1,'bar '+(it.b<0?'alt':'hl')]].forEach(([v,x,c])=>{const y0=y(0),y1=y(v);s+=`<rect x="${x.toFixed(1)}" y="${Math.min(y0,y1).toFixed(1)}" width="${bw}" height="${Math.max(v?2:0,Math.abs(y1-y0)).toFixed(1)}" rx="3" class="${c}"><title>${esc(it.tip||it.label)}</title></rect>`});
  s+=`<text x="${cx.toFixed(1)}" y="${H-8}" text-anchor="middle" class="ax">${esc(it.label)}</text>`});
 return s+'</svg>';
}
function hbars(items,o){ // horizontal bars [{label,v,tip}]
 o=o||{};const max=Math.max(...items.map(i=>i.v),0);if(!max)return '';const rowH=30,L=110,W=640,H=items.length*rowH+8;
 let s=`<svg class="an-chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(o.aria||'Bar chart')}" preserveAspectRatio="xMidYMid meet">`;
 items.forEach((it,i)=>{const w=Math.max(it.v>0?3:0,(W-L-70)*it.v/max),y=4+i*rowH;
  s+=`<text x="${L-8}" y="${y+17}" text-anchor="end" class="lbl">${esc(it.label)}</text><rect x="${L}" y="${y+3}" width="${w.toFixed(1)}" height="18" rx="5" class="bar"><title>${esc(it.tip||it.label)}</title></rect><text x="${(L+w+6).toFixed(1)}" y="${y+17}" class="lbl val">${esc(it.text!=null?it.text:it.v)}</text>`});
 return s+'</svg>';
}
function range(m){ // benchmark: band p25-p75, median tick, your marker
 const hi=Math.max(num(m.peer_p75),num(m.yours),num(m.peer_median))*1.15||1,W=640,H=52,L=10,R=20,x=v=>L+(W-L-R)*Math.max(0,Math.min(v,hi))/hi;
 return `<svg class="an-chart an-range" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(m.label)}: you ${esc(String(m.yours))}, similar businesses typically ${esc(String(m.peer_p25))} to ${esc(String(m.peer_p75))}, median ${esc(String(m.peer_median))}" preserveAspectRatio="xMidYMid meet">
  <line x1="${L}" x2="${W-R}" y1="30" y2="30" class="gl"/><rect x="${x(num(m.peer_p25)).toFixed(1)}" y="22" width="${Math.max(3,x(num(m.peer_p75))-x(num(m.peer_p25))).toFixed(1)}" height="16" rx="8" class="rg-band"><title>Middle half of similar businesses: ${esc(String(m.peer_p25))} to ${esc(String(m.peer_p75))}</title></rect>
  <line x1="${x(num(m.peer_median)).toFixed(1)}" x2="${x(num(m.peer_median)).toFixed(1)}" y1="18" y2="42" class="rg-med"><title>Median ${esc(String(m.peer_median))}</title></line>
  <circle cx="${x(num(m.yours)).toFixed(1)}" cy="30" r="9" class="rg-you"><title>You: ${esc(String(m.yours))}</title></circle><text x="${x(num(m.yours)).toFixed(1)}" y="12" text-anchor="middle" class="lbl val">You</text></svg>`;
}
function ring(score,band){ // credit-readiness score
 const r=52,c=2*Math.PI*r,f=Math.max(0,Math.min(100,score))/100;
 return `<svg class="an-ring" viewBox="0 0 140 140" role="img" aria-label="Readiness score ${score} out of 100, ${esc(band)}"><circle cx="70" cy="70" r="${r}" class="rg-bg"/><circle cx="70" cy="70" r="${r}" class="rg-fg ${esc(band)}" stroke-dasharray="${(c*f).toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 70 70)"/><text x="70" y="68" text-anchor="middle" class="rg-n">${score}</text><text x="70" y="90" text-anchor="middle" class="rg-s">out of 100</text></svg>`;
}

// ---- report cards ----
const META={
 forecast:{t:'Sales forecast and cash flow',adv:true,d:'Expected sales for the next 7 and 28 days from your own history, and what is left after costs and expenses.'},
 pnl:{t:'Profit and loss statement',adv:true,d:'Monthly profit and loss: revenue, cost of goods, expenses and net profit. Printable.'},
 expenses:{t:'Expense tracking',adv:true,d:'Record rent, wages, utilities and other costs so profit and cash flow are real.'},
 inventory:{t:'Inventory valuation, turnover and reorder',adv:true,d:'What your stock is worth, how fast it sells, and what to order next.'},
 clv:{t:'Customer lifetime value and segments',adv:true,d:'Value per customer, loyal and at-risk groups, local and overseas phone numbers.'},
 accounting:{t:'Accounting export (QuickBooks, Xero)',adv:true,d:'Download sales and expenses in files you can import into accounting software.'},
 benchmark:{t:'Benchmark against similar businesses',adv:false,d:'See how you compare with anonymous averages of similar Carriacou businesses.'},
 pricing:{t:'Pricing and discount insights',adv:false,d:'Which products could carry a higher price or a discount, and whether past campaigns lifted sales.'},
 fraud:{t:'Fraud and refund monitoring',adv:false,d:'Unusual cancellations, refunds, large first orders, shared phone numbers and order bursts.'},
 credit:{t:'Loan and credit-readiness report',adv:false,d:'A transparent checklist score you can print and bring to a lender.'},
 export:{t:'Data export',adv:false,d:'Download all your orders and order lines for your own records.'}};
const DEFAULT=['forecast','pnl','expenses','inventory','clv','accounting','benchmark','pricing','fraud','credit','export'];
const NOT_FEASIBLE=['Scheduled email reports (this site cannot send email on a schedule yet)','Multi-location comparison (the database has no locations; staff comparison is in the Standard reports)','Dynamic price elasticity (needs far more price changes than a small shop has; see the rules-based suggestions instead)','Chargebacks and an API (Connect Pay is play money; no card payments or API keys exist yet)'];

function locked(el,o,kind){
 const own=o.isOwner,adv=kind==='adv';
 const list=DEFAULT.filter(k=>META[k].adv===adv);
 el.innerHTML=`<section class="an-std an-adv ${adv?'':'prem'}"><div class="an-stdhead"><h3>${adv?'Advanced':'Premium'} analytics <span class="badge ${adv?'t-Pro':'t-Enterprise'}">${adv?'Pro and Enterprise':'Enterprise'}</span></h3></div>
 <div class="notice lockedmsg" role="note">🔒 These reports are part of the <b>${adv?'Pro</b> plan (and Enterprise)':'Enterprise</b> plan'}. ${own?'<button class="btn" type="button" data-lk="1">Upgrade to see them</button>':'Ask the business owner to upgrade the plan.'}</div>
 <div class="lk-grid">${list.map(k=>`<div class="aa-lk" aria-disabled="true"><h4>${esc(META[k].t)}</h4><p>${esc(META[k].d)}</p><span class="lk-lock" aria-hidden="true">🔒</span></div>`).join('')}</div></section>`;
 const b=el.querySelector('[data-lk]');if(b)b.onclick=()=>o.onUpgrade?o.onUpgrade():(location.href='tiers.html');
}

async function mount(el,o){
 const {vendor}=o;const tier=(o.plan&&o.plan.tier)||vendor.tier;const rank=RANK[tier]||1;
 if(rank<4){el.innerHTML='<div id="adv-a"></div><div id="adv-p"></div>';locked(el.querySelector('#adv-a'),o,'adv');locked(el.querySelector('#adv-p'),o,'prem');return}
 if(rank<5){el.innerHTML='<div id="adv-a"></div><div id="adv-p"></div>';locked(el.querySelector('#adv-p'),o,'prem');return build(el.querySelector('#adv-a'),o,false,DEFAULT.filter(k=>META[k].adv))}
 // Enterprise: saved layout (which cards, which order)
 let layout=null,layoutErr=null;
 try{const r=await o.sb.from('vendor_dashboard_prefs').select('widgets').eq('vendor_id',vendor.id).maybeSingle();if(r.error)layoutErr=r.error;else if(r.data&&Array.isArray(r.data.widgets))layout=r.data.widgets.filter(k=>META[k])}catch(e){layoutErr=e}
 return build(el,o,true,layout||DEFAULT.slice(),layout);
}

async function build(el,o,prem,keys,saved){
 const {sb,vendor}=o,from=o.from,to=o.to,perms=new Set(o.perms||[]);
 const tier=(o.plan&&o.plan.tier)||vendor.tier;
 const custom=prem?`<div class="aa-custom"><button class="btn alt" type="button" id="aa-cu">Customize this dashboard</button>${saved?' <span class="muted">Your saved layout is on.</span>':''}</div><div id="aa-cp" class="formcard" hidden></div>`:'';
 el.innerHTML=`<section class="an-std an-adv"><div class="an-stdhead"><h3>${prem?'Advanced and Premium analytics':'Advanced analytics'} <span class="badge t-${esc(TIERNAME[tier].replace('+',''))}">${esc(TIERNAME[tier])}</span></h3>
 <p class="muted">Date range as above (<b>${esc(from)}</b> to <b>${esc(to)}</b>) where a report uses one. Sales exclude cancelled and refunded orders. Days use Grenada time. Forecasts and scores are estimates from your own data, not promises.</p>${custom}</div>
 ${keys.length?keys.map(k=>`<div class="an-card" id="aa-${k}"><h4>${esc(META[k].t)} <span class="aa-tag ${META[k].adv?'adv':'prem'}">${META[k].adv?'Advanced':'Premium'}</span></h4><div class="asb"><p class="muted">Loading…</p></div></div>`).join(''):empty('🧩','You have hidden every report. Use <b>Customize this dashboard</b> to show some.')}
 <details class="aa-nf"><summary>Not available yet</summary><ul>${NOT_FEASIBLE.map(x=>`<li>${esc(x)}</li>`).join('')}</ul></details></section>`;
 const body=k=>el.querySelector('#aa-'+k+' .asb');
 const call=async(fn,args)=>{const r=await sb.rpc(fn,args);if(r.error)throw r.error;return r.data};
 const a={p_vendor:vendor.id,p_from:from,p_to:to},v1={p_vendor:vendor.id};
 const pdf=(spec,btn,msg)=>{if(CC.orderPdf&&CC.orderPdf.report)CC.orderPdf.report(spec,{vendorName:vendor.name},btn,msg);else{msg.className='notice err';msg.textContent='The PDF tool did not load. Refresh the page.';msg.hidden=false}};
 const jobs=[];const R={};
 const add=(k,fn)=>{if(!keys.includes(k))return;jobs.push((async()=>{try{await fn(body(k))}catch(e){body(k).innerHTML=errBox(e)}})())};
 const mk=(id,label,cls)=>`<button class="btn ${cls||'alt'}" type="button" id="${id}">${label}</button>`;
 const msgBox=id=>`<div id="${id}" class="notice" hidden role="status"></div>`;

 // ---------- forecast ----------
 add('forecast',async b=>{
  const F=await call('vendor_forecast',v1);
  if(F.insufficient){b.innerHTML=empty('🔮',`A forecast needs at least <b>${F.needed_days} days</b> of sales history. You have ${F.days_of_history}. Keep selling and check back.`);return}
  const c=F.cashflow,days=F.days.map((d,i)=>({label:i%7===0?d.day.slice(5):'',v:num(d.revenue_xcd),hl:d.dow>=6,tip:DOWS[d.dow-1]+' '+d.day+': about '+money(d.revenue_xcd)+', '+num(d.orders).toFixed(1)+' orders'}));
  b.innerHTML=`<p class="muted">Based on the ${F.history_days} days from ${esc(F.history_from)} to ${esc(F.history_to)}: each weekday's average sales, carried forward. It does not know about holidays, campaigns or weather.</p>
  <div class="kpis">${kpi('Next 7 days',money(F.next7_revenue_xcd),'about '+num(F.next7_orders).toFixed(0)+' orders')}${kpi('Next 28 days',money(F.next28_revenue_xcd),F.next28_low_xcd!=null?'typical range '+money(F.next28_low_xcd)+' to '+money(F.next28_high_xcd):'range needs 4 full weeks of history')}${kpi('Expected left after costs',`<span class="${num(c.net_xcd)<0?'down':''}">${money(c.net_xcd)}</span>`,'next 28 days, after cost of goods and expenses',num(c.net_xcd)<0?'warn':'')}</div>
  ${S().bars(days,{aria:'Forecast sales per day for the next 28 days; weekends highlighted',fmt:v=>Math.round(v).toLocaleString('en-US'),every:1})}
  <p class="legend"><span class="sw"></span>weekday <span class="sw hl"></span>weekend</p>
  <h5>Cash-flow outlook, next 28 days</h5>
  <table><tr><th>Line</th><th>Amount</th><th>How it is worked out</th></tr>
  <tr><td>Expected sales</td><td>${money(c.revenue_xcd)}</td><td>sum of the weekday forecasts</td></tr>
  <tr><td>Cost of goods (estimate)</td><td>- ${money(c.cost_of_goods_xcd)}</td><td>${F.cost_ratio_pct==null?'no product costs recorded, so counted as 0':'cost is '+pct(F.cost_ratio_pct)+' of sales on items with a cost price'}</td></tr>
  <tr><td>Expenses (estimate)</td><td>- ${money(c.expenses_xcd)}</td><td>${money(F.expenses_per_day_xcd)} a day over the same history, x 28</td></tr>
  <tr class="tot"><td><b>Left over</b></td><td class="${num(c.net_xcd)<0?'neg':''}"><b>${money(c.net_xcd)}</b></td><td></td></tr></table>
  <p>${mk('fccsv','Export CSV')} ${mk('fcpdf','Download PDF')}</p>${msgBox('fcm')}`;
  b.querySelector('#fccsv').onclick=()=>dl('CC-forecast-'+F.days[0].day+'.csv',csv(['Date (Grenada)','Weekday','Forecast sales (EC$)','Forecast orders'],F.days.map(d=>[d.day,DOWS[d.dow-1],d.revenue_xcd,d.orders]),[2,3]));
  b.querySelector('#fcpdf').onclick=()=>pdf({title:'Sales forecast',sub:'Sales forecast and cash flow',file:'CC-forecast-'+F.days[0].day,period:'History '+F.history_from+' to '+F.history_to+' (Grenada local days). Forecast from '+F.days[0].day+' for 28 days.',warn:'An estimate from past sales only. It does not know about holidays, campaigns or weather.',
   kvs:[['Next 7 days',money(F.next7_revenue_xcd)],['Next 28 days',money(F.next28_revenue_xcd)],['Typical range (28 days)',F.next28_low_xcd!=null?money(F.next28_low_xcd)+' to '+money(F.next28_high_xcd):'not enough history'],['Cost of goods (estimate)',money(c.cost_of_goods_xcd)],['Expenses (estimate)',money(c.expenses_xcd)],['Left over (estimate)',money(c.net_xcd)]],
   sections:[{h:'Forecast by day',table:{cols:[{t:'Date',w:.3},{t:'Weekday',w:.25},{t:'Sales',w:.25,align:'right'},{t:'Orders',w:.2,align:'right'}],rows:F.days.map(d=>[d.day,DOWS[d.dow-1],money(d.revenue_xcd),num(d.orders).toFixed(1)]),size:8}}]},b.querySelector('#fcpdf'),b.querySelector('#fcm'));
 });

 // ---------- profit and loss ----------
 add('pnl',async b=>{
  const P=await call('vendor_pnl',a),T=P.totals,M=P.months;
  const cov=T.cost_coverage_pct;
  b.innerHTML=`<div class="kpis">${kpi('Revenue',money(T.revenue_xcd),T.orders+' order'+(T.orders===1?'':'s')+(num(T.tax_collected_xcd)>0?', before '+money(T.tax_collected_xcd)+' tax collected':''))}${kpi('Gross profit',money(T.gross_profit_xcd),'revenue minus cost of goods')}${kpi('Expenses',money(T.expenses_xcd),'entered in Expense tracking')}${kpi('Net profit',`<span class="${num(T.net_profit_xcd)<0?'down':''}">${money(T.net_profit_xcd)}</span>`,'gross profit minus expenses',num(T.net_profit_xcd)<0?'warn':'')}</div>
  ${cov!=null&&cov<100?`<div class="notice">Only <b>${pct(cov)}</b> of revenue has a cost price (${money(T.uncosted_revenue_xcd)} has none), so cost of goods may be too low and profit too high. Add cost prices to your products for a complete picture.</div>`:''}
  ${M.some(m=>m.orders||num(m.expenses_xcd))?pairs(M.map(m=>({label:mlabel(m.month),a:num(m.revenue_xcd),b:num(m.net_profit_xcd),tip:mlabel(m.month)+': revenue '+money(m.revenue_xcd)+', net profit '+money(m.net_profit_xcd)})),{aria:'Revenue and net profit per month'})+'<p class="legend"><span class="sw"></span>revenue <span class="sw hl"></span>net profit <span class="sw alt"></span>net loss</p>':empty('📒','No sales or expenses in this period.')}
  <div class="tblw"><table><tr><th>Month</th><th>Orders</th><th>Revenue</th><th>Discounts given</th><th>Cost of goods</th><th>Gross profit</th><th>Expenses</th><th>Net profit</th></tr>
  ${M.map(m=>`<tr><td>${esc(mlabel(m.month))}</td><td>${m.orders}</td><td>${money(m.revenue_xcd)}</td><td>${money(m.discounts_xcd)}</td><td>${money(m.cogs_xcd)}</td><td>${money(m.gross_profit_xcd)}</td><td>${money(m.expenses_xcd)}</td><td class="${num(m.net_profit_xcd)<0?'neg':''}"><b>${money(m.net_profit_xcd)}</b></td></tr>`).join('')}
  <tr class="tot"><td><b>Total</b></td><td>${T.orders}</td><td>${money(T.revenue_xcd)}</td><td>${money(T.discounts_xcd)}</td><td>${money(T.cogs_xcd)}</td><td>${money(T.gross_profit_xcd)}</td><td>${money(T.expenses_xcd)}</td><td class="${num(T.net_profit_xcd)<0?'neg':''}"><b>${money(T.net_profit_xcd)}</b></td></tr></table></div>
  ${P.expenses_by_category.length?`<h5>Expenses by category</h5><table><tr><th>Category</th><th>Amount</th></tr>${P.expenses_by_category.map(x=>`<tr><td>${esc(x.category)}</td><td>${money(x.amount_xcd)}</td></tr>`).join('')}</table>`:''}
  <p class="muted">Revenue = what customers paid (after discounts). Cost of goods uses the cost price saved on each order line. Stock purchases are not entered as expenses: they are already counted through cost prices. Tax is not deducted. For your records; not an audited statement.</p>
  <p>${mk('plcsv','Export CSV')} ${mk('plpdf','Download PDF')}</p>${msgBox('plm')}`;
  b.querySelector('#plcsv').onclick=()=>dl('CC-pnl-'+from+'_to_'+to+'.csv',csv(['Month','Orders','Revenue (EC$)','Discounts given (EC$)','Cost of goods (EC$)','Gross profit (EC$)','Expenses (EC$)','Net profit (EC$)'],M.map(m=>[String(m.month).slice(0,7),m.orders,m.revenue_xcd,m.discounts_xcd,m.cogs_xcd,m.gross_profit_xcd,m.expenses_xcd,m.net_profit_xcd]).concat([['Total',T.orders,T.revenue_xcd,T.discounts_xcd,T.cogs_xcd,T.gross_profit_xcd,T.expenses_xcd,T.net_profit_xcd]]),[2,3,4,5,6,7]));
  b.querySelector('#plpdf').onclick=()=>pdf({title:'Profit and loss',sub:'Profit and loss statement',file:'CC-pnl-'+from+'_to_'+to,period:'Period '+from+' to '+to+' (Grenada local days)',warn:'For your records, not an audited statement. Sales exclude cancelled and refunded orders. Tax is not deducted.'+(cov!=null&&cov<100?' Only '+pct(cov)+' of revenue has a cost price, so profit may be overstated.':''),
   kvs:[['Revenue',money(T.revenue_xcd)],['Cost of goods',money(T.cogs_xcd)],['Gross profit',money(T.gross_profit_xcd)],['Expenses',money(T.expenses_xcd)],['Net profit',money(T.net_profit_xcd)]],
   sections:[{h:'By month',table:{cols:[{t:'Month',w:.14},{t:'Orders',w:.09,align:'right'},{t:'Revenue',w:.15,align:'right'},{t:'Cost of goods',w:.15,align:'right'},{t:'Gross',w:.15,align:'right'},{t:'Expenses',w:.15,align:'right'},{t:'Net',w:.17,align:'right'}],rows:M.map(m=>[String(m.month).slice(0,7),String(m.orders),money(m.revenue_xcd),money(m.cogs_xcd),money(m.gross_profit_xcd),money(m.expenses_xcd),money(m.net_profit_xcd)]),size:8}},
    {h:'Expenses by category',table:{cols:[{t:'Category',w:.6},{t:'Amount',w:.4,align:'right'}],rows:P.expenses_by_category.map(x=>[x.category,money(x.amount_xcd)])}}]},b.querySelector('#plpdf'),b.querySelector('#plm'));
 });

 // ---------- expenses ----------
 add('expenses',async b=>{
  const r=await sb.from('vendor_expenses').select('*').eq('vendor_id',vendor.id).order('spent_on',{ascending:false}).limit(200);
  if(r.error)throw r.error;const rows=r.data||[];const canEdit=!!o.isOwner;
  const CATS=['rent','wages','utilities','transport','marketing','fees','equipment','other'];
  b.innerHTML=`<p class="muted">Enter running costs here. <b>Do not enter stock purchases</b>: stock is already counted through each product's cost price, so it would be counted twice.</p>
  ${canEdit?`<form id="exf" class="formcard" novalidate><div class="stockrow"><label>Date<input id="exd" type="date" max="${esc(A().todayGD())}" value="${esc(A().todayGD())}"></label><label>Category<select id="exc">${CATS.map(c=>`<option>${c}</option>`).join('')}</select></label><label>Amount (EC$)<input id="exa" type="number" min="0.01" step="0.01" inputmode="decimal"></label></div>
  <label>Note (optional)<input id="exn" maxlength="120"></label><button class="btn" id="exs" type="submit">Add expense</button><div id="exm" class="notice" hidden role="alert"></div></form>`:'<p class="muted">Only the business owner can add or delete expenses.</p>'}
  ${rows.length?`<div class="tblw"><table><tr><th>Date</th><th>Category</th><th>Note</th><th>Amount</th>${canEdit?'<th></th>':''}</tr>${rows.map(x=>`<tr><td>${esc(x.spent_on)}</td><td>${esc(x.category)}</td><td>${esc(x.description||'')}</td><td>${money(x.amount_xcd)}</td>${canEdit?`<td><button class="btn ghost" type="button" data-del="${esc(x.id)}">Delete</button></td>`:''}</tr>`).join('')}</table></div>${rows.length>=200?'<p class="muted">Showing the newest 200 expenses; the profit and loss statement counts all of them.</p>':''}
  <p>${mk('excsv','Export CSV')}</p>`:empty('🧾','No expenses recorded yet.')}`;
  const again=()=>mount(el.closest('#anadv')||el,o);
  const ec=b.querySelector('#excsv');if(ec)ec.onclick=()=>dl('CC-expenses.csv',csv(['Date','Category','Note','Amount (EC$)'],rows.map(x=>[x.spent_on,x.category,x.description||'',x.amount_xcd]),[3]));
  b.querySelectorAll('[data-del]').forEach(x=>x.onclick=async()=>{if(!confirm('Delete this expense?'))return;x.disabled=true;const d=await sb.from('vendor_expenses').delete().eq('id',x.dataset.del);if(d.error){x.disabled=false;alert(d.error.message);return}again()});
  const f=b.querySelector('#exf');if(f)f.onsubmit=async ev=>{ev.preventDefault();const m=b.querySelector('#exm'),say=t=>{m.className='notice err';m.textContent=t;m.hidden=!t};
   const d=b.querySelector('#exd').value,amt=b.querySelector('#exa').value.trim();
   if(!A().validDate(d))return say('Choose a valid date.');if(d>A().todayGD())return say('The date cannot be in the future.');
   if(!(Number(amt)>0)||Number(amt)>10000000)return say('Enter an amount greater than 0.');
   const btn=b.querySelector('#exs');btn.disabled=true;
   const ins=await sb.from('vendor_expenses').insert({vendor_id:vendor.id,spent_on:d,category:b.querySelector('#exc').value,amount_xcd:Number(amt),description:b.querySelector('#exn').value.trim()||null});
   if(ins.error){say(/row-level security/.test(ins.error.message)?'Only the business owner on a Pro or Enterprise plan can add expenses.':ins.error.message);btn.disabled=false;return}
   again()};
 });

 // ---------- inventory ----------
 add('inventory',async b=>{
  const st=o._inv||(o._inv={lead:7,cover:14});
  const I=await call('vendor_inventory_report',{...a,p_lead_days:st.lead,p_cover_days:st.cover});
  const need=I.products.filter(p=>['out','reorder','soon'].includes(p.status));
  b.innerHTML=`<div class="kpis">${kpi('Stock value at cost',money(I.value_at_cost_xcd),I.products_without_cost?I.products_without_cost+' product'+(I.products_without_cost===1?'':'s')+' without a cost price':'all tracked products have a cost')}${kpi('Stock value at selling price',money(I.value_at_retail_xcd),I.units_in_stock+' units in stock')}${kpi('Stock turnover',I.turnover==null?'n/a':I.turnover+'x',I.turnover_annualised==null?'needs cost prices and stock':I.turnover_annualised+'x a year (approx.)')}${kpi('To order',String(need.length),'out, reorder now or order soon',need.length?'warn':'')}</div>
  <form class="stockrow aa-inv" id="invf" novalidate><label>Supplier delivery time (days)<input id="invl" type="number" min="0" max="90" step="1" value="${st.lead}"></label><label>Days of stock to keep<input id="invc" type="number" min="1" max="180" step="1" value="${st.cover}"></label><button class="btn alt" type="submit" style="align-self:end">Update</button></form><div id="invm" class="notice err" hidden role="alert"></div>
  ${I.untracked_products?`<div class="notice">${I.untracked_products} active product${I.untracked_products===1?' does':'s do'} not track stock, so ${I.untracked_products===1?'it is':'they are'} left out. Turn on stock tracking by entering a stock quantity on the product.</div>`:''}
  ${I.products.length?`<div class="tblw"><table><tr><th>Product</th><th>Stock</th><th>Sold (${I.days} days)</th><th>Per day</th><th>Days of stock</th><th>Status</th><th>Suggested order</th><th>Value at cost</th></tr>
  ${I.products.map(p=>{const s=STATUS[p.status]||[p.status,'mute'];return `<tr><td>${esc(p.name)}</td><td>${p.stock}</td><td>${p.sold}</td><td>${p.per_day}</td><td>${p.days_of_stock==null?'<span class="muted">n/a</span>':p.days_of_stock}</td><td>${pill(s[1],s[0])}</td><td>${p.suggested_order||''}</td><td>${p.value_at_cost_xcd==null?'<span class="muted">no cost</span>':money(p.value_at_cost_xcd)}</td></tr>`}).join('')}</table></div>`:empty('📦','No products with stock tracking yet. Enter a stock quantity on a product to track it.')}
  <p class="muted">Suggested order = items sold per day x (delivery days + days of stock to keep) - stock now. Turnover = cost of goods sold in the range / value of stock now (the system does not keep daily stock history, so this is approximate).</p>
  <p>${mk('ivcsv','Export CSV')} ${mk('ivpdf','Download reorder list (PDF)')}</p>${msgBox('ivm')}`;
  b.querySelector('#invf').onsubmit=ev=>{ev.preventDefault();const m=b.querySelector('#invm'),l=b.querySelector('#invl').value,c=b.querySelector('#invc').value;
   if(!(/^\d+$/.test(l)&&+l<=90))return(m.textContent='Delivery time must be a whole number from 0 to 90 days.',m.hidden=false);if(!(/^\d+$/.test(c)&&+c>=1&&+c<=180))return(m.textContent='Days of stock to keep must be a whole number from 1 to 180.',m.hidden=false);
   st.lead=+l;st.cover=+c;mount(el.closest('#anadv')||el,o)};
  b.querySelector('#ivcsv').onclick=()=>dl('CC-inventory-'+from+'_to_'+to+'.csv',csv(['Product','Stock','Cost price (EC$)','Selling price (EC$)','Sold in range','Per day','Days of stock','Status','Suggested order','Value at cost (EC$)','Value at selling price (EC$)'],I.products.map(p=>[p.name,p.stock,p.cost_price==null?'':p.cost_price,p.price_xcd,p.sold,p.per_day,p.days_of_stock==null?'':p.days_of_stock,(STATUS[p.status]||[p.status])[0],p.suggested_order,p.value_at_cost_xcd==null?'':p.value_at_cost_xcd,p.value_at_retail_xcd]),[2,3,9,10]));
  b.querySelector('#ivpdf').onclick=()=>pdf({title:'Reorder list',sub:'Inventory and reorder list',file:'CC-reorder-'+to,period:'Sales from '+from+' to '+to+' ('+I.days+' days, Grenada local days). Delivery time '+I.lead_days+' days, keep '+I.cover_days+' days of stock.',warn:'Suggestions from your own sales speed. Turnover is approximate.',
   kvs:[['Stock value at cost',money(I.value_at_cost_xcd)],['Stock value at selling price',money(I.value_at_retail_xcd)],['Stock turnover',I.turnover==null?'n/a':I.turnover+'x ('+(I.turnover_annualised==null?'n/a':I.turnover_annualised+'x a year')+')']],
   sections:[{h:'Products to order',table:{cols:[{t:'Product',w:.34},{t:'Stock',w:.1,align:'right'},{t:'Per day',w:.12,align:'right'},{t:'Days left',w:.14,align:'right'},{t:'Status',w:.15},{t:'Order',w:.15,align:'right'}],rows:need.map(p=>[p.name,String(p.stock),String(p.per_day),p.days_of_stock==null?'-':String(p.days_of_stock),(STATUS[p.status]||[p.status])[0],String(p.suggested_order)])}}]},b.querySelector('#ivpdf'),b.querySelector('#ivm2')||b.querySelector('#ivm'));
 });

 // ---------- customer lifetime value ----------
 add('clv',async b=>{
  const C=await call('vendor_clv_report',{...v1,p_limit:10});
  const SEG={champion:['Champions','3+ orders, last within 30 days'],loyal:['Loyal','2+ orders, last within 60 days'],new:['New','1 order in the last 30 days'],one_time:['One-time','1 order, 31 to 120 days ago'],at_risk:['At risk','2+ orders, last 61 to 120 days ago'],lapsed:['Lapsed','last order over 120 days ago']};
  const ORG={local:'Local number',overseas:'Overseas number',unknown:'Unknown'};
  if(!C.customers){b.innerHTML=empty('👥','No customers yet. This report fills in as orders arrive.');return}
  b.innerHTML=`<p class="muted">All-time, as of ${esc(C.as_of)} (Grenada). Only people who ordered from you. Names are the order contact names; account details are never shown.</p>
  <div class="kpis">${kpi('Average lifetime value',money(C.avg_clv_xcd),'spent per customer so far')}${kpi('Customers',String(C.customers),C.orders+' orders')}${kpi('Repeat customers',pct(C.repeat_rate_pct),'bought more than once')}${kpi('Average order',money(C.avg_order_xcd),num(C.avg_orders_per_customer).toFixed(1)+' orders per customer')}</div>
  <h5>Segments</h5>${hbars(C.segments.map(s=>({label:SEG[s.segment][0],v:s.customers,text:s.customers+' · '+money(s.revenue_xcd),tip:SEG[s.segment][0]+': '+s.customers+' customers, '+money(s.revenue_xcd)})),{aria:'Customers by segment'})}
  <div class="tblw"><table><tr><th>Segment</th><th>Rule</th><th>Customers</th><th>Revenue</th><th>Average value</th></tr>${C.segments.map(s=>`<tr><td>${esc(SEG[s.segment][0])}</td><td>${esc(SEG[s.segment][1])}</td><td>${s.customers}</td><td>${money(s.revenue_xcd)}</td><td>${s.avg_clv_xcd==null?'<span class="muted">n/a</span>':money(s.avg_clv_xcd)}</td></tr>`).join('')}</table></div>
  <h5>Local and overseas phone numbers</h5><div class="tblw"><table><tr><th>Phone number</th><th>Customers</th><th>Orders</th><th>Revenue</th><th>Average order</th></tr>${C.origins.map(s=>`<tr><td>${esc(ORG[s.origin])}</td><td>${s.customers}</td><td>${s.orders}</td><td>${money(s.revenue_xcd)}</td><td>${s.avg_order_xcd==null?'<span class="muted">n/a</span>':money(s.avg_order_xcd)}</td></tr>`).join('')}</table></div>
  <p class="muted">This is a guess from the phone number each customer gave (7 digits, or starting 473 or 1473, counts as local). A visitor can use a local SIM and a local can use an overseas number, so it does not prove who is a tourist.</p>
  <h5>Top customers by spend</h5><div class="tblw"><table><tr><th>#</th><th>Name</th><th>Orders</th><th>Spent</th><th>Last order</th><th>Segment</th></tr>${C.top.map(t=>`<tr><td>${t.rank}</td><td>${esc(t.name)}${t.phone_hint?` <small class="muted">${esc(t.phone_hint)}</small>`:''}</td><td>${t.orders}</td><td>${money(t.spent_xcd)}</td><td>${esc(t.last_order)} <small class="muted">(${t.days_since} days ago)</small></td><td>${esc(SEG[t.segment][0])}</td></tr>`).join('')}</table></div>
  <p>${mk('clcsv','Export CSV')}</p>`;
  b.querySelector('#clcsv').onclick=()=>dl('CC-customer-value-'+C.as_of+'.csv',csv(['Name','Phone hint','Orders','Spent (EC$)','First order','Last order','Days since last order','Segment','Phone number type'],C.top.map(t=>[t.name,t.phone_hint||'',t.orders,t.spent_xcd,t.first_order,t.last_order,t.days_since,SEG[t.segment][0],ORG[t.origin]]),[3])
   +'\r\n'+csv(['Segment','Customers','Revenue (EC$)','Average value (EC$)'],C.segments.map(s=>[SEG[s.segment][0],s.customers,s.revenue_xcd,s.avg_clv_xcd==null?'':s.avg_clv_xcd]),[2,3]).replace('\ufeff',''));
 });

 // ---------- accounting export ----------
 add('accounting',async b=>{
  b.innerHTML=`<p class="muted">Sales are grouped by day and payment method (like lines on a bank statement); expenses are listed one by one. Files are made in your browser and are not sent anywhere. Range: <b>${esc(from)}</b> to <b>${esc(to)}</b>.</p>
  <p>${mk('acq','QuickBooks CSV','btn')} ${mk('acx','Xero CSV','btn')} ${mk('acg','Generic journal CSV')}</p>${msgBox('acm')}
  <p class="muted">The QuickBooks and Xero files follow each program's standard bank-statement import layout (QuickBooks: Date, Description, Amount; Xero: *Date, *Amount, Payee, Description, Reference). They have not been tried against a live QuickBooks or Xero account: if an import screen complains, use the generic journal file or check the date format setting in the program.</p>`;
  const m=b.querySelector('#acm');let cache=null;
  const get=async()=>cache||(cache=await call('vendor_accounting_export',a));
  const PM={pay_on_pickup:'Pay on pickup',pay_on_delivery:'Pay on delivery',pay_with_wallet:'Wallet (test)'};
  const run=(id,fn)=>b.querySelector(id).onclick=async ev=>{const btn=ev.currentTarget;btn.disabled=true;m.hidden=true;
   try{const X=await get();if(!X.sales.length&&!X.expenses.length){m.className='notice';m.textContent='Nothing to export in this date range.';m.hidden=false}else{fn(X);m.className='notice ok';m.textContent='File created. '+(X.expenses_truncated?'Only the first '+X.limit+' expenses are included; choose a shorter range for the rest.':'');m.hidden=false}}
   catch(e){m.className='notice err';m.textContent=nice(e).msg||'Could not create the file';m.hidden=false}finally{btn.disabled=false}};
  const sd=s=>'Sales '+PM[s.method]+' ('+s.orders+' order'+(s.orders===1?'':'s')+')';
  run('#acq',X=>dl('CC-quickbooks-'+from+'_to_'+to+'.csv',csv(['Date','Description','Amount'],X.sales.map(s=>[mdy(s.day),sd(s),s.total_xcd]).concat(X.expenses.map(e=>[mdy(e.day),'Expense: '+e.category+(e.description?' - '+e.description:''),-num(e.amount_xcd)])),[2])));
  run('#acx',X=>dl('CC-xero-'+from+'_to_'+to+'.csv',csv(['*Date','*Amount','Payee','Description','Reference','Check Number'],X.sales.map(s=>[dmy(s.day),s.total_xcd,'Carriacou Connect customers',sd(s),'CC-'+s.day.replace(/-/g,'')+'-'+s.method,'']).concat(X.expenses.map(e=>[dmy(e.day),-num(e.amount_xcd),e.category,e.description||('Expense: '+e.category),'CC-EXP-'+e.day.replace(/-/g,''),''])),[1])));
  run('#acg',X=>dl('CC-journal-'+from+'_to_'+to+'.csv',csv(['Date','Account','Description','Debit (EC$)','Credit (EC$)','Reference'],X.sales.flatMap(s=>{const ref='CC-'+s.day.replace(/-/g,'')+'-'+s.method;return [[s.day,s.method==='pay_with_wallet'?'Wallet receivable':'Cash and bank',sd(s),s.total_xcd,'',ref],[s.day,'Sales revenue',sd(s),'',Math.round((num(s.total_xcd)-num(s.tax_xcd||0))*100)/100,ref]].concat(num(s.tax_xcd||0)>0?[[s.day,'Sales tax payable',sd(s),'',s.tax_xcd,ref]]:[])}).concat(X.expenses.flatMap(e=>{const ref='CC-EXP-'+e.day.replace(/-/g,'');return [[e.day,'Expense: '+e.category,e.description||'',e.amount_xcd,'',ref],[e.day,'Cash and bank',e.description||'Expense paid','',e.amount_xcd,ref]]})),[3,4])));
 });

 // ---------- benchmark ----------
 add('benchmark',async b=>{
  const B=await call('vendor_benchmark',a);
  if(!B.available){b.innerHTML=`<div class="notice">Not enough similar businesses yet. A comparison needs at least <b>${B.min_peers}</b> other Carriacou businesses in your main category${B.category?` (<b>${esc(B.category)}</b>)`:''} with sales in this period, so nobody can be identified. In this period you had ${B.yours?B.yours.orders:0} order${B.yours&&B.yours.orders===1?'':'s'} and ${money(B.yours?B.yours.revenue_xcd:0)} in sales. It fills in on its own as more businesses sell.</div>`;return}
  b.innerHTML=`<p class="muted">Compared with <b>${B.peer_group_size}</b> other businesses in <b>${esc(B.category)}</b> with sales in this period. Only the middle half and the median are shown; no business is named. The bar is the middle half of similar businesses, the line is the median, the gold dot is you.</p>
  ${B.metrics.map(m=>{const better=m.percentile==null?'':m.higher_is_better?m.percentile:100-m.percentile;return `<div class="aa-bm"><div class="aa-bmh"><b>${esc(m.label)}</b><span>You <b>${esc(String(m.yours==null?'n/a':m.yours))}</b> · typical ${esc(String(m.peer_p25))} to ${esc(String(m.peer_p75))} · median ${esc(String(m.peer_median))}</span></div>${range(m)}<small class="muted">${m.percentile==null?'No value for you in this period.':'You are ahead of about '+better+'% of similar businesses'+(m.higher_is_better?'':' (lower is better here)')+'.'}</small></div>`}).join('')}
  <p>${mk('bmcsv','Export CSV')}</p>`;
  b.querySelector('#bmcsv').onclick=()=>dl('CC-benchmark-'+from+'_to_'+to+'.csv',csv(['Measure','You','Similar: 25th percentile','Similar: median','Similar: 75th percentile','You are ahead of (%)'],B.metrics.map(m=>[m.label,m.yours==null?'':m.yours,m.peer_p25,m.peer_median,m.peer_p75,m.percentile==null?'':(m.higher_is_better?m.percentile:100-m.percentile)]),[1,2,3,4,5]));
 });

 // ---------- pricing ----------
 add('pricing',async b=>{
  const Pr=await call('vendor_pricing_insights',a);
  const ACT={raise_price:['Could raise price','good'],discount:['Could discount','warn'],hold:['Keep as is','mute']};
  const VER={lift:['Sales rose','good'],flat:['No clear change','mute'],down:['Sales fell','bad'],too_early:['Too early','mute'],no_baseline:['No earlier sales to compare','mute']};
  const rows=Pr.products;
  b.innerHTML=`<p class="muted">Suggestions from your own sales speed, stock and margin in <b>${esc(from)}</b> to <b>${esc(to)}</b>. Nothing is changed for you. A product could carry a higher price when it sells faster than 3 in 4 of your products and stock would run out within 14 days (needs 4 products with sales). It could take a discount when stock would last 90+ days, or it has not sold at all in a product older than 30 days; the safe maximum is half its margin, never above 20%.</p>
  ${rows.length?`<div class="tblw"><table><tr><th>Product</th><th>Price</th><th>Margin</th><th>Sold</th><th>Days of stock</th><th>Suggestion</th></tr>${rows.map(p=>{const s=ACT[p.action];return `<tr><td>${esc(p.name)}</td><td>${money(p.price_xcd)}</td><td>${p.margin_pct==null?'<span class="muted">no cost</span>':pct(p.margin_pct)}</td><td>${p.sold}</td><td>${p.days_of_stock==null?'<span class="muted">n/a</span>':p.days_of_stock}</td><td>${pill(s[1],s[0])}${p.action==='raise_price'?` <small>try ${money(p.suggested_price_xcd)}</small>`:''}${p.action==='discount'?` <small>${p.max_discount_pct!=null?'up to '+p.max_discount_pct+'%':'add a cost price to see a safe limit'}</small>`:''}</td></tr>`}).join('')}</table></div>`:empty('🏷️','No active products yet.')}
  <h5>Did your discount campaigns lift sales?</h5>
  ${Pr.campaigns.length?`<div class="tblw"><table><tr><th>Campaign</th><th>Ran</th><th>Orders</th><th>Discount given</th><th>Sales per day: before / during</th><th>Change</th></tr>${Pr.campaigns.map(c=>{const v=VER[c.verdict];return `<tr><td>${esc(c.name)}${c.code?` <small class="muted">${esc(c.code)}</small>`:''}</td><td>${esc(c.starts_on)} (${c.days_run} day${c.days_run===1?'':'s'})</td><td>${c.orders}</td><td>${money(c.discount_given_xcd)}</td><td>${c.revenue_per_day_before_xcd==null?'n/a':money(c.revenue_per_day_before_xcd)} / ${money(c.revenue_per_day_during_xcd)}</td><td>${pill(v[1],v[0])}${c.lift_pct!=null?` <small>${c.lift_pct>0?'+':''}${c.lift_pct}%</small>`:''}</td></tr>`}).join('')}</table></div>
  <p class="muted">Compares your total sales per day during the campaign with the 14 days before it. Things other than the campaign (holidays, weather, a visiting ship) also move sales, so treat this as a pointer, not proof.</p>`:empty('🎟️','No discount campaigns yet. Create one in the Campaigns tab.')}
  <p>${mk('prcsv','Export CSV')}</p>`;
  b.querySelector('#prcsv').onclick=()=>dl('CC-pricing-'+from+'_to_'+to+'.csv',csv(['Product','Price (EC$)','Cost (EC$)','Margin %','Sold','Per day','Stock','Days of stock','Suggestion','Suggested price (EC$)','Max discount %'],rows.map(p=>[p.name,p.price_xcd,p.cost_price==null?'':p.cost_price,p.margin_pct==null?'':p.margin_pct,p.sold,p.per_day,p.stock==null?'':p.stock,p.days_of_stock==null?'':p.days_of_stock,ACT[p.action][0],p.suggested_price_xcd==null?'':p.suggested_price_xcd,p.max_discount_pct==null?'':p.max_discount_pct]),[1,2,3,9]));
 });

 // ---------- fraud ----------
 add('fraud',async b=>{
  const days=o._fd||(o._fd=30);
  const Fm=await call('vendor_fraud_monitor',{...v1,p_days:days});
  const sec=(t,list,cols)=>list.length?`<h5>${esc(t)} <span class="aa-pill bad">${list.length}</span></h5><div class="tblw"><table><tr>${cols.map(c=>`<th>${esc(c[0])}</th>`).join('')}</tr>${list.map(x=>`<tr>${cols.map(c=>`<td>${c[1](x)}</td>`).join('')}</tr>`).join('')}</table></div>`:'';
  const who=x=>esc(x.name)+(x.phone_hint?` <small class="muted">${esc(x.phone_hint)}</small>`:'');
  b.innerHTML=`<form class="aa-fd"><label>Look back <select id="fdd">${[7,30,90].map(d=>`<option value="${d}" ${d===days?'selected':''}>${d} days</option>`).join('')}</select></label></form>
  <p class="muted">${esc(Fm.from)} to ${esc(Fm.to)} (Grenada). ${Fm.orders} order${Fm.orders===1?'':'s'}, ${Fm.refunded_orders} refunded${Fm.refund_rate_pct==null?'':' ('+pct(Fm.refund_rate_pct)+')'}, ${Fm.customer_cancelled_orders} cancelled by the customer. ${esc(Fm.chargeback_note)}</p>
  ${Fm.flag_count?`<div class="notice err">${Fm.flag_count} thing${Fm.flag_count===1?'':'s'} worth a look. A flag is a prompt to check, not proof of fraud.</div>`:'<div class="notice ok">Nothing unusual found in this period.</div>'}
  ${Fm.flag_refund_rate?`<div class="notice err"><b>High refund rate:</b> ${Fm.refunded_orders} refunds, ${pct(Fm.refund_rate_pct)} of orders (flagged at 3+ refunds and 10% or more).</div>`:''}
  ${sec('Customers who cancelled 3 or more of their own orders',Fm.customer_cancels,[['Customer',who],['Cancelled',x=>x.cancelled],['Value',x=>money(x.value_xcd)]])}
  ${sec('Large first orders (EC$100+ and 3x your average order)',Fm.big_first_orders,[['Customer',who],['Order',x=>esc(x.order)],['Total',x=>money(x.total_xcd)],['When',x=>esc(String(x.at).slice(0,10))]])}
  ${sec('One phone number used by 3 or more accounts',Fm.shared_phones,[['Phone',x=>esc(x.phone_hint)],['Accounts',x=>x.accounts],['Orders',x=>x.orders]])}
  ${sec('5 or more orders within an hour',Fm.order_bursts,[['Customer',x=>esc(x.name)],['Orders in an hour',x=>x.orders_in_an_hour]])}
  <p class="muted">Rules: 3+ customer-made cancellations, 3+ refunds making up 10%+ of orders, a first-ever order of EC$100+ that is 3x your average (last 90 days), one phone (last 7 digits) on 3+ accounts, 5+ orders from one customer within an hour.</p>
  <p>${mk('frcsv','Export CSV')}</p>`;
  b.querySelector('#fdd').onchange=e=>{o._fd=+e.target.value;mount(el.closest('#anadv')||el,o)};
  b.querySelector('#frcsv').onclick=()=>dl('CC-fraud-flags-'+Fm.to+'.csv',csv(['Flag','Customer','Phone hint','Detail'],
   Fm.customer_cancels.map(x=>['Repeat cancellations',x.name,x.phone_hint||'',x.cancelled+' cancelled, '+x.value_xcd+' EC$'])
   .concat(Fm.big_first_orders.map(x=>['Large first order',x.name,x.phone_hint||'',x.order+' '+x.total_xcd+' EC$']))
   .concat(Fm.shared_phones.map(x=>['Shared phone number',x.name,x.phone_hint,x.accounts+' accounts, '+x.orders+' orders']))
   .concat(Fm.order_bursts.map(x=>['Order burst',x.name,'',x.orders_in_an_hour+' orders in an hour']))
   .concat(Fm.flag_refund_rate?[['High refund rate','','',Fm.refunded_orders+' refunds, '+Fm.refund_rate_pct+'%']]:[])));
 });

 // ---------- credit readiness ----------
 add('credit',async b=>{
  const C=await call('vendor_credit_readiness',v1),f=C.facts;
  const BAND={strong:'Strong',building:'Building',early:'Early'};
  b.innerHTML=`<div class="aa-credit">${ring(C.score,C.band)}<div><p class="aa-band ${esc(C.band)}">${esc(BAND[C.band])}</p><p class="muted">A checklist score, not a credit score. No lender uses it automatically: print it and bring it with you. Last 12 months to ${esc(C.as_of)} (Grenada).</p></div></div>
  <div class="tblw"><table><tr><th>Check</th><th>Points</th><th>Your figure</th><th>How to improve</th></tr>${C.components.map(c=>`<tr><td>${esc(c.label)}</td><td><b>${c.points}</b> / ${c.max}</td><td>${c.value==null?'<span class="muted">not enough data</span>':esc(String(c.value))+' <small class="muted">'+esc(c.unit)+'</small>'}</td><td><small>${c.points>=c.max?'Full points':esc(c.tip)}</small></td></tr>`).join('')}</table></div>
  <h5>Key figures (last 12 months)</h5><div class="kpis">${kpi('Sales',money(f.revenue_12m_xcd),f.orders_12m+' orders, '+f.customers_12m+' customers')}${kpi('Average month',f.avg_monthly_revenue_xcd==null?'n/a':money(f.avg_monthly_revenue_xcd),f.completed_months+' completed month'+(f.completed_months===1?'':'s'))}${kpi('Net profit',money(f.net_profit_12m_xcd),'sales - cost of goods - expenses entered')}${kpi('Trading since',f.first_sale?esc(f.first_sale):'n/a',f.months_with_sales+' month'+(f.months_with_sales===1?'':'s')+' with sales')}</div>
  <p class="muted">70 or more is Strong, 40 to 69 Building, under 40 Early. Net profit only means something if costs and expenses are entered. This is a summary of your own records on Carriacou Connect; a lender will decide using its own rules.</p>
  <p>${mk('crcsv','Export CSV')} ${mk('crpdf','Download PDF')}</p>${msgBox('crm')}`;
  b.querySelector('#crcsv').onclick=()=>dl('CC-credit-readiness-'+C.as_of+'.csv',csv(['Check','Points','Maximum','Figure','Unit'],C.components.map(c=>[c.label,c.points,c.max,c.value==null?'':c.value,c.unit]).concat([['Total',C.score,100,'',BAND[C.band]]])));
  b.querySelector('#crpdf').onclick=()=>pdf({title:'Credit-readiness summary',sub:'Loan and credit-readiness summary',file:'CC-credit-readiness-'+C.as_of,period:'Last 12 months to '+C.as_of+' (Grenada local days)',warn:'A checklist score from records kept on Carriacou Connect. It is not a credit score and not financial advice; a lender decides using its own rules.',
   kvs:[['Readiness score',C.score+' / 100 ('+BAND[C.band]+')'],['Sales, last 12 months',money(f.revenue_12m_xcd)],['Orders / customers',f.orders_12m+' / '+f.customers_12m],['Average completed month',f.avg_monthly_revenue_xcd==null?'n/a':money(f.avg_monthly_revenue_xcd)],['Net profit (sales - cost of goods - expenses entered)',money(f.net_profit_12m_xcd)],['Trading on Connect since',f.first_sale||'n/a'],['Licence',f.licence_number?f.licence_number+(f.licence_expiry?' (expires '+f.licence_expiry+')':''):'not saved']],
   sections:[{h:'Checklist',table:{cols:[{t:'Check',w:.3},{t:'Points',w:.12,align:'right'},{t:'Figure',w:.58}],rows:C.components.map(c=>[c.label,c.points+' / '+c.max,c.value==null?'not enough data':c.value+' '+c.unit])}},{h:'Sales by month',table:{cols:[{t:'Month',w:.4},{t:'Sales',w:.6,align:'right'}],rows:C.monthly.map(m=>[mlabel(m.m),money(m.rev)])}}]},b.querySelector('#crpdf'),b.querySelector('#crm'));
 });

 // ---------- data export ----------
 add('export',async b=>{
  b.innerHTML=`<p class="muted">Every order in <b>${esc(from)}</b> to <b>${esc(to)}</b>, including cancelled and refunded ones, with a status column. Customer phone numbers and addresses are not included. Up to 20,000 orders per file. API access is not available yet.</p>
  <p>${mk('dxo','Orders CSV','btn')} ${mk('dxi','Order lines CSV','btn')} ${mk('dxp','POS charges CSV','btn')}</p>${msgBox('dxm')}`;
  const m=b.querySelector('#dxm');let cache=null;
  const run=(id,fn)=>b.querySelector(id).onclick=async ev=>{const btn=ev.currentTarget;btn.disabled=true;m.hidden=true;
   try{cache=cache||await call('vendor_data_export',a);if(!cache.orders.length&&!(cache.pos_charges||[]).length){m.className='notice';m.textContent='No orders in this date range.';m.hidden=false}else{await fn(cache);m.className='notice ok';m.textContent='File created.'+(cache.truncated?' Only the first '+cache.limit+' orders are included; choose a shorter range.':'');m.hidden=false}}
   catch(e){m.className='notice err';m.textContent=nice(e).msg||'Could not create the file';m.hidden=false}finally{btn.disabled=false}};
  const GD=new Intl.DateTimeFormat('en-GB',{timeZone:TZ,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});
  run('#dxo',async X=>{const PD={};try{const ns=X.orders.map(x=>x.order);for(let i=0;i<ns.length;i+=200){const q=await sb.from('orders').select('*').eq('vendor_id',vendor.id).in('order_number',ns.slice(i,i+200));(q.data||[]).forEach(o=>PD[o.order_number]=o)}}catch(e){}
   const pd=x=>{const o=PD[x.order];if(!o||o.status==='cancelled'||o.payment_status==='refunded')return ['',''];const t=Number(o.total_xcd)||0,p=o.payment_status==='paid'?t:(Number(o.amount_paid_xcd)||0);return [p.toFixed(2),Math.max(0,t-p).toFixed(2)]};
   dl('CC-orders-'+from+'_to_'+to+'.csv',csv(['Order','Date (Grenada)','Status','Payment status','Payment method','Fulfilment','Customer','Subtotal (EC$)','Discount (EC$)','Delivery (EC$)','Total (EC$)','VAT (EC$)','VAT rate %','VAT included in prices','Campaign code','Amount paid (EC$)','Balance due (EC$)'],X.orders.map(x=>[x.order,GD.format(new Date(x.at)),x.status,x.payment_status,x.method,x.fulfilment,x.customer||'',x.subtotal_xcd,x.discount_xcd,x.delivery_xcd,x.total_xcd,x.tax_xcd==null?'':x.tax_xcd,x.tax_rate_pct==null?'':x.tax_rate_pct,x.tax_inclusive==null?'':(x.tax_inclusive?'yes':'no'),x.campaign_code||'',...pd(x)]),[7,8,9,10,11,15,16]))});
  run('#dxi',X=>dl('CC-order-lines-'+from+'_to_'+to+'.csv',csv(['Order','Product','Quantity','Unit price (EC$)','Line total (EC$)','Unit cost (EC$)'],X.items.map(x=>[x.order,x.product,x.quantity,x.unit_price_xcd,x.line_total_xcd,x.unit_cost_xcd==null?'':x.unit_cost_xcd]),[3,4,5])));
  run('#dxp',X=>dl('CC-pos-charges-'+from+'_to_'+to+'.csv',csv(['Charge','Date (Grenada)','Note','Total paid (EC$)','VAT (EC$)','VAT rate %','VAT included in price'],(X.pos_charges||[]).map(x=>[x.code,GD.format(new Date(x.at)),x.note||'',x.total_xcd,x.tax_xcd==null?'':x.tax_xcd,x.tax_rate_pct==null?'':x.tax_rate_pct,x.tax_inclusive==null?'':(x.tax_inclusive?'yes':'no')]),[3,4])));
 });

 // ---------- customize (Enterprise) ----------
 if(prem){
  const cu=el.querySelector('#aa-cu'),cp=el.querySelector('#aa-cp');
  cu.onclick=()=>{
   let order=keys.slice();DEFAULT.forEach(k=>{if(!order.includes(k))order.push(k)});let on=new Set(keys);
   const draw=()=>{cp.hidden=false;cp.innerHTML=`<h5>Choose and order your reports</h5><ul class="aa-cl">${order.map((k,i)=>`<li><label class="chk"><input type="checkbox" data-k="${k}" ${on.has(k)?'checked':''} ${o.isOwner?'':'disabled'}> ${esc(META[k].t)} <span class="aa-tag ${META[k].adv?'adv':'prem'}">${META[k].adv?'Advanced':'Premium'}</span></label>${o.isOwner?`<span><button class="btn ghost" type="button" data-up="${i}" aria-label="Move up" ${i?'':'disabled'}>▲</button><button class="btn ghost" type="button" data-dn="${i}" aria-label="Move down" ${i<order.length-1?'':'disabled'}>▼</button></span>`:''}</li>`).join('')}</ul>
   ${o.isOwner?`<p><button class="btn" type="button" id="cps">Save layout</button> <button class="btn alt" type="button" id="cpr">Show everything in the usual order</button> <button class="btn ghost" type="button" id="cpx">Close</button></p>`:'<p class="muted">Only the business owner can change the layout.</p><p><button class="btn ghost" type="button" id="cpx">Close</button></p>'}<div id="cpm" class="notice" hidden role="alert"></div>`;
    cp.querySelectorAll('[data-k]').forEach(c=>c.onchange=()=>{c.checked?on.add(c.dataset.k):on.delete(c.dataset.k)});
    cp.querySelectorAll('[data-up]').forEach(x=>x.onclick=()=>{const i=+x.dataset.up;[order[i-1],order[i]]=[order[i],order[i-1]];draw()});
    cp.querySelectorAll('[data-dn]').forEach(x=>x.onclick=()=>{const i=+x.dataset.dn;[order[i+1],order[i]]=[order[i],order[i+1]];draw()});
    cp.querySelector('#cpx').onclick=()=>{cp.hidden=true};
    const save=async w=>{const m=cp.querySelector('#cpm');m.className='notice';m.textContent='Saving…';m.hidden=false;
     const ex=await sb.from('vendor_dashboard_prefs').select('vendor_id').eq('vendor_id',vendor.id).maybeSingle();
     const r=ex.data?await sb.from('vendor_dashboard_prefs').update({widgets:w}).eq('vendor_id',vendor.id):await sb.from('vendor_dashboard_prefs').insert({vendor_id:vendor.id,widgets:w});
     if(r.error){m.className='notice err';m.textContent=/row-level security/.test(r.error.message)?'Only the business owner on the Enterprise plan can save the layout.':/does not exist|schema cache/.test(r.error.message)?'Saving needs advanced_analytics.sql to be run in Supabase first.':r.error.message;return}
     mount(el,o)};
    const s=cp.querySelector('#cps');if(s)s.onclick=()=>save(order.filter(k=>on.has(k)));
    const r=cp.querySelector('#cpr');if(r)r.onclick=()=>save(DEFAULT.slice());
   };draw()};
 }
 await Promise.all(jobs);
}
CC.analyticsAdv={mount,pairs,hbars,range,ring,META,DEFAULT};
})();
