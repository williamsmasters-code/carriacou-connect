// Delivery & tax tab (v1.5), owner and sub-admin only. Needs supabase/tax_delivery.sql. Plans are TEST MODE: nothing is billed or paid out.
// Every value is checked again by the database function vendor_set_checkout_settings; the page only makes it friendly.
(function(){
const CC=window.CC;if(!CC)return;
const esc=CC.esc;
const AREAS=['Hillsborough',"L'Esterie",'Windward','Harvey Vale','Belair','Bogles','Mount Pleasant','Dumfries'];
const nice=m=>{m=(m&&m.message)||String(m||'');return /Could not find the function|schema cache|does not exist/i.test(m)?'Delivery and tax settings are not switched on yet (tax_delivery.sql has not been run in Supabase).':m};
const money=n=>'EC$'+(Math.round((Number(n)||0)*100)/100).toFixed(2);
function mount(box,o){
 const {sb,vendor}=o;let S=null,zones=[],busy=false;
 const say=(t,ok)=>{const e=box.querySelector('#cdm');if(!e)return;e.className='notice '+(ok?'ok':'err');e.textContent=t||'';e.hidden=!t;if(t)e.scrollIntoView({block:'nearest'})};
 async function load(){
  box.innerHTML='<p class="muted">Loading settings…</p>';
  const r=await sb.rpc('vendor_get_checkout_settings',{p_vendor:vendor.id});
  if(r.error){box.innerHTML='<div class="notice err">'+esc(nice(r.error))+'</div>';return}
  S=r.data;zones=(S.delivery_zones||[]).map(z=>({name:z.name,fee:String(z.fee)}));draw();
 }
 function example(){
  const g=id=>box.querySelector(id);if(!g('#cdex'))return;
  const reg=g('#cdreg').checked,incl=g('#cdincl').checked,rateTxt=g('#cdrate').value.trim(),rate=reg?(rateTxt===''?Number(S.platform_default_vat_pct):Number(rateTxt)):0;
  const model=box.querySelector('input[name=cdm]:checked').value;let fee=model==='zones'?(zones.length?Number(zones[0].fee):0):Number(g('#cdfee').value)||0;
  const fo=g('#cdfree').value.trim();if(fo!==''&&100>=Number(fo))fee=0;
  const del=g('#cddel').checked;const base=100+(del?fee:0);
  const tax=rate>0?Math.round((incl?base*rate/(100+rate):base*rate/100)*100)/100:0;const total=base+(incl?0:tax);
  g('#cdex').innerHTML='<b>Example</b> (an illustration of the rules, not a real order): goods EC$100.00'+(del?' + delivery '+money(fee)+(model==='zones'&&zones.length?' (first area in your list)':''):' picked up')+(rate>0?', VAT '+rate+'% '+(incl?'already inside the prices = '+money(tax):'added on top = '+money(tax)):', no tax')+' → customer pays <b>'+money(total)+'</b>.';
 }
 function zoneRows(){return zones.map((z,i)=>`<div class="zrow"><label class="zl">Area name<input data-zn="${i}" maxlength="40" value="${esc(z.name)}" placeholder="Area name"></label><label class="zl">Fee (EC$)<input data-zf="${i}" type="number" min="0" max="500" step="0.01" inputmode="decimal" value="${esc(z.fee)}"></label><button type="button" class="btn ghost sm" data-zd="${i}" aria-label="Remove area ${esc(z.name)}">Remove</button></div>`).join('')}
 function draw(){
  box.innerHTML=`<div id="cdm" class="notice" hidden role="alert"></div>
  <form id="cdf" class="formcard" novalidate>
  <h3>Pickup and delivery</h3>
  <label class="chk"><input type="checkbox" id="cdpick" ${S.pickup_enabled?'checked':''}> Offer <b>pickup</b> (always free)</label>
  <label class="chk"><input type="checkbox" id="cddel" ${S.delivery_enabled?'checked':''}> Offer <b>delivery</b></label>
  <div id="cddelbox">
   <h4>Delivery fee</h4>
   <label class="chk"><input type="radio" name="cdm" value="flat" ${S.delivery_model==='flat'?'checked':''}> One flat fee for every delivery</label>
   <label class="chk"><input type="radio" name="cdm" value="zones" ${S.delivery_model==='zones'?'checked':''}> A fee for each area (customer picks their area)</label>
   <div id="cdflat"><label>Flat delivery fee (EC$)<input id="cdfee" type="number" min="0" max="500" step="0.01" inputmode="decimal" value="${esc(S.delivery_flat_fee)}"></label></div>
   <div id="cdzones"><div id="cdzl">${zoneRows()}</div>
    <p><button type="button" class="btn alt sm" id="cdza">Add an area</button> <button type="button" class="btn ghost sm" id="cdzc">Add Carriacou areas</button></p>
    <p class="muted"><small>Up to 20 areas. "Add Carriacou areas" adds ${AREAS.join(', ')} (only the ones missing) using your flat fee; then edit each fee.</small></p></div>
   <label>Free delivery on orders of at least (EC$, optional)<input id="cdfree" type="number" min="0.01" max="100000" step="0.01" inputmode="decimal" value="${S.free_over_xcd==null?'':esc(S.free_over_xcd)}" placeholder="No free-delivery threshold"></label>
   <p class="muted"><small>The threshold is checked against the goods total after any promo discount. Leave it empty to always charge the fee.</small></p>
  </div>
  <h3>Tax (VAT)</h3>
  <label class="chk"><input type="checkbox" id="cdreg" ${S.vat_registered?'checked':''}> My business is <b>VAT registered</b> and charges VAT</label>
  <div id="cdvat">
   <div class="stockrow"><label>VAT rate (%)<input id="cdrate" type="number" min="0" max="30" step="0.01" inputmode="decimal" value="${S.vat_rate_pct==null?'':esc(S.vat_rate_pct)}" placeholder="Platform default: ${esc(Number(S.platform_default_vat_pct))}"></label>
   <label>VAT number (optional)<input id="cdvn" maxlength="40" value="${esc(S.vat_number||'')}" placeholder="Shown on order PDFs"></label></div>
   <label class="chk"><input type="radio" name="cdi" id="cdincl" value="1" ${S.prices_include_tax?'checked':''}> My prices <b>already include</b> VAT (tax is shown inside the total)</label>
   <label class="chk"><input type="radio" name="cdi" id="cdexcl" value="0" ${S.prices_include_tax?'':'checked'}> My prices <b>exclude</b> VAT (tax is added on top at checkout)</label>
   <p class="muted"><small>Leave the rate empty to follow the Carriacou Connect default (currently ${esc(Number(S.platform_default_vat_pct))}%). Delivery fees are taxed like your goods. Tax is worked out once per order and rounded to the cent. Each order keeps the rate it was placed with, so changing this later never changes old orders.</small></p>
  </div>
  <div id="cdex" class="notice" role="note"></div>
  <button class="btn" id="cdsave" type="submit">Save settings</button>
  <p class="muted"><small>${S.saved?'Settings saved '+esc(CC.fdate(S.updated_at))+'. ':'Nothing saved yet: customers currently see free pickup and free delivery and no tax. '}Changes are signed in your Team activity log. Summary for your records, not tax advice: check rates with the Inland Revenue Division.</small></p>
  </form>`;
  wire();sync();
 }
 function readZones(){box.querySelectorAll('[data-zn]').forEach(e=>{zones[+e.dataset.zn].name=e.value});box.querySelectorAll('[data-zf]').forEach(e=>{zones[+e.dataset.zf].fee=e.value})}
 function sync(){const g=id=>box.querySelector(id);
  g('#cddelbox').hidden=!g('#cddel').checked;g('#cdvat').hidden=!g('#cdreg').checked;
  const zm=box.querySelector('input[name=cdm]:checked').value==='zones';g('#cdflat').hidden=zm;g('#cdzones').hidden=!zm;example()}
 function wire(){
  const f=box.querySelector('#cdf');
  f.addEventListener('input',()=>{readZones();example()});f.addEventListener('change',sync);
  box.querySelector('#cdza').onclick=()=>{readZones();if(zones.length>=20)return say('At most 20 areas.');zones.push({name:'',fee:box.querySelector('#cdfee').value||'0'});box.querySelector('#cdzl').innerHTML=zoneRows();wireZ();example()};
  box.querySelector('#cdzc').onclick=()=>{readZones();const have=new Set(zones.map(z=>z.name.trim().toLowerCase()));const fee=box.querySelector('#cdfee').value||'0';AREAS.forEach(a=>{if(!have.has(a.toLowerCase())&&zones.length<20)zones.push({name:a,fee})});box.querySelector('#cdzl').innerHTML=zoneRows();wireZ();example()};
  wireZ();
  f.onsubmit=async e=>{e.preventDefault();if(busy)return;readZones();say('');
   const g=id=>box.querySelector(id),model=box.querySelector('input[name=cdm]:checked').value;
   const pick=g('#cdpick').checked,del=g('#cddel').checked;
   if(!pick&&!del)return say('Turn on pickup, delivery or both.');
   const num=(v,l,min,max)=>{if(v==='')return null;const n=Number(v);if(!isFinite(n)||n<min||n>max||Math.round(n*100)!==n*100)throw new Error(l+' must be between '+min+' and '+max+', with at most two decimals.');return n};
   let st;
   try{
    const ff=num(g('#cdfee').value.trim()||'0','The delivery fee',0,500),fo=num(g('#cdfree').value.trim(),'Free delivery over',0.01,100000);
    const reg=g('#cdreg').checked,vr=num(g('#cdrate').value.trim(),'The VAT rate',0,30);
    const zs=model==='zones'?zones.map(z=>({name:z.name.trim(),fee:num(String(z.fee).trim()===''?'0':String(z.fee).trim(),'The fee for "'+z.name.trim()+'"',0,500)})):zones.filter(z=>z.name.trim()).map(z=>({name:z.name.trim(),fee:Number(z.fee)||0}));
    if(model==='zones'){if(!zs.length)throw new Error('Add at least one delivery area, or choose a flat fee.');if(zs.some(z=>!z.name))throw new Error('Every area needs a name (or remove the empty row).')}
    st={pickup_enabled:pick,delivery_enabled:del,delivery_model:model,delivery_flat_fee:ff,free_over_xcd:fo,delivery_zones:zs,vat_registered:reg,vat_rate_pct:vr,prices_include_tax:g('#cdincl').checked,vat_number:g('#cdvn').value.trim()||null};
   }catch(x){return say(x.message)}
   busy=true;const btn=g('#cdsave');btn.disabled=true;
   const r=await sb.rpc('vendor_set_checkout_settings',{p_vendor:vendor.id,p_settings:st});
   busy=false;
   if(r.error){say(nice(r.error));btn.disabled=false;return}
   S=r.data;zones=(S.delivery_zones||[]).map(z=>({name:z.name,fee:String(z.fee)}));draw();say('Saved. New orders use these settings; old orders are not changed.',true);
  };
 }
 function wireZ(){box.querySelectorAll('[data-zd]').forEach(b=>b.onclick=()=>{readZones();zones.splice(+b.dataset.zd,1);box.querySelector('#cdzl').innerHTML=zoneRows();wireZ();example()})}
 load();
}
CC.checkoutSettings={mount};
})();
