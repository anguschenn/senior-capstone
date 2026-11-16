const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const serviceWorkerPath = path.resolve(__dirname, '../../web/push/sw.js');
const serviceWorkerSource = fs.readFileSync(serviceWorkerPath, 'utf8');

function createWorker() {
  const listeners = {};
  const notifications = [];
  const windows = [];
  const openedUrls = [];

  const registration = {
    async getNotifications(options = {}) {
      return notifications.filter(
        (notification) => !options.tag || notification.tag === options.tag,
      );
    },
    async showNotification(title, options) {
      const notification = {
        title,
        ...options,
        close() {
          const index = notifications.indexOf(notification);
          if (index >= 0) notifications.splice(index, 1);
        },
      };
      const existing = notifications.findIndex(
        (item) => item.tag === notification.tag,
      );
      if (existing >= 0) notifications.splice(existing, 1);
      notifications.push(notification);
    },
  };
  const self = {
    location: { origin: 'https://smartspend.example' },
    registration,
    clients: {
      async matchAll() {
        return windows;
      },
      async openWindow(url) {
        openedUrls.push(url);
      },
    },
    addEventListener(type, listener) {
      listeners[type] = listener;
    },
  };

  vm.runInNewContext(serviceWorkerSource, { self, URL, console, Promise });
  return { listeners, notifications, windows, openedUrls };
}

async function sendPush(worker, message) {
  const pending = [];
  worker.listeners.push({
    data: { json: () => message },
    waitUntil(promise) {
      pending.push(promise);
    },
  });
  await Promise.all(pending);
}

test('aggregates notifications of the same kind and counts them in the title', async () => {
  const worker = createWorker();
  await Promise.all(
    Array.from({ length: 120 }, () =>
      sendPush(worker, {
        kind: 'transaction_review',
        title: 'SmartSpend needs your input',
        body: 'A transaction needs a category review.',
        url: '/?notification=transaction_review',
      }),
    ),
  );

  assert.equal(worker.notifications.length, 1);
  assert.equal(worker.notifications[0].title, '120 transactions need review');
  assert.equal(worker.notifications[0].data.count, 120);
  assert.equal(worker.notifications[0].tag, 'smartspend-transaction_review');
});

test('displays the exact count supplied for a batch of 34 reviews', async () => {
  const worker = createWorker();
  await sendPush(worker, {
    kind: 'transaction_review',
    count: 34,
    title: 'SmartSpend needs your input',
    body: 'A transaction needs a category review.',
    url: '/?notification=transaction_review',
  });

  assert.equal(worker.notifications[0].title, '34 transactions need review');
});

test('keeps different notification kinds in separate groups', async () => {
  const worker = createWorker();
  await Promise.all([
    sendPush(worker, {
      kind: 'transaction_review',
      title: 'SmartSpend needs your input',
      body: 'A transaction needs a category review.',
      url: '/?notification=transaction_review',
    }),
    sendPush(worker, {
      kind: 'budget_alert',
      title: 'SmartSpend budget alert',
      body: 'A budget needs your attention.',
      url: '/?notification=budget',
    }),
  ]);

  assert.equal(worker.notifications.length, 2);
  assert.deepEqual(
    worker.notifications.map((notification) => notification.tag).sort(),
    ['smartspend-budget_alert', 'smartspend-transaction_review'],
  );
});

test('does not combine unrelated unknown notification kinds', async () => {
  const worker = createWorker();
  await Promise.all([
    sendPush(worker, { kind: 'new_kind_a' }),
    sendPush(worker, { kind: 'new_kind_b' }),
  ]);

  assert.equal(worker.notifications.length, 2);
  assert.deepEqual(
    worker.notifications.map((notification) => notification.tag).sort(),
    ['smartspend-new_kind_a', 'smartspend-new_kind_b'],
  );
});

test('merges legacy same-kind notifications without losing their count', async () => {
  const worker = createWorker();
  worker.notifications.push({
    title: 'SmartSpend needs your input',
    body: 'A transaction needs a category review.',
    tag: 'delivery-1',
    data: { url: '/?notification=transaction_review' },
    close() {
      worker.notifications.splice(worker.notifications.indexOf(this), 1);
    },
  });
  await sendPush(worker, {
    kind: 'transaction_review',
    title: 'SmartSpend needs your input',
    body: 'A transaction needs a category review.',
    url: '/?notification=transaction_review',
  });

  assert.equal(worker.notifications.length, 1);
  assert.equal(worker.notifications[0].title, '2 transactions need review');
});

test('notification clicks navigate an open app to the destination and focus it', async () => {
  const worker = createWorker();
  const calls = [];
  worker.windows.push({
    url: 'https://smartspend.example/',
    async navigate(url) {
      calls.push(['navigate', url]);
      return this;
    },
    async focus() {
      calls.push(['focus']);
    },
  });
  const event = {
    notification: { data: { url: '/?notification=transaction_review' }, close() {} },
    waitUntil(promise) {
      this.pending = promise;
    },
  };

  worker.listeners.notificationclick(event);
  await event.pending;

  assert.deepEqual(calls, [
    ['navigate', 'https://smartspend.example/?notification=transaction_review'],
    ['focus'],
  ]);
  assert.deepEqual(worker.openedUrls, []);
});

test('notification clicks open the destination when the app is closed', async () => {
  const worker = createWorker();
  const event = {
    notification: {
      data: { url: '/?notification=transaction_review' },
      close() {},
    },
    waitUntil(promise) {
      this.pending = promise;
    },
  };

  worker.listeners.notificationclick(event);
  await event.pending;

  assert.deepEqual(worker.openedUrls, [
    'https://smartspend.example/?notification=transaction_review',
  ]);
});
