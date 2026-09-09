/* Public static resources only. Never cache APIs, auth, order responses, addresses, or private HTML. */
const VERSION='jana-static-v3';
const SHELL=['/offline.html','/assets/styles.css','/assets/common.js','/assets/shop.js','/assets/ops.js','/assets/icon.svg'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(VERSION).then(c=>c.addAll(SHELL)));self.skipWaiting();});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==VERSION).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{
 const u=new URL(e.request.url); if(e.request.method!=='GET'||u.origin!==self.location.origin||u.pathname.startsWith('/api/')||u.pathname==='/health'||u.pathname==='/ready'||u.pathname.startsWith('/media/'))return;
 if(e.request.mode==='navigate'){e.respondWith(fetch(e.request).catch(()=>caches.match('/offline.html')));return;}
 if(SHELL.includes(u.pathname)){e.respondWith(caches.match(e.request).then(cached=>cached||fetch(e.request)));}
});
