self.addEventListener('push', (event) => {
  let message = {};
  try {
    message = event.data ? event.data.json() : {};
  } catch (_) {
    message = {};
  }

  const title = message.title || 'SmartSpend';
  const options = {
    body: message.body || 'Open SmartSpend to review your account.',
    icon: '../icons/Icon-192.png',
    badge: '../icons/Icon-192.png',
    tag: message.tag || 'smartspend-notification',
    data: { url: message.url || '/' },
    renotify: false,
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const requested = new URL(
    event.notification.data?.url || '/',
    self.location.origin,
  );
  if (requested.origin !== self.location.origin) return;

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(
      (windows) => {
        const existing = windows.find((client) => {
          try {
            return new URL(client.url).origin === self.location.origin;
          } catch (_) {
            return false;
          }
        });
        if (existing) {
          return existing.navigate(requested.href).then(() => existing.focus());
        }
        return self.clients.openWindow(requested.href);
      },
    ),
  );
});
