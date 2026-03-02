// sw.js — CravaAí (simples e seguro)
// ✅ NÃO cacheia HTML (evita ficar preso em versão antiga)
// ✅ NÃO cacheia Netlify Functions (odds sempre atualizadas)
// ✅ Cacheia só arquivos estáticos (GET) para carregar mais rápido

const VERSION = "cravai-2026-03-02";
const CACHE_STATIC = `${VERSION}-static`;

self.addEventListener("install", (event) => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE_STATIC));
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(
      keys.map((k) => (k.endsWith("-static") && k !== CACHE_STATIC ? caches.delete(k) : null))
    );
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Só lida com GET
  if (req.method !== "GET") return;

  // Nunca cachear chamadas da API (Netlify functions)
  if (url.pathname.startsWith("/.netlify/functions/")) {
    event.respondWith(fetch(req));
    return;
  }

  // Nunca cachear HTML / navegação
  const accept = req.headers.get("accept") || "";
  const isHTML = req.mode === "navigate" || accept.includes("text/html") || url.pathname.endsWith(".html");
  if (isHTML) {
    event.respondWith(fetch(req));
    return;
  }

  // Para arquivos estáticos: cache-first com fallback para rede
  event.respondWith((async () => {
    const cache = await caches.open(CACHE_STATIC);
    const cached = await cache.match(req);
    if (cached) return cached;

    const fresh = await fetch(req);
    // guarda só respostas OK e same-origin
    if (fresh && fresh.ok && url.origin === self.location.origin) {
      cache.put(req, fresh.clone()).catch(() => {});
    }
    return fresh;
  })());
});