// Left in place so an already-installed worker can update, then leave.
// Do not navigate clients. Navigating here reloads the page forever.
self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.registration.unregister());
});
