(() => {
  const supported = () =>
    'Notification' in window &&
    'serviceWorker' in navigator &&
    'PushManager' in window;

  const registration = async () => {
    const scriptUrl = new URL('push/sw.js', document.baseURI);
    const scopeUrl = new URL('push/', document.baseURI);
    const reg = await navigator.serviceWorker.register(scriptUrl, {
      scope: scopeUrl.pathname,
    });

    if (reg.active) return reg;
    const worker = reg.installing || reg.waiting;
    if (!worker) throw new Error('The push service worker did not install.');

    await new Promise((resolve, reject) => {
      if (worker.state === 'activated') {
        resolve();
        return;
      }
      worker.addEventListener('statechange', () => {
        if (worker.state === 'activated') resolve();
        if (worker.state === 'redundant') {
          reject(new Error('The push service worker could not activate.'));
        }
      });
    });
    return reg;
  };

  const currentSubscription = async () => {
    if (!supported()) return null;
    const reg = await registration();
    return reg.pushManager.getSubscription();
  };

  window.SmartSpendPush = {
    status: async () => {
      if (!supported()) {
        return JSON.stringify({
          supported: false,
          permission: 'unsupported',
          subscribed: false,
          subscription: null,
        });
      }
      const subscription = await currentSubscription();
      return JSON.stringify({
        supported: true,
        permission: Notification.permission,
        subscribed: subscription !== null,
        subscription: subscription ? subscription.toJSON() : null,
      });
    },

    requestPermission: async () => {
      if (!supported()) {
        return JSON.stringify({
          supported: false,
          permission: 'unsupported',
        });
      }
      const permission =
        Notification.permission === 'default'
          ? await Notification.requestPermission()
          : Notification.permission;
      return JSON.stringify({ supported: true, permission });
    },

    subscribe: async (publicKey) => {
      if (!supported()) {
        return JSON.stringify({
          supported: false,
          permission: 'unsupported',
          subscription: null,
        });
      }
      const permission = Notification.permission;
      if (permission !== 'granted') {
        return JSON.stringify({
          supported: true,
          permission,
          subscription: null,
        });
      }

      const reg = await registration();
      let subscription = await reg.pushManager.getSubscription();
      if (!subscription) {
        const padding = '='.repeat((4 - (publicKey.length % 4)) % 4);
        const raw = atob((publicKey + padding).replace(/-/g, '+').replace(/_/g, '/'));
        const applicationServerKey = Uint8Array.from(raw, (char) =>
          char.charCodeAt(0),
        );
        subscription = await reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey,
        });
      }
      return JSON.stringify({
        supported: true,
        permission,
        subscription: subscription.toJSON(),
      });
    },

    unsubscribe: async () => {
      const subscription = await currentSubscription();
      if (subscription) await subscription.unsubscribe();
      return JSON.stringify({ unsubscribed: true });
    },
  };
})();
