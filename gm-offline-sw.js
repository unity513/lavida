const CACHE_NAME = "lavida-connect-independent-v230";
const APP_SHELL = [
  "./",
  "./index.html",
  "./marketplace.html",
  "./lavida-updater.js",
  "./community.html",
  "./lavida-community-video.css",
  "./lavida-community-video.js",
  "./games365.html",
  "./chess365.html",
  "./bawo365.html",
  "./assets/bawo-board.jpg",
  "./hrm365.html",
  "./product-details.html",
  "./marketplace-admin.html",
  "./marketplace-orders-admin.html",
  "./printing-admin.html",
  "./business-operations.html",
  "./signin.html",
  "./register.html",
  "./forgot-password.html",
  "./reset-password.html",
  "./manifest.webmanifest",
  "./vendor/supabase-js.js",
  "./vendor/chess-global.js"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("message", (event) => {
  if(event.data?.type === "SKIP_WAITING") self.skipWaiting();
});

self.addEventListener("fetch", (event) => {
  if(event.request.method !== "GET") return;
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        return response;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || caches.match("./index.html")))
  );
});
