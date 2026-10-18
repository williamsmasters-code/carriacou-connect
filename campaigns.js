// Campaigns tab (v1.1, every plan). Needs supabase/standard_analytics.sql. Owner and sub-admins only (products_edit).
// A campaign has optional discount code + percent, dates, and an optional "featured" banner on the marketplace home page.
// The discount is applied by the database when the order is placed (place_order_with_code); nothing here can change a price.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc,TZ='America/Grenada';
const fmtD=new Intl.DateTimeFormat('en-CA',{timeZone:TZ,year:'numeric',month:'2-digit',day:'2-digit'});
const today=()=>fmtD.format(new Date());
const addDays=(s,n)=>{const [y,m,d]=s.split('-').map(Number);const t=new Date(Date.UTC(y,m-1,d+n));return t.toISOString().slice(0,10)};
const nice=m=>{m=(m&&m.message)||String(m||'');
 if(/Could not find|schema cache|does not exist|relation .*campaigns/i.test(m))return 'Campaigns are not switched on yet (standard_analytics.sql has not been run in Supabase). See README.txt.';
 if(/campaigns_code_uq|duplicate key/.test(m))return 'That code is already used by another campaign. Choose a different code.';
 if(/campaigns_discount_needs_code/.test(m))return 'A percent discount needs a code. Add a code, or clear the percent.';
 if(/campaigns_dates_ok/.test(m))return 'The end date must be on or after the start date, and the campaign can last at most 366 days.';
 if(/campaigns_code_check/.test(m))return 'The code must be 3 to 20 letters or digits, no spaces.';
 if(/orders_campaign_fk|foreign key/.test(m))return 'This campaign already has orders, so it cannot be deleted. Pause it instead.';
 if(/at most 100 campaigns/.test(m))return 'You have 100 campaigns already. Delete old ones first.';
 if(/row-level security/.test(m))return 'You do not have permission to change campaigns for this business.';
 return m};
