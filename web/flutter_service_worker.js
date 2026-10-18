// Replaces Flutter's generated worker, which reloads every client on activate.
// Do not navigate clients. Navigating here reloads the page forever.
self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.registration.unregister());
});
