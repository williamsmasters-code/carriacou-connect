// Carriacou Connect service worker (v1.14). Purpose: make the site installable, nothing more.
// Network-first for same-origin page navigations only, with a tiny offline fallback. Supabase, API, realtime,
// CDN and every non-GET request are never touched (the browser handles them directly), so live data stays fresh.
const C='cc-shell-v1',OFF='./index.html';
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.add(OFF)).catch(()=>{}));self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==C).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{const r=e.request;
  if(r.method!=='GET'||r.mode!=='navigate'||new URL(r.url).origin!==location.origin)return;
  e.respondWith(fetch(r).catch(()=>caches.match(r).then(m=>m||caches.match(OFF))));
});
