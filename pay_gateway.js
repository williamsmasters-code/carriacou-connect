// v1.20 card payments: provider interface + MOCK provider (TEST MODE, no real money). Server side: supabase/payments_mock.sql.
// v1.21.1: expiry auto-inserts MM/YY slash as you type; card number groups in 4s (spaces stripped before tokenize).
// The flows (checkout, order pages, refunds, admin) only call CC.payments.*. A real processor (WiPay, a bank gateway) replaces
// the provider object below (its hosted card fields return a token) without touching the flows.
// SECURITY: the full card number and the CVC never leave this page. tokenize() turns them into a token + brand + last 4 +
// expiry; only those are sent to Carriacou Connect, and the server refuses anything that looks like a card number or CVC.
(function(){
const C=window.CC;if(!C)return;const esc=C.esc;
const CFG=window.CCONNECT_CONFIG||{};
const BANNER='<div class="testbanner paytest" role="note"><b>TEST MODE – no real money.</b> Use a test card: 4242 4242 4242 4242 (approved), 4000 0000 0000 0002 (declined), 4000 0000 0000 9995 (insufficient funds), 4000 0000 0000 0069 (expired). Any future expiry and any 3 digits.</div>';
const digits=s=>String(s||'').replace(/\D/g,'');
// Expiry typist: digits only, max MM/YY. A first digit of 2-9 becomes 0X/. Paste of 1228, 12/28 or 12 / 2028 -> 12/28.
// Backspace over the slash drops the slash without immediately putting it back (so the field does not get stuck).
function expDigits(raw){let d=digits(raw);if(d.length>=5&&/^(20|21)\d{2}$/.test(d.slice(-4))){const mm=d.slice(0,-4).padStart(2,'0').slice(-2);d=mm+d.slice(-2)}return d.slice(0,4)}
function formatExp(raw,opts){const o=opts||{};let d=expDigits(raw);if(!o.noPad&&d.length===1&&d[0]>='2'&&d[0]<='9')d='0'+d;if(d.length>=2&&o.slash!==false)return d.slice(0,2)+'/'+d.slice(2);return d}
function formatPan(raw){return digits(raw).slice(0,19).replace(/(\d{4})(?=\d)/g,'$1 ')}
function caretAfterDigits(fmt,n){if(n<=0)return 0;let seen=0;for(let i=0;i<fmt.length;i++){if(/\d/.test(fmt[i])){seen++;if(seen===n)return i+1}}return fmt.length}
function setExp(el,raw,opts){const next=formatExp(raw,opts);const dig=expDigits(next);const pos=caretAfterDigits(next,el.selectionStart==null?dig.length:digits((el.value||'').slice(0,el.selectionStart)).length);el.value=next;try{el.setSelectionRange(pos,pos)}catch(e){}}
function setPan(el){const old=el.value||'',pos=el.selectionStart||0,before=digits(old.slice(0,pos)).length,next=formatPan(old);el.value=next;try{el.setSelectionRange(caretAfterDigits(next,before),caretAfterDigits(next,before))}catch(e){}}
function enhanceCardFields(root){
  const box=root&&root.querySelector?root:document;
  box.querySelectorAll('#ccexp').forEach(el=>{
    if(el.dataset.ccExp==='1')return;el.dataset.ccExp='1';
    el.setAttribute('inputmode','numeric');el.setAttribute('autocomplete','cc-exp');el.setAttribute('maxlength','5');el.setAttribute('placeholder','MM/YY');el.setAttribute('aria-label',el.getAttribute('aria-label')||'Expiry Date');
    el.addEventListener('keydown',e=>{if(e.key!=='Backspace'||e.metaKey||e.ctrlKey||e.altKey)return;const a=el.selectionStart,b=el.selectionEnd;if(a==null||a!==b||a<1||el.value[a-1]!=='/')return;e.preventDefault();const raw=el.value.slice(0,a-1)+el.value.slice(b);el.value=formatExp(raw,{slash:expDigits(raw).length>2,noPad:true});const n=digits(el.value.slice(0,Math.max(0,a-1))).length;try{el.setSelectionRange(caretAfterDigits(el.value,n),caretAfterDigits(el.value,n))}catch(x){}});
    el.addEventListener('paste',e=>{e.preventDefault();const t=(e.clipboardData||window.clipboardData).getData('text')||'';el.value=formatExp(t,{slash:true});try{el.setSelectionRange(el.value.length,el.value.length)}catch(x){}});
    el.addEventListener('input',e=>{const del=e.inputType&&e.inputType.indexOf('delete')===0;el.value=formatExp(el.value,{slash:!del||expDigits(el.value).length>2,noPad:!!del});});
  });
  box.querySelectorAll('#ccnum').forEach(el=>{
    if(el.dataset.ccPan==='1')return;el.dataset.ccPan='1';
    el.setAttribute('inputmode','numeric');el.setAttribute('autocomplete','cc-number');if(!el.getAttribute('maxlength'))el.setAttribute('maxlength','23');
    el.addEventListener('input',()=>setPan(el));
    el.addEventListener('paste',e=>{e.preventDefault();el.value=formatPan((e.clipboardData||window.clipboardData).getData('text')||'');try{el.setSelectionRange(el.value.length,el.value.length)}catch(x){}});
  });
}
document.addEventListener('focusin',e=>{const t=e.target;if(!t||!t.id)return;if(t.id==='ccexp'||t.id==='ccnum')enhanceCardFields(t.form||t.closest('.cardform')||t.parentElement||document)});
document.addEventListener('input',e=>{const t=e.target;if(!t||(t.id!=='ccexp'&&t.id!=='ccnum'))return;enhanceCardFields(t.form||t.closest('.cardform')||document);if(t.id==='ccnum')setPan(t);if(t.id==='ccexp'){const del=e.inputType&&e.inputType.indexOf('delete')===0;t.value=formatExp(t.value,{slash:!del||expDigits(t.value).length>2,noPad:!!del})}},true);
const luhn=n=>{let s=0,alt=false;for(let i=n.length-1;i>=0;i--){let d=+n[i];if(alt){d*=2;if(d>9)d-=9}s+=d;alt=!alt}return s%10===0};
const brandOf=n=>/^4/.test(n)?'visa':/^(5[1-5]|2[2-7])/.test(n)?'mastercard':/^3[47]/.test(n)?'amex':/^6(011|5)/.test(n)?'discover':'card';
const BRAND={visa:'Visa',mastercard:'Mastercard',amex:'Amex',discover:'Discover',card:'Card'};
// MOCK provider: maps the standard test numbers to gateway tokens, the way a real processor's hosted fields return a token
const mockProvider={name:'mock',test:true,
 tokenize(f){const n=digits(f.number),cvc=digits(f.cvc);let exp=String(f.exp||'');const ed=expDigits(exp);if(ed.length===4)exp=ed.slice(0,2)+'/'+ed.slice(2);const m=exp.match(/^\s*(\d{1,2})\s*\/\s*(\d{2}|\d{4})\s*$/);
  if(n.length<13||n.length>19||!luhn(n))return {error:'Enter a valid card number.'};
  if(!m||+m[1]<1||+m[1]>12)return {error:'Enter the expiry as MM/YY.'};
  if(cvc.length<3||cvc.length>4)return {error:'Enter the 3 or 4 digit security code.'};
  const T={'4000000000000002':'tok_mock_declined','4000000000009995':'tok_mock_insufficient','4000000000000069':'tok_mock_expired'};
  const ey=m[2].length===2?2000+(+m[2]):+m[2];
  return {token:T[n]||'tok_mock_ok',brand:brandOf(n),last4:n.slice(-4),exp_month:+m[1],exp_year:ey}}};
const P={
 provider:mockProvider,
 // card checkout is on only when this build is configured for it AND the server says so
 enabled(FL){const m=CFG.PAYMENTS_MODE||'off';return m!=='off'&&!!FL&&FL.card_payments_enabled===true&&(FL.payments_mode||'off')===m},
 mode(){return CFG.PAYMENTS_MODE||'off'},
 BANNER,BRAND,
 formHtml(){return `<div class="cardform" id="cardform">${BANNER}<label>Card number<input id="ccnum" inputmode="numeric" autocomplete="cc-number" maxlength="23" placeholder="4242 4242 4242 4242"></label>
  <div class="ccrow"><label>Expiry Date<input id="ccexp" inputmode="numeric" autocomplete="cc-exp" maxlength="5" placeholder="MM/YY"></label><label>Security code<input id="cccvc" inputmode="numeric" autocomplete="cc-csc" maxlength="4" placeholder="123"></label></div>
  <label>Name on card<input id="ccname" autocomplete="cc-name" maxlength="80"></label><p class="muted"><small>🔒 Your full card number and security code are never sent to or stored by Carriacou Connect: only the card brand, last 4 digits and expiry.</small></p></div>`},
 bind(root){enhanceCardFields(root||document);return P},
 read(root){const g=s=>(root.querySelector(s)||{}).value||'';return P.provider.tokenize({number:digits(g('#ccnum')),exp:formatExp(g('#ccexp'),{slash:true})||g('#ccexp'),cvc:g('#cccvc')})},
 wipe(root){['#ccnum','#cccvc'].forEach(s=>{const e=root.querySelector(s);if(e)e.value=''})},
 formatExp,formatPan,expDigits,
 async pay(sb,orderIds,tok,key){const r=await sb.rpc('card_pay_orders',{p_order_ids:orderIds,p_card:{token:tok.token,brand:tok.brand,last4:tok.last4,exp_month:tok.exp_month,exp_year:tok.exp_year},p_key:key||null});return r},
 async toPickup(sb,orderIds){return sb.rpc('card_order_to_pickup',{p_order_ids:orderIds})},
 async refund(sb,orderId,cents,reason){return sb.rpc('vendor_refund_card',{p_order:orderId,p_amount_cents:cents,p_reason:reason||null})},
 async info(sb,orderId){try{const r=await sb.rpc('order_card_payment',{p_order:orderId});return r.error?[]:(r.data||[])}catch(e){return []}},
 label(cp){return cp?BRAND[cp.brand]+' •••• '+cp.last4+(cp.test?' (TEST)':''):''},
 statusText(cp){return !cp?'':({paid:'Paid by card',partially_refunded:'Paid by card, part refunded',refunded:'Refunded to card',failed:'Card declined',pending:'Card payment pending',authorised:'Card authorised'})[cp.status]||cp.status},
 // summary block for receipts and order pages
 html(list){const ok=(list||[]).filter(x=>x.status!=='failed');if(!ok.length)return '';const cp=ok[0];
  return `<div class="cardpay-sum">${cp.test?'<span class="testtag">TEST MODE – no real money</span>':''}<b>${esc(P.statusText(cp))}</b> · ${esc(P.label(cp))} · ${C.cents(cp.amount_cents)}${Number(cp.refunded_cents)?` · refunded ${C.cents(cp.refunded_cents)}`:''}</div>`}
};
C.payments=P;
const mo=typeof MutationObserver==='function'&&new MutationObserver(ms=>{if(ms.some(m=>m.addedNodes&&[...m.addedNodes].some(n=>n.nodeType===1&&(n.id==='ccexp'||n.id==='ccnum'||(n.querySelector&&(n.querySelector('#ccexp')||n.querySelector('#ccnum')))))))enhanceCardFields(document)});if(mo)mo.observe(document.documentElement,{childList:true,subtree:true});
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>enhanceCardFields(document));else enhanceCardFields(document);
})();
