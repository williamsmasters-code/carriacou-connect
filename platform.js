// Platform-level analytics + settings for the operator (v1.2, TEST MODE). Platform admins only; every number comes from
// admin_pa_* database functions that re-check the admin role. Inline SVG charts, no libraries. Needs supabase/platform_analytics.sql.
// Privacy: aggregates and business names only; customers appear only as masked ids.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,AN=()=>CC.analytics;
const money=n=>'EC$'+(Number(n)||0).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});
const MON=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const monLab=m=>MON[+m.slice(5,7)-1]+" '"+m.slice(2,4);
const CATL={food:'Food',crafts:'Crafts',fashion:'Fashion',beauty:'Beauty',sea:'Sea & fishing',home:'Home',unknown:'Unknown (product removed)'};
const RULE={large_order:'Unusually large order',order_velocity:'Many orders in a short time',large_transfer:'Unusually large wallet transfer',transfer_velocity:'Many wallet transfers in a short time',cancel_refund:'Many cancelled or refunded orders',failed_codes:'Repeated failed code lookups'};
const PRESETS=[['week','This week'],['month','This month'],['last30','Last 30 days'],['last90','Last 90 days'],['custom','Custom range']];
const missing=m=>/Could not find the function|schema cache|does not exist|PGRST202|404/.test(m||'');
const kpi=(l,v,sub,c)=>`<div class="kpi ${c||''}"><span>${esc(l)}</span><b>${v}</b>${sub?`<small>${sub}</small>`:''}</div>`;
const empty=(ic,t)=>`<div class="empty small"><div class="empty-ic" aria-hidden="true">${ic}</div><p>${esc(t)}</p></div>`;
const niceMax=max=>{const p=Math.pow(10,Math.floor(Math.log10(max)));const f=max/p;return (f<=1?1:f<=2?2:f<=5?5:10)*p};
const num=n=>Number(n)||0;