const status=c=>{const t=today();return !c.active?['paused','Paused']:c.ends_on<t?['ended','Ended']:c.starts_on>t?['sched','Scheduled']:['run','Running']};
function mount(box,o){
 const {sb,vendor}=o;let list=[],editing=null,counts={};
 const say=(m,ok)=>{const e=box.querySelector('#cpmsg');if(!e)return;e.className='notice '+(ok?'ok':'err');e.textContent=m||'';e.hidden=!m;if(m)e.scrollIntoView({block:'nearest'})};
 async function load(){
  box.innerHTML='<p class="muted">Loading campaigns…</p>';
  const r=await sb.from('campaigns').select('id,name,headline,code,discount_pct,starts_on,ends_on,featured,active,max_uses,one_per_customer,created_at').eq('vendor_id',vendor.id).order('starts_on',{ascending:false}).order('created_at',{ascending:false});
  if(r.error){box.innerHTML='<div class="notice err">'+esc(nice(r.error))+'</div>';return}
  list=r.data||[];draw();
 }
 function draw(){
  const e=editing,t=today();
  const v=k=>e?e[k]:null;
  box.innerHTML=`<div id="cpmsg" class="notice" hidden role="alert"></div>
  <p class="muted">Run a promotion: give shoppers a <b>code</b> to type at checkout (optionally a percent off), show a <b>banner</b> on the marketplace home page, and see the sales each campaign brought in under Analytics (Standard plan and up). A code only discounts <b>your</b> items in the order. One code per order.</p>
  <form id="cpf" class="formcard" novalidate><h3>${e?'Edit campaign':'New campaign'}</h3>
   <label>Campaign name<input id="cpn" maxlength="80" required value="${esc(v('name')||'')}" placeholder="e.g. Independence Week"></label>
   <label>Banner headline <small>(optional, shown on the home page when featured; max 140)</small><input id="cph" maxlength="140" value="${esc(v('headline')||'')}" placeholder="e.g. 10% off all spice. Use code SPICE10"></label>
   <div class="stockrow"><label>Discount code <small>(optional, 3-20 letters/digits)</small><input id="cpc" maxlength="20" autocapitalize="characters" value="${esc(v('code')||'')}" placeholder="SPICE10"></label>
   <label>Percent off <small>(optional, needs a code)</small><input id="cpp" type="number" min="0.01" max="90" step="0.01" inputmode="decimal" value="${v('discount_pct')==null?'':esc(v('discount_pct'))}" placeholder="10"></label></div>
   <div class="stockrow"><label>Starts<input id="cps" type="date" required value="${esc(v('starts_on')||t)}"></label><label>Ends<input id="cpe" type="date" required value="${esc(v('ends_on')||addDays(t,7))}"></label></div>
   <div class="stockrow"><label>Limit total uses <small>(optional)</small><input id="cpm" type="number" min="1" max="1000000" step="1" inputmode="numeric" value="${v('max_uses')==null?'':esc(v('max_uses'))}" placeholder="no limit"></label>
   <label class="chk" style="align-self:end"><input type="checkbox" id="cpo" ${v('one_per_customer')?'checked':''}> One use per customer</label></div>
   <label class="chk"><input type="checkbox" id="cpf1" ${v('featured')?'checked':''}> Show a banner on the marketplace home page while it runs</label>
   <label class="chk"><input type="checkbox" id="cpa" ${e?(e.active?'checked':''):'checked'}> Active</label>
   <button class="btn" id="cpsave">${e?'Save changes':'Create campaign'}</button> ${e?'<button type="button" class="btn alt" id="cpcancel">Cancel</button>':''}</form>
  <h3>Your campaigns</h3>
  ${list.length?`<div class="cplist">${list.map(c=>{const [k,l]=status(c);return `<div class="cprow"><div class="cpmain"><b>${esc(c.name)}</b> <span class="cpst s-${k}">${l}</span>${c.featured?' <span class="cpst s-feat">Banner</span>':''}
    <div class="muted">${esc(c.starts_on)} to ${esc(c.ends_on)}${c.code?' · code <b>'+esc(c.code)+'</b>':' · no code'}${c.discount_pct!=null?' · '+Number(c.discount_pct)+'% off':c.code?' · tracking only (no discount)':''}${c.max_uses?' · max '+c.max_uses+' uses':''}${c.one_per_customer?' · one per customer':''}</div></div>
    <div class="cpact"><button class="btn ghost sm" data-e="${esc(c.id)}">Edit</button><button class="btn ghost sm" data-t="${esc(c.id)}">${c.active?'Pause':'Resume'}</button><button class="btn ghost sm" data-d="${esc(c.id)}">Delete</button></div></div>`}).join('')}</div>`
  :'<div class="empty small"><div class="empty-ic" aria-hidden="true">📣</div><p>No campaigns yet. Create your first one above.</p></div>'}`;
  box.querySelector('#cpf').onsubmit=save;
  const cn=box.querySelector('#cpcancel');if(cn)cn.onclick=()=>{editing=null;draw()};
  box.querySelectorAll('[data-e]').forEach(b=>b.onclick=()=>{editing=list.find(x=>x.id===b.dataset.e)||null;draw();box.querySelector('#cpf').scrollIntoView({block:'start'})});
  box.querySelectorAll('[data-t]').forEach(b=>b.onclick=async()=>{const c=list.find(x=>x.id===b.dataset.t);const r=await sb.from('campaigns').update({active:!c.active}).eq('id',c.id);if(r.error)say(nice(r.error));else await load()});
  box.querySelectorAll('[data-d]').forEach(b=>b.onclick=async()=>{const c=list.find(x=>x.id===b.dataset.d);if(!confirm('Delete campaign "'+c.name+'"?'))return;const r=await sb.from('campaigns').delete().eq('id',c.id);if(r.error)say(nice(r.error));else{editing=null;await load()}});
 }
 async function save(ev){
  ev.preventDefault();const g=id=>box.querySelector(id);
  const name=g('#cpn').value.trim(),code=g('#cpc').value.trim().toUpperCase().replace(/\s+/g,''),pct=g('#cpp').value.trim(),s=g('#cps').value,e=g('#cpe').value,mx=g('#cpm').value.trim();
  if(name.length<2)return say('Give the campaign a name.');
  if(code&&!/^[A-Z0-9]{3,20}$/.test(code))return say('The code must be 3 to 20 letters or digits, no spaces.');
  if(pct!==''&&!code)return say('A percent discount needs a code. Add a code, or clear the percent.');
  if(pct!==''&&!(Number(pct)>0&&Number(pct)<=90))return say('Percent off must be more than 0 and at most 90.');
  if(!/^\d{4}-\d{2}-\d{2}$/.test(s)||!/^\d{4}-\d{2}-\d{2}$/.test(e)||e<s)return say('Choose a start date and an end date that is on or after it.');
  if(mx!==''&&!(Number.isInteger(Number(mx))&&Number(mx)>=1))return say('Total uses must be a whole number, 1 or more.');
  const row={name,headline:g('#cph').value.trim()||null,code:code||null,discount_pct:pct===''?null:Number(pct),starts_on:s,ends_on:e,max_uses:mx===''?null:Number(mx),one_per_customer:g('#cpo').checked,featured:g('#cpf1').checked,active:g('#cpa').checked};
  const b=g('#cpsave');b.disabled=true;
  const r=editing?await sb.from('campaigns').update(row).eq('id',editing.id):await sb.from('campaigns').insert({...row,vendor_id:vendor.id});
  if(r.error){say(nice(r.error));b.disabled=false;return}
  editing=null;await load();say(row.code?'Saved. Shoppers can enter '+row.code+' at checkout.':'Saved.',true);
 }
 load();
}
CC.campaigns={mount};
})();
