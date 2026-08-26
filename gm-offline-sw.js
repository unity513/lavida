const CACHE_NAME = "lavida-connect-independent-v236";
const APP_SHELL = [
  "./",
  "./index.html",
  "./marketplace.html",
  "./lavida-updater.js",
  "./community.html",
  "./lavida-community-video.css",
  "./lavida-community-video.js",
  "./lavida-services.css",
  "./lavida-services.js",
  "./lavida-notifications.css",
  "./lavida-notifications.js",
  "./assets/lavida-notification-l-v2.png",
  "./assets/lavida-notification-l-badge-v2.png",
  "./games365.html",
  "./chess365.html",
  "./bawo365.html",
  "./assets/bawo-board.jpg",
  "./hrm365.html",
  "./product-details.html",
  "./marketplace-admin.html",
  "./marketplace-orders-admin.html",
  "./printing-admin.html",
  "./service-requests-admin.html",
  "./notifications-admin.html",
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

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (error) {
    payload = { title: "LAVIDA Update", body: event.data ? event.data.text() : "There's a new update from LAVIDA." };
  }
  const title = payload.title || "LAVIDA Update";
  const options = {
    body: payload.body || "There's a new update from LAVIDA.",
    icon: payload.icon || "./assets/lavida-notification-l-v2.png",
    badge: payload.badge || "./assets/lavida-notification-l-badge-v2.png",
    tag: payload.tag || payload.notification_id || "lavida-notification",
    data: {
      url: payload.url || payload.action_url || "./marketplace.html#notifications",
      notification_id: payload.notification_id || payload.notificationId || null,
      notificationId: payload.notificationId || payload.notification_id || null,
      type: payload.type || "",
      orderId: payload.orderId || payload.order_id || "",
      invoiceId: payload.invoiceId || payload.invoice_id || "",
      projectId: payload.projectId || payload.project_id || ""
    },
    requireInteraction: Boolean(payload.requireInteraction)
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const targetUrl = new URL(event.notification.data?.url || "./marketplace.html#notifications", self.location.href).href;
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ("focus" in client && client.url.split("#")[0] === targetUrl.split("#")[0]) {
          client.navigate(targetUrl);
          return client.focus();
        }
      }
      if (clients.openWindow) return clients.openWindow(targetUrl);
      return null;
    })
  );
});

