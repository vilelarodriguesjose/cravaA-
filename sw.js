// sw.js — CravaAí (safe update)
// Não cacheia index.html para evitar tela antiga.
// Cacheia só arquivos estáticos (css/js/imagens) quando fizer sentido.

const VERSION = "cravai-v20260302";
const STATIC_CACHE = `${VERSION}-static`;

self.addEventListener("install", (event) => {
  self.skipWaiting();
  event.waitUntil(caches.open(STATIC_CACHE));
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.map(k => (k.startsWith("cravai-") && k !== STATIC_CACHE) ? caches.delete(k) : null));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Nunca cachear HTML
  if (req.mode === "navigate" || url.pathname.endsWith(".html") || url.pathname === "/" ) {
    event.respondWith(fetch(req));
    return;
  }

  // Nunca cachear funções (API)
  if (url.pathname.startsWith("/.netlify/functions/")) {
    event.respondWith(fetch(req));
    return;
  }

  // Cache-first só para arquivos estáticos
  event.respondWith((async () => {
    const cache = await caches.open(STATIC_CACHE);
    const cached = await cache.match(req);
    if (cached) return cached;

    const fresh = await fetch(req);
    // Só cacheia GET e respostas ok
    if (req.method === "GET" && fresh.ok) cache.put(req, fresh.clone());
    return fresh;
  })());
});