// =============================================================================
// Service Worker — permet à l'application de se charger sans connexion internet,
// y compris après un redémarrage complet de l'ordinateur (le cache est stocké
// sur le disque, dans le profil du navigateur, pas en mémoire).
//
// Stratégie :
// - Pages/CSS/JS/images de l'app : "stale-while-revalidate" (réponse immédiate
//   depuis le cache, mise à jour en arrière-plan si une connexion est dispo).
// - Bibliothèques externes (Supabase JS, XLSX) : cache-first, car les URLs sont
//   versionnées (figées) donc jamais périmées.
// - Appels à l'API Supabase elle-même : jamais interceptés, gérés par le cache
//   applicatif (localStorage) dans assets/app.js.
//
// Pense à changer CACHE_VERSION si tu modifies les fichiers de l'app, sinon les
// postes déjà installés continueront de servir l'ancienne version en cache.
// =============================================================================

const CACHE_VERSION = "v4";
const SHELL_CACHE = `sylla-shell-${CACHE_VERSION}`;
const RUNTIME_CACHE = `sylla-runtime-${CACHE_VERSION}`;

const SHELL_ASSETS = [
  "login.html",
  "index.html",
  "catalogue.html",
  "stock.html",
  "rupture-stock.html",
  "factures.html",
  "facture-detail.html",
  "credits.html",
  "clients.html",
  "assets/style.css",
  "assets/app.js",
  "assets/config.js",
  "assets/img/logo-sylla-icon.png",
  "assets/img/logo-sylla.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE)
      .then((cache) => cache.addAll(SHELL_ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(
        names.filter((n) => n !== SHELL_CACHE && n !== RUNTIME_CACHE).map((n) => caches.delete(n))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);

  // Les appels Supabase (API/Auth) passent en direct : jamais mis en cache par le SW.
  if (url.hostname.endsWith(".supabase.co")) return;

  const isSameOrigin = url.origin === self.location.origin;
  const isVendorScript = url.hostname === "cdn.jsdelivr.net";
  if (!isSameOrigin && !isVendorScript) return;

  // Clé de cache sans la query string, pour que "facture-detail.html?id=42" et
  // "facture-detail.html?id=43" partagent la même entrée de cache (le contenu
  // dynamique est de toute façon rechargé depuis Supabase, pas depuis le SW).
  const cacheKey = isSameOrigin ? new Request(url.origin + url.pathname) : req;

  event.respondWith(
    (async () => {
      const cache = await caches.open(isVendorScript ? RUNTIME_CACHE : SHELL_CACHE);
      const cached = await cache.match(cacheKey);

      const networkFetch = fetch(req)
        .then((res) => {
          if (res && res.ok) cache.put(cacheKey, res.clone());
          return res;
        })
        .catch(() => null);

      if (isVendorScript) {
        // URL versionnée (contient le numéro de version de la lib) : jamais périmée.
        return cached || (await networkFetch) || Response.error();
      }

      if (cached) {
        // La requête réseau ci-dessus tourne déjà en tâche de fond (elle a été lancée
        // avant ce test) et mettra le cache à jour toute seule si elle aboutit ;
        // on ne l'attend pas, on répond tout de suite avec la version en cache.
        return cached;
      }
      return (await networkFetch) || (await cache.match("login.html")) || Response.error();
    })()
  );
});