// ---- inline SVG charts ----
function bars(items,o){ // items [{label,v,tip,hl}]
 o=o||{};const max=Math.max(...items.map(i=>i.v),0);if(!max)return empty('📊',o.empty||'Nothing to show for this period yet.');
 const W=640,H=200,L=48,B=26,T=10,iw=W-L-6,ih=H-B-T,n=items.length,bw=iw/n,gap=Math.min(5,bw*.25),nice=niceMax(max),fmt=o.fmt||(v=>Math.round(v).toLocaleString('en-US'));
 let s=`<svg class="an-chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(o.aria||'Bar chart')}" preserveAspectRatio="xMidYMid meet">`;
 [0,.5,1].forEach(f=>{const y=T+ih-ih*f;s+=`<line x1="${L}" x2="${W-6}" y1="${y}" y2="${y}" class="gl"/><text x="${L-6}" y="${y+4}" text-anchor="end" class="ax">${esc(fmt(nice*f))}</text>`});
 items.forEach((p,i)=>{const h=Math.max(p.v>0?2:0,ih*p.v/nice),x=L+i*bw+gap/2;
  s+=`<rect x="${x.toFixed(2)}" y="${(T+ih-h).toFixed(2)}" width="${Math.max(1,bw-gap).toFixed(2)}" height="${h.toFixed(2)}" rx="${Math.min(4,bw/3).toFixed(1)}" class="bar${p.hl?' hl':''}${o.alt?' alt':''}"><title>${esc(p.tip||p.label)}</title></rect>`;
  const every=o.every||(n>16?Math.ceil(n/6):1);if(i%every===0||i===n-1&&n<=16)s+=`<text x="${(L+i*bw+bw/2).toFixed(1)}" y="${H-8}" text-anchor="middle" class="ax">${esc(p.label)}</text>`});
 return s+'</svg>';
}
function hbars(items,fmt){ // [{label,v,sub}]
 const max=Math.max(...items.map(i=>i.v),0);if(!max)return empty('🧺','No sales in this period yet.');
 const LW=150,W=640,rh=30,H=items.length*rh+6,bw=W-LW-110;
 let s=`<svg class="an-chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Revenue by category" preserveAspectRatio="xMidYMid meet">`;
 items.forEach((p,i)=>{const y=3+i*rh,w=Math.max(p.v>0?3:0,bw*p.v/max);
  s+=`<text x="${LW-8}" y="${y+18}" text-anchor="end" class="ax lbl">${esc(p.label)}</text><rect x="${LW}" y="${y+4}" width="${w.toFixed(1)}" height="${rh-10}" rx="6" class="bar${i===0?' hl':''}"><title>${esc(p.label)}: ${esc(fmt(p.v))}</title></rect><text x="${(LW+w+6).toFixed(1)}" y="${y+18}" class="ax val">${esc(fmt(p.v))}</text>`});
 return s+'</svg>';
}
const TCOL={lite:'#7a8e96',standard:'#17a2a2',plus:'#0b7285',pro:'#f4b942',enterprise:'#ff6b4a'};
function stack(tiers){ // plan mix as one stacked bar
 const tot=tiers.reduce((s,t)=>s+t.vendors,0);if(!tot)return empty('🏪','No businesses yet.');
 const W=640,H=64,L=0;let x=0,s=`<svg class="an-chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Plan mix: ${esc(tiers.map(t=>t.label+' '+t.vendors).join(', '))}" preserveAspectRatio="xMidYMid meet">`;
 tiers.forEach(t=>{if(!t.vendors)return;const w=W*t.vendors/tot;s+=`<rect x="${x.toFixed(1)}" y="6" width="${Math.max(1,w-2).toFixed(1)}" height="30" rx="8" fill="${TCOL[t.tier]||'#999'}"><title>${esc(t.label)}: ${t.vendors} (${Math.round(t.vendors*100/tot)}%)</title></rect>`;if(w>40)s+=`<text x="${(x+w/2).toFixed(1)}" y="26" text-anchor="middle" class="ax" style="fill:#fff;font-weight:700">${t.vendors}</text>`;x+=w});
 let lx=0;tiers.forEach(t=>{s+=`<rect x="${lx}" y="46" width="10" height="10" rx="3" fill="${TCOL[t.tier]||'#999'}"/><text x="${lx+14}" y="55" class="ax">${esc(t.label)}</text>`;lx+=14+t.label.length*7+18});
 return s+'</svg>';
}

// ---- CSV ----
const csvText=(headers,rows,numCols)=>{const c=AN().csvCell;return '\ufeff'+[headers.map(h=>c(h)).join(',')].concat(rows.map(r=>r.map((v,i)=>numCols&&numCols.includes(i)&&v!==''&&v!=null?c(String(Number(v)),true):c(v)).join(','))).join('\r\n')+'\r\n'};
const csvBtn=(id,label)=>`<button type="button" class="btn ghost sm pa-csv" data-csv="${id}" aria-label="Download ${esc(label)} as CSV">Download CSV</button>`;
const nice=e=>{const m=(e&&e.message)||String(e||'');return missing(m)?{off:true}:{msg:m}};
const offBox='<div class="notice">Platform analytics is not switched on yet. In Supabase, open the SQL Editor and run <code>supabase/platform_analytics.sql</code> (see README.txt), then refresh.</div>';

let seq=0;const state={preset:'last30',from:null,to:null};

async function mountAnalytics(el,sb){
 const my=++seq,A=AN(),today=A.todayGD();
 const rg=()=>{const r=A.ranges(today);r.last90=[A.addDays(today,-89),today];return r};
 if(state.preset!=='custom'){const r=rg();[state.from,state.to]=r[state.preset]||r.last30}else if(!state.from){[state.from,state.to]=rg().last30}
 const head=()=>`<div class="ofilter an-presets" role="group" aria-label="Date range">${PRESETS.map(([k,l])=>`<button type="button" data-p="${k}" class="${state.preset===k?'on':''}">${esc(l)}</button>`).join('')}</div>
  <form class="an-custom" id="pacust" ${state.preset==='custom'?'':'hidden'}><label>From<input type="date" id="pafrom" value="${esc(state.from)}" max="${today}"></label><label>To<input type="date" id="pato" value="${esc(state.to)}" max="${today}"></label><button class="btn alt" type="submit">Apply</button></form>
  <p class="muted an-range">Showing <b>${esc(state.from)}</b> to <b>${esc(state.to)}</b> (Grenada days, America/Grenada)</p><div id="pamsg" class="notice err" hidden role="alert"></div>`;
 el.innerHTML=CC.TESTBANNER.replace('play money, not real funds','play money and estimates only: no real billing, no money is moved')+'<h3>Platform analytics</h3><p class="muted">Island-wide totals across all businesses (sample businesses are left out). Aggregates and business names only; customers show as masked ids.</p><div id="pabox"><p class="muted">Loading…</p></div>';
 const box=el.querySelector('#pabox');
 function wire(){
  box.querySelectorAll('[data-p]').forEach(b=>b.onclick=()=>{const k=b.dataset.p;state.preset=k;if(k!=='custom'){[state.from,state.to]=rg()[k];load()}else{box.querySelector('#pacust').hidden=false;box.querySelectorAll('[data-p]').forEach(x=>x.classList.toggle('on',x.dataset.p==='custom'))}});
  const f=box.querySelector('#pacust');if(f)f.onsubmit=e=>{e.preventDefault();const a=box.querySelector('#pafrom').value,z=box.querySelector('#pato').value,m=box.querySelector('#pamsg');
   const err=!A.validDate(a)||!A.validDate(z)?'Choose both a start and an end date.':z<a?'The end date is before the start date.':z>today?'The end date cannot be in the future.':(Date.parse(z)-Date.parse(a))/864e5>731?'Choose a range of two years or less.':'';
   if(err){m.textContent=err;m.hidden=false;return}state.from=a;state.to=z;state.preset='custom';load()}}
 async function load(){
  box.innerHTML=head()+'<p class="muted">Loading…</p>';wire();
  const a={p_from:state.from,p_to:state.to};
  const [ov,gr,pl,ct,vn,fl]=await Promise.all([sb.rpc('admin_pa_overview',a),sb.rpc('admin_pa_growth',a),sb.rpc('admin_pa_plans'),sb.rpc('admin_pa_categories',a),sb.rpc('admin_pa_vendors',{...a,p_limit:10}),sb.rpc('admin_pa_flags',a)]);
  if(my!==seq)return;
  const bad=[ov,gr,pl,ct,vn,fl].find(r=>r.error);
  if(bad){const n=nice(bad.error);box.innerHTML=head()+(n.off?offBox:'<div class="notice err">Could not load platform analytics: '+esc(n.msg)+'</div>');wire();return}
  const O=ov.data,G=gr.data,P=pl.data,C=ct.data.categories||[],V=vn.data,F=fl.data,W=O.wallet,fee=O.fee;
  // daily chart (weeks above 92 days)
  let pts=(O.daily||[]).map(d=>({label:d.day.slice(5),v:num(d.gmv_xcd),n:d.orders,tip:d.day+': '+money(d.gmv_xcd)+', '+d.orders+' order'+(d.orders==1?'':'s')}));
  if(pts.length>92){const w=[];for(let i=0;i<pts.length;i+=7){const g=pts.slice(i,i+7);const v=g.reduce((s,x)=>s+x.v,0);w.push({label:g[0].label,v,tip:'Week of '+g[0].label+': '+money(v)})}pts=w}
  const pend=num(P.pending_requests);
  const csvs={};
  csvs.daily=[['Day (Grenada)','Orders','GMV (EC$)','Wallet volume (EC$, test money)'],(O.daily||[]).map(d=>[d.day,d.orders,num(d.gmv_xcd).toFixed(2),num(d.wallet_xcd).toFixed(2)]),[1,2,3]];
  csvs.growth=[['Month','New vendors','New consumers','Active vendors','Upgrades','Downgrades'],(G.months||[]).map(m=>[m.month.slice(0,7),m.new_vendors,m.new_consumers,m.active_vendors,m.upgrades,m.downgrades]),[1,2,3,4,5]];
  csvs.plans=[['Plan','Businesses','Placeholder price (EC$/month)','Price is a placeholder','Estimated monthly revenue (EC$, test)'],(P.tiers||[]).map(t=>[t.label,t.vendors,num(t.price_xcd).toFixed(2),t.is_placeholder?'yes':'no',num(t.est_monthly_xcd).toFixed(2)]),[1,2,4]];
  csvs.categories=[['Category','Orders','Units','Revenue (EC$)'],C.map(x=>[CATL[x.category]||x.category,x.orders,x.units,num(x.revenue_xcd).toFixed(2)]),[1,2,3]];
  csvs.vendors=[['Business','Plan','Orders','GMV (EC$)','Average order (EC$)','Share of GMV (%)'],(V.top||[]).map(x=>[x.name,CC.TIER_LABEL[x.tier]||x.tier,x.orders,num(x.gmv_xcd).toFixed(2),num(x.avg_order_xcd).toFixed(2),x.share_pct==null?'':x.share_pct]),[2,3,4,5]];
  csvs.flags=[['Rule','Severity','Masked id','Reference','Business','Value','Threshold','When','Detail'],(F.flags||[]).map(x=>[RULE[x.rule]||x.rule,x.severity,x.subject||'',x.ref||'',x.vendor||'',x.value,x.threshold,x.at||'',x.detail||'']),[5,6]];
  box._csv=csvs;
  let taxCard='';try{const tx=await sb.rpc('admin_pa_tax_summary',a);if(my!==seq)return;if(!tx.error&&tx.data){const T=tx.data;
   taxCard=`<h3 class="pa-sec">Tax and delivery</h3><div class="an-card"><div class="kpis">${kpi('Tax collected',money(T.tax_collected_xcd),T.taxed_orders+' taxed order'+(T.taxed_orders==1?'':'s')+' of '+T.sales_orders)}${kpi('Delivery fees',money(T.delivery_fees_xcd),'in GMV')}${kpi('GMV before tax',money(T.goods_net_of_tax_xcd),'GMV '+money(T.gmv_xcd)+' includes tax and delivery')}${kpi('VAT-registered businesses',T.vat_registered_vendors,'default rate '+Number(T.default_vat_pct)+'%')}</div>
   <p class="muted">Tax collected = the tax saved on each order at checkout (${money(T.tax_inside_prices_xcd)} was already inside prices, ${money(T.tax_added_on_top_xcd)} was added on top). ${T.orders_without_tax_record?T.orders_without_tax_record+' order'+(T.orders_without_tax_record==1?' from before v1.5 has':'s from before v1.5 have')+' no tax record and '+(T.orders_without_tax_record==1?'is':'are')+' not counted. ':''}Change the default rate in <a href="#settings" data-go="settings">Settings</a>. Summary for records, not official tax advice.</p></div>`}}catch(e){}
  const g=G.churn||{};
  box.innerHTML=head()+`
  <div class="kpis">${kpi('Island GMV',money(O.gmv_xcd),'sales orders, excl. cancelled and refunded')}${kpi('Orders',O.sales_orders,O.orders_placed+' placed in total')}${kpi('Average order',money(O.avg_order_xcd),(O.vendors_with_sales)+' business'+(O.vendors_with_sales==1?'':'es')+' selling')}${kpi('Wallet volume',money(W.volume_xcd),'TEST money: orders, POS, transfers')}${kpi('Platform fee (estimate)',money(fee.fee_xcd),'at '+Number(fee.current_rate_pct)+'% now · nothing is charged')}${kpi('Cancelled / refunded',O.cancelled_orders+' / '+O.refunded_orders,money(num(O.cancelled_xcd)+num(O.refunded_xcd))+' not counted in GMV','mute')}</div>
  <div class="an-card"><div class="pa-h"><h4>GMV per ${(O.daily||[]).length>92?'week':'day'}</h4>${csvBtn('daily','daily totals')}</div>${bars(pts,{aria:'Island GMV per day',fmt:v=>Math.round(v).toLocaleString('en-US'),empty:'No sales in this period yet.'})}</div>
  <div class="an-grid"><div class="an-card"><h4>Wallet activity <span class="pp pp-unpaid">TEST MONEY</span></h4><table><tr><th>Kind</th><th>Count</th><th>EC$</th></tr>
   <tr><td>Order payments</td><td>${W.order_payments}</td><td>${money(W.order_payments_xcd)}</td></tr><tr><td>POS charges</td><td>${W.pos_charges}</td><td>${money(W.pos_xcd)}</td></tr><tr><td>Person-to-person transfers</td><td>${W.transfers}</td><td>${money(W.transfers_xcd)}</td></tr>
   <tr><td>Refunds</td><td>${W.refunds}</td><td>${money(W.refunds_xcd)}</td></tr><tr><td>Test top-ups (play money issued)</td><td>${W.topups}</td><td>${money(W.topups_xcd)}</td></tr></table>
   <p class="muted">Volume = order payments + POS + transfers. Top-ups and refunds are not volume.</p></div>
   <div class="an-card"><h4>Platform fee (estimate)</h4><p class="pa-big">${money(fee.fee_xcd)}</p><p class="muted">On ${money(fee.eligible_xcd)} of wallet-paid orders and POS charges (${fee.eligible_items} item${fee.eligible_items==1?'':'s'}). Each item uses the rate in force when it was paid. Current rate ${Number(fee.current_rate_pct)}% (change it in <a href="#settings" data-go="settings">Settings</a>). Cash orders are not counted. Nothing is charged or moved.</p></div></div>
  ${taxCard}
  <h3 class="pa-sec">Growth</h3>
  <div class="kpis">${kpi('Businesses',G.vendors_total,'+'+G.vendors_new+' new in range')}${kpi('Active businesses',G.vendors_active,'with a sale in range')}${kpi('Consumers',G.consumers_total,'+'+G.consumers_new+' new in range')}${kpi('Active consumers',G.consumers_active,'with a purchase in range')}</div>
  <div class="an-grid"><div class="an-card"><div class="pa-h"><h4>New businesses per month</h4>${csvBtn('growth','monthly growth')}</div>${bars((G.months||[]).map(m=>({label:monLab(m.month),v:m.new_vendors,tip:monLab(m.month)+': '+m.new_vendors+' new'})),{aria:'New businesses per month',every:2,empty:'No new businesses in the last 12 months.'})}</div>
   <div class="an-card"><h4>New consumers per month</h4>${bars((G.months||[]).map(m=>({label:monLab(m.month),v:m.new_consumers,tip:monLab(m.month)+': '+m.new_consumers+' new'})),{aria:'New consumers per month',every:2,alt:true,empty:'No new consumers in the last 12 months.'})}</div></div>
  <div class="an-card"><h4>Active businesses per month</h4>${bars((G.months||[]).map(m=>({label:monLab(m.month),v:m.active_vendors,tip:monLab(m.month)+': '+m.active_vendors+' active'})),{aria:'Active businesses per month',every:2,empty:'No sales in the last 12 months.'})}<p class="muted">Months shown are the 12 months up to the end of the chosen range. Active = at least one sale (not cancelled or refunded) that month.</p></div>
  <h3 class="pa-sec">Plans, revenue estimate and churn</h3>
  <div class="an-card"><div class="pa-h"><h4>Plan mix</h4>${csvBtn('plans','plan mix')}</div>${stack(P.tiers||[])}
   <table><tr><th>Plan</th><th>Businesses</th><th>Price / month</th><th>Est. monthly revenue</th></tr>${(P.tiers||[]).map(t=>`<tr><td>${esc(t.label)}</td><td>${t.vendors}</td><td>${money(t.price_xcd)}${t.is_placeholder?' <span class="pp pp-unpaid">placeholder</span>':''}</td><td>${money(t.est_monthly_xcd)}</td></tr>`).join('')}
   <tr><th>Total</th><th>${P.vendors_total}</th><th></th><th>${money(P.est_monthly_revenue_xcd)}</th></tr></table>
   <p class="muted"><b>Test-mode estimate.</b> ${P.prices_are_placeholders?'Some prices are placeholders, not real prices. ':''}Nobody is billed. Edit prices in <a href="#settings" data-go="settings">Settings</a>. ${pend?pend+' upgrade request'+(pend==1?'':'s')+' waiting on the Plans tab. ':''}${P.approved_last_30d} upgrade${P.approved_last_30d==1?'':'s'} approved in the last 30 days.</p></div>
  <div class="an-card"><h4>Churn in this range</h4><div class="kpis"><div class="kpi mute"><span>Downgraded</span><b>${g.downgraded_vendors}</b><small>businesses moved to a smaller plan</small></div><div class="kpi mute"><span>Removed</span><b>${g.removed_businesses}</b><small>businesses deleted (from the audit log)</small></div><div class="kpi"><span>Upgrades</span><b>${g.upgrades}</b></div><div class="kpi"><span>Churn rate</span><b>${g.churn_pct==null?'n/a':g.churn_pct+'%'}</b><small>of ${g.vendors_at_start} businesses at the start</small></div></div>
   <p class="muted">Downgrades come from plan changes in the audit log; removed businesses are dated by their last audit entry, so that date is approximate.</p></div>
  <h3 class="pa-sec">Category demand</h3>
  <div class="an-card"><div class="pa-h"><h4>Revenue by category</h4>${csvBtn('categories','categories')}</div>${hbars(C.map(x=>({label:CATL[x.category]||x.category,v:num(x.revenue_xcd)})),money)}
   ${C.length?`<table><tr><th>Category</th><th>Orders</th><th>Units</th><th>Revenue</th></tr>${C.map(x=>`<tr><td>${esc(CATL[x.category]||x.category)}</td><td>${x.orders}</td><td>${x.units}</td><td>${money(x.revenue_xcd)}</td></tr>`).join('')}</table>`:''}
   <p class="muted">Line totals before campaign discounts; an order with several categories counts once in each.</p></div>
  <h3 class="pa-sec">Businesses</h3>
  <div class="an-card"><div class="pa-h"><h4>Top businesses by GMV</h4>${csvBtn('vendors','top businesses')}</div>${(V.top||[]).length?`<table><tr><th>Business</th><th>Plan</th><th>Orders</th><th>GMV</th><th>Average</th><th>Share</th></tr>${V.top.map(x=>`<tr><td>${esc(x.name)}</td><td>${esc(CC.TIER_LABEL[x.tier]||x.tier)}</td><td>${x.orders}</td><td>${money(x.gmv_xcd)}</td><td>${money(x.avg_order_xcd)}</td><td>${x.share_pct==null?'':x.share_pct+'%'}</td></tr>`).join('')}</table>`:empty('🏆','No sales in this period yet.')}</div>
  <div class="an-card"><h4>Low-activity businesses</h4>${(V.low_activity||[]).length?`<table><tr><th>Business</th><th>Plan</th><th>Orders in range</th><th>Products</th><th>Last order</th></tr>${V.low_activity.slice(0,25).map(x=>`<tr><td>${esc(x.name)}</td><td>${esc(CC.TIER_LABEL[x.tier]||x.tier)}</td><td>${x.orders_in_range}</td><td>${x.products}</td><td>${x.last_order_at?esc(CC.fdate(x.last_order_at)):'never'}</td></tr>`).join('')}</table>`:empty('🌴','Every business has activity in this range.')}
   <p class="muted">Rule: at most ${V.low_activity_rule.max_orders} order${V.low_activity_rule.max_orders==1?'':'s'} in the range, and the business is at least ${V.low_activity_rule.min_age_days} days old.</p></div>
  <h3 class="pa-sec">Fraud and anomaly flags</h3>
  <div class="an-card"><div class="pa-h"><h4>Flags in this range <span class="nbadge">${F.count}</span></h4>${csvBtn('flags','flags')}</div>
   ${F.flags.length?`<div class="tblwrap"><table class="admtab"><tr><th>Severity</th><th>Rule</th><th>Who</th><th>Detail</th><th>When</th></tr>${F.flags.map(x=>`<tr><td><span class="sev sev-${esc(x.severity)}">${esc(x.severity)}</span></td><td>${esc(RULE[x.rule]||x.rule)}</td><td><code>${esc(x.subject||'')}</code>${x.ref?'<small>order '+esc(x.ref)+'</small>':''}${x.vendor?'<small>'+esc(x.vendor)+'</small>':''}</td><td>${esc(x.detail||'')}<small>threshold ${esc(x.threshold)}</small></td><td>${x.at?esc(CC.fdate(x.at)):''}</td></tr>`).join('')}</table></div>${F.truncated?'<p class="muted">Showing the first 200 flags. Choose a shorter range to see the rest.</p>':''}`:empty('✅','Nothing unusual in this range.')}
   <p class="muted">${esc(F.note)} Thresholds are in <a href="#settings" data-go="settings">Settings</a>. Failed code lookups are only kept for about a day.</p></div>`;
  wire();
  box.querySelectorAll('[data-csv]').forEach(b=>b.onclick=()=>{const [h,r,n]=box._csv[b.dataset.csv];A.download('CC-platform-'+b.dataset.csv+'-'+state.from+'_to_'+state.to+'.csv',csvText(h,r,n))});
  box.querySelectorAll('[data-go]').forEach(a=>a.onclick=e=>{e.preventDefault();location.hash='#'+a.dataset.go;window.dispatchEvent(new HashChangeEvent('hashchange'))});
 }
 await load();
}

async function mountSettings(el,sb){
 const my=++seq;let msg='',mok=true;
 async function load(){
  const r=await sb.rpc('admin_pa_settings');if(my!==seq)return;
  if(r.error){const n=nice(r.error);el.innerHTML=n.off?offBox:'<div class="notice err">'+esc(n.msg)+'</div>';return}
  const S=r.data;let V=null;try{const vr=await sb.rpc('admin_vat_settings');if(!vr.error)V=vr.data}catch(e){}
  if(my!==seq)return;
  el.innerHTML=CC.TESTBANNER.replace('play money, not real funds','estimates only: nothing here charges or moves money')+(msg?`<div class="notice ${mok?'ok':'err'}" role="alert">${esc(msg)}</div>`:'')+`
  <h3>Platform fee</h3><div class="an-card"><form id="fee" class="pa-form" novalidate><label>Fee rate (% of each wallet-paid order or POS charge)<input id="feev" type="number" step="0.01" min="0" max="30" value="${esc(S.fee_rate_pct)}" inputmode="decimal"></label><button class="btn alt" type="submit">Save rate</button></form>
   <p class="muted">Default 0%. The fee is only an <b>estimate shown in analytics</b>: no fee is deducted and no money moves. A new rate applies from the moment you save it; earlier periods keep the rate that applied then.</p>
   <details><summary>Rate history</summary><ul class="auditlist">${S.fee_history.map(h=>`<li><b>${Number(h.rate_pct)}%</b> from ${esc(h.effective_from.startsWith('2000-01-01')?'the start':CC.fdate(h.effective_from))}</li>`).join('')}</ul></details></div>
  ${V?`<h3>Default VAT rate</h3><div class="an-card"><form id="vat" class="pa-form" novalidate><label>Default VAT rate (%)<input id="vatv" type="number" step="0.01" min="${esc(V.min)}" max="${esc(V.max)}" value="${esc(V.default_vat_pct)}" inputmode="decimal"></label><label>Reason for the change<input id="vatr" maxlength="300" placeholder="e.g. Budget announcement"></label><button class="btn alt" type="submit">Save VAT rate</button></form>
   <p class="muted">Allowed ${esc(V.min)} to ${esc(V.max)}%. Used at checkout for VAT-registered businesses that did not set their own rate (${V.vendors_using_default} of ${V.registered_vendors} VAT-registered business${V.registered_vendors==1?'':'es'} use it). It applies to <b>new orders only</b>; every order keeps the rate it was placed with. Grenada's standard VAT rate is 15%. Every change needs a reason and is logged.</p>
   <details><summary>Change history</summary>${V.history.length?'<ul class="auditlist">'+V.history.map(h=>`<li><b>${Number(h.from)}% to ${Number(h.to)}%</b> on ${esc(CC.fdate(h.at))}: ${esc(h.reason||'')}</li>`).join('')+'</ul>':'<p class="muted">No changes yet. The starting rate is 15%.</p>'}</details></div>`:''}
  <h3>Plan prices (for the revenue estimate)</h3><div class="an-card"><div class="notice">These are <b>placeholder</b> prices until you set them. No real billing exists; the numbers only feed the test-mode revenue estimate.</div>
   <table class="admtab"><tr><th>Plan</th><th>EC$ per month</th><th></th></tr>${S.tier_prices.map(t=>`<tr><td>${esc(t.label)} ${t.is_placeholder?'<span class="pp pp-unpaid">placeholder</span>':'<span class="pp pp-paid">set</span>'}</td><td><input type="number" step="0.01" min="0" max="100000" value="${esc(t.monthly_price_xcd)}" data-price="${esc(t.tier)}" aria-label="Monthly price for ${esc(t.label)}" inputmode="decimal"></td><td><button class="btn sm" data-saveprice="${esc(t.tier)}">Save</button></td></tr>`).join('')}</table></div>
  <h3>Flag thresholds</h3><div class="an-card"><table class="admtab"><tr><th>Rule</th><th>Value</th><th></th></tr>${S.flag_config.map(f=>`<tr><td>${esc(f.label)}<small>allowed ${esc(f.min)} to ${esc(f.max)}</small></td><td><input type="number" step="1" min="${esc(f.min)}" max="${esc(f.max)}" value="${esc(f.value)}" data-flag="${esc(f.key)}" aria-label="${esc(f.label)}" inputmode="numeric"></td><td><button class="btn sm" data-saveflag="${esc(f.key)}">Save</button></td></tr>`).join('')}</table>
   <p class="muted">Flags are simple rules, not proof of wrongdoing. A value of twice the threshold or more is marked high.</p></div>`;
  const call=async(fn,args,ok)=>{el.querySelectorAll('button').forEach(b=>b.disabled=true);const x=await sb.rpc(fn,args);msg=x.error?(nice(x.error).off?'Not switched on yet.':x.error.message):ok;mok=!x.error;await load()};
  el.querySelector('#fee').onsubmit=e=>{e.preventDefault();const v=el.querySelector('#feev').value;if(v===''||isNaN(Number(v))){msg='Enter a number between 0 and 30.';mok=false;load();return}call('admin_pa_set_fee',{p_rate:Number(v)},'Fee rate saved (estimate only).')};
  const vf=el.querySelector('#vat');if(vf)vf.onsubmit=e=>{e.preventDefault();const v=el.querySelector('#vatv').value,why=el.querySelector('#vatr').value.trim();if(v===''||isNaN(Number(v))){msg='Enter a number between '+V.min+' and '+V.max+'.';mok=false;load();return}if(why.length<3){msg='Give a reason for the change (at least 3 characters).';mok=false;load();return}call('admin_set_default_vat',{p_rate:Number(v),p_reason:why},'Default VAT rate saved. New orders use it; old orders keep their rate.')};
  el.querySelectorAll('[data-saveprice]').forEach(b=>b.onclick=()=>{const v=el.querySelector('[data-price="'+b.dataset.saveprice+'"]').value;if(v===''||isNaN(Number(v))){msg='Enter a price.';mok=false;load();return}call('admin_pa_set_tier_price',{p_tier:b.dataset.saveprice,p_price:Number(v)},'Price saved.')});
  el.querySelectorAll('[data-saveflag]').forEach(b=>b.onclick=()=>{const v=el.querySelector('[data-flag="'+b.dataset.saveflag+'"]').value;if(v===''||isNaN(Number(v))){msg='Enter a number.';mok=false;load();return}call('admin_pa_set_flag',{p_key:b.dataset.saveflag,p_value:Number(v)},'Threshold saved.')});
 }
 await load();
}
CC.platform={mountAnalytics,mountSettings,bars,hbars,stack,csvText};
})();
