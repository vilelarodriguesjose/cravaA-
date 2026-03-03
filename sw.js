// sw.js (fix: HTML = network-first | assets = cache-first)
const VERSION = "v3"; // <-- sempre que mudar o SW, troca isso (v4, v5...)
const CACHE_STATIC = `cravai-static-${VERSION}`;
const CACHE_RUNTIME = `cravai-runtime-${VERSION}`;

const CORE_ASSETS = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./sw.js",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_STATIC).then((cache) => cache.addAll(CORE_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.map((k) => {
          if (k !== CACHE_STATIC && k !== CACHE_RUNTIME) return caches.delete(k);
          return null;
        })
      )
    )
  );
  self.clients.claim();
});

// helpers
function isHTMLRequest(req) {
  return (
    req.mode === "navigate" ||
    (req.headers.get("accept") || "").includes("text/html")
  );
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);

  // 1) NAVEGAÇÃO/HTML -> NETWORK FIRST (evita "site antigo" ao mudar o index)
  if (isHTMLRequest(req)) {
    event.respondWith(
      fetch(req)
        .then((res) => {
          // atualiza o cache do index (sem depender do ?)
          const copy = res.clone();
          caches.open(CACHE_RUNTIME).then((cache) => cache.put("./index.html", copy));
          return res;
        })
        .catch(async () => {
          // offline: cai no index cacheado
          const cached = await caches.match("./index.html");
          return cached || caches.match("./");
        })
    );
    return;
  }

  // 2) NÃO cachear requests com querystring em geral (tipo ?odds=...)
  //    (isso evita "poluir" cache com URLs infinitas)
  if (url.search && url.search.length > 0) {
    event.respondWith(
      fetch(req).catch(() => caches.match(req))
    );
    return;
  }

  // 3) ASSETS (css/js/img) -> CACHE FIRST + atualiza em background
  event.respondWith(
    caches.match(req).then((cached) => {
      if (cached) {
        // atualiza em background
        event.waitUntil(
          fetch(req)
            .then((res) => {
              const copy = res.clone();
              return caches.open(CACHE_STATIC).then((cache) => cache.put(req, copy));
            })
            .catch(() => null)
        );
        return cached;
      }

      return fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE_STATIC).then((cache) => cache.put(req, copy));
          return res;
        })
        .catch(() => cached);
    })
  );
});