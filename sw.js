// Carriacou Connect service worker (v1.19). Versioned: change VERSION to roll out an update (old caches are deleted on activate).
// Caches ONLY the app shell (same-origin HTML/CSS/JS/icons listed below) and an offline page.
// NEVER caches Supabase, API, auth, realtime, storage or any other cross-origin response, and never any non-GET request:
// those requests are not intercepted at all, so the browser talks to Supabase directly and live data and sessions stay fresh.
const VERSION='v1.19.1';
const C='cc-shell-'+VERSION,OFF='./offline.html';
const SHELL=['./','./index.html','./offline.html','./style.css','./cc.js','./app.js','./manifest.webmanifest','./icons/icon-192.png','./icons/icon-512.png','./icons/favicon-32.png','./icons/apple-touch-icon.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>Promise.all(SHELL.map(u=>c.add(new Request(u,{cache:'reload'})).catch(()=>{})))));self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k.startsWith('cc-')&&k!==C).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
const isShell=u=>{const base=new URL('./',self.registration.scope).pathname;const p=u.pathname.startsWith(base)?'./'+u.pathname.slice(base.length):null;return p!==null&&SHELL.includes(p)};
self.addEventListener('fetch',e=>{const r=e.request,u=new URL(r.url);
  if(r.method!=='GET'||u.origin!==location.origin)return;               // Supabase / auth / CDN / POST: never touched
  if(/supabase|\/auth\/|\/rest\/|\/realtime\//i.test(u.href)||u.pathname.endsWith('config.js'))return;
  if(r.mode==='navigate'){e.respondWith(fetch(r).catch(()=>caches.match(r,{ignoreSearch:true}).then(m=>m||caches.match(OFF))));return}
  if(isShell(u))e.respondWith(caches.open(C).then(c=>fetch(r).then(res=>{if(res.ok&&res.type==='basic')c.put(r,res.clone());return res}).catch(()=>c.match(r))));
});
