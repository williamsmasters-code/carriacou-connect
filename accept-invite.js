// Accept a staff / sub-admin invite (v0.9). The code comes from the link (#code=...) or is typed in. It only works for the email it was sent to.
(function(){
const CC=window.CC,esc=CC.esc,$=s=>document.querySelector(s),R=$('#inv');
const KEY='cconnect_invite_code';
const nice=m=>/Could not find the function|schema cache/.test(m||'')?'Team invites are not switched on yet (staff.sql has not been run in Supabase).':m;
async function boot(){
 if(!CC.configured){R.innerHTML='<div class="notice">Accounts are not switched on in this preview.</div>';return}
 const sb=await CC.client();if(!sb){R.innerHTML='<div class="notice">Accounts are not switched on in this preview.</div>';return}
 const hm=(location.hash.match(/code=([^&]+)/)||[])[1];
 let code=hm?decodeURIComponent(hm):localStorage.getItem(KEY)||'';
 if(hm){localStorage.setItem(KEY,code);history.replaceState(null,'',location.pathname)}   // keep the secret out of the address bar / history
 const user=await CC.getUser();
 if(!user){
  R.innerHTML='<div class="notice">To join a team, sign in or create an account <b>with the email address the invite was sent to</b>. Your invite is kept safe in this browser while you do that.</div><p><a class="btn" href="login.html?next=accept-invite.html">Sign in</a> <a class="btn alt" href="signup.html?next=accept-invite.html">Create an account</a></p><p class="muted">When you sign up, choose <b>Shop (consumer)</b>: team members do not need a business profile of their own.</p>';return}
 const draw=async(msg)=>{
  let pv=null;
  if(code){const r=await sb.rpc('invite_preview',{p_code:code});if(r.error){msg=nice(r.error.message)}else pv=r.data}
  R.innerHTML=(msg?'<div class="notice err" role="alert">'+esc(msg)+'</div>':'')+
   (pv&&pv.ok?'<div class="invbox"><span class="kicker">You are invited</span><h2>'+esc(pv.vendor_name)+'</h2><p>Role: <b>'+esc(CC.ROLE_LABEL[pv.role]||pv.role)+'</b>. You are signed in as <b>'+esc(user.email)+'</b>.</p><p class="muted">'+(pv.role==='staff'?'Staff can manage orders, take POS payments and write order notes.':'Sub-admins can also manage products, issue refunds and see analytics.')+' The owner can pause or remove your access at any time.</p><button class="btn" id="acc">Join the team</button> <a class="btn ghost" href="index.html">Not now</a></div>'
   :(code&&!msg?'<div class="notice err" role="alert">This invite is not valid for <b>'+esc(user.email)+'</b>. It may have expired, been used already, been revoked, or been sent to a different email address. Ask the owner for a new one, or sign in with the invited email.</div>':''))+
   '<form id="cf" class="formcard"><label>Invite code<input id="cc" value="'+esc(code)+'" placeholder="CCI-XXXXX-XXXXX-XXXXX-XXXXX" autocomplete="off" spellcheck="false"></label><button class="btn alt">Check code</button></form>';
  const a=$('#acc');
  if(a)a.onclick=async()=>{a.disabled=true;const r=await sb.rpc('accept_invite',{p_code:code});
   if(r.error){await draw(nice(r.error.message));return}
   if(!r.data.ok){await draw('That invite could not be used.');return}
   localStorage.removeItem(KEY);R.innerHTML='<div class="notice ok">You joined <b>'+esc(r.data.vendor_name)+'</b> as '+esc(CC.ROLE_LABEL[r.data.role]||r.data.role)+'. Taking you to the work dashboard…</div>';setTimeout(()=>location.href='dashboard-vendor.html',900)};
  $('#cf').onsubmit=async e=>{e.preventDefault();code=$('#cc').value.trim();localStorage.setItem(KEY,code);await draw('')};
 };
 await draw('');
}
boot().catch(e=>{console.error(e);R.innerHTML='<div class="notice err">Something went wrong. Please refresh.</div>'});
})();
