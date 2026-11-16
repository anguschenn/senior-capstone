let pushQueue = Promise.resolve();

function notificationKind(message) {
  const knownKinds = [
    'transaction_review',
    'subscription_review',
    'budget_alert',
    'monthly_report',
  ];
  if (knownKinds.includes(message.kind)) return message.kind;
  if (
    typeof message.kind === 'string' &&
    /^[a-z0-9_-]{1,64}$/i.test(message.kind)
  ) {
    return message.kind;
  }

  try {
    const url = new URL(message.url || '/', self.location.origin);
    const kind = url.searchParams.get('notification');
    if (kind === 'budget') return 'budget_alert';
    if (knownKinds.includes(kind)) return kind;
    if (typeof kind === 'string' && /^[a-z0-9_-]{1,64}$/i.test(kind)) {
      return kind;
    }
  } catch (_) {
    // The click handler separately rejects URLs outside this app's origin.
  }
  return 'other';
}

function notificationContent(kind, count) {
  switch (kind) {
    case 'transaction_review':
      return {
        title: `${count} transaction${count === 1 ? ' needs' : 's need'} review`,
        body: 'Open SmartSpend to review transaction categories.',
      };
    case 'subscription_review':
      return {
        title: `${count} subscription${count === 1 ? ' needs' : 's need'} review`,
        body: 'Open SmartSpend to review recurring charges.',
      };
    case 'budget_alert':
      return {
        title: `${count} budget alert${count === 1 ? ' needs' : 's need'} attention`,
        body: 'Open SmartSpend to review your budget alerts.',
      };
    case 'monthly_report':
      return {
        title: `${count} monthly report${count === 1 ? ' is' : 's are'} available`,
        body: 'Open SmartSpend to view your report.',
      };
    default:
      const label = kind.replace(/_/g, ' ');
      return {
        title: `${count} ${label} notification${count === 1 ? '' : 's'}`,
        body: 'Open SmartSpend to review your account.',
      };
  }
}

async function showGroupedNotification(message) {
  const kind = notificationKind(message);
  const tag = `smartspend-${kind}`;
  const existing = await self.registration.getNotifications();
  const sameKind = existing.filter((notification) =>
    notificationKind(notification.data || {}) === kind,
  );
  const previousCount = sameKind.reduce((count, notification) => {
    const value = Number(notification.data?.count);
    return count + (Number.isSafeInteger(value) && value > 0 ? value : 1);
  }, 0);
  for (const notification of sameKind) {
    if (notification.tag !== tag) notification.close();
  }
  const increment = Number.isSafeInteger(message.count) && message.count > 0
    ? message.count
    : 1;
  const count = previousCount + increment;
  const content = notificationContent(kind, count);

  await self.registration.showNotification(content.title, {
    body: content.body,
    icon: '../icons/Icon-192.png',
    badge: '../icons/Icon-192.png',
    tag,
    data: {
      url: message.url || '/',
      kind,
      count,
    },
    renotify: false,
  });
}

self.addEventListener('push', (event) => {
  let message = {};
  try {
    message = event.data ? event.data.json() : {};
  } catch (_) {
    message = {};
  }
  if (!message || typeof message !== 'object') message = {};

  const delivery = pushQueue
    .catch(() => {})
    .then(() => showGroupedNotification(message));
  pushQueue = delivery.catch((error) => {
    console.error('Could not display a push notification:', error);
  });
  event.waitUntil(delivery);
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
