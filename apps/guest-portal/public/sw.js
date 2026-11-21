/* Cache public shell assets only. Never retain stay tokens, HTML, APIs or documents. */
const CACHE='hospitality-guest-shell-v1';
const PUBLIC_FILES=['/offline.html','/icons/stay-192.png','/icons/stay-512.png','/icons/stay-180.png'];
self.addEventListener('install',event=>{event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(PUBLIC_FILES)));self.skipWaiting();});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('hospitality-guest-shell-')&&key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',event=>{const request=event.request,url=new URL(request.url);if(request.method!=='GET'||url.origin!==self.location.origin)return;
 if(url.pathname.startsWith('/s/')||request.mode==='navigate'){event.respondWith(fetch(request,{cache:'no-store'}).catch(()=>caches.match('/offline.html').then(response=>response||new Response('You are offline. Reconnect and reopen your hotel stay link.',{status:503,headers:{'Content-Type':'text/plain','Cache-Control':'no-store'}}))));return;}
 if(PUBLIC_FILES.includes(url.pathname)&&!url.search)event.respondWith(caches.match(request).then(response=>response||fetch(request)));
});
