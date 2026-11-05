# Chrome Browser Push Notifications

This document describes the browser push notification implementation in SmartSpend: what was added, how a notification travels from the app to Chrome, how to configure and test it, and what is not yet covered.

## Status and scope

The code for opt-in Chrome Web Push is implemented in the Flutter web client and Flask backend. It supports four notification event types:

1. A new, reopened, or escalated budget alert.
2. A subscription that needs confirmation.
3. A transaction that needs category review because its classification is low-confidence or uncategorized.
4. A monthly spending report for the previous month.

The code changes and automated tests do not themselves configure a live Supabase project or prove delivery through a real Chrome/Google push subscription. Before production use, the migration, backend credentials, VAPID keys, HTTPS origin, CORS origin, and monthly scheduler must be configured as described below.

Notifications are opt-in per browser. Enabling them does not send a test notification. It authorizes Chrome and registers the current browser to receive future eligible events.

## How one notification works

### 1. User opts in from Settings

The signed-in user enables **Browser notifications** in the app's Settings. The user gesture is important: Chrome permission is requested directly from this interaction, not later in a background task.

The Flutter web bridge checks browser support, requests notification permission, registers `ssdemo_1/web/push/sw.js` with the `/push/` service-worker scope, and creates a Push API subscription using the backend's public VAPID key. The subscription contains a Chrome push endpoint and encryption keys; it is not the VAPID private key.

The Flutter service then calls the authenticated backend to save the subscription. If permission is denied, the browser is unsupported, the backend is not configured, or the save fails, Settings can report an error rather than showing a successful subscription state.

### 2. Backend stores the subscription

The Flask API authenticates push routes using the app's API key and the signed-in Supabase user's access token. The backend validates the subscription payload and accepts only HTTPS Chrome FCM endpoints matching `fcm.googleapis.com/fcm/send/`. It stores the endpoint and keys in Supabase; the browser never receives the VAPID private key.

When a user registers, the backend also checks for eligible existing unresolved items and attempts to queue and deliver them. The budget check is limited to open alerts that have not yet been marked notified.

### 3. App events are detected and queued

The backend uses a durable Supabase queue with a unique `(user_id, event_key)` key. Repeated syncs should therefore not enqueue a second delivery for the same event. The backend sends generic notification copy that omits dollar amounts, merchant names, and other financial details.

Budget alert calculation returns notification candidates for newly detected, reopened, or escalated alerts. After transaction sync, the backend recomputes derived user data and processes budget alerts, pending subscription confirmations, and transaction review candidates.

The transaction review rule excludes transactions with an existing user category/decision, internal transfers/paybacks, and peer-to-peer inflows. It queues low-confidence or uncategorized items.

The monthly script queues a previous-month report once per user and month. An hourly scheduler can run it at 9 AM America/New_York on the first day of each month; the queue's unique event key prevents later hourly runs from duplicating that report.

### 4. Backend sends and Chrome displays

The backend uses the VAPID private key and the subscription's encryption keys to send a Web Push request to the Chrome endpoint. The service worker handles the `push` event and asks the browser to display a system notification.

Clicking the notification navigates to the app on the same origin. App deep-link handling selects the relevant section (Budget, Transactions, Subscriptions, or Cash Flow for the monthly report). Cross-origin notification destinations are ignored.

## Supabase storage and access control

Migration [`db/migrations/019_browser_push_notifications.sql`](./db/migrations/019_browser_push_notifications.sql) creates two tables:

- `public.push_subscriptions`: one browser/device endpoint and its encryption keys per row. Endpoints are sensitive bearer-like identifiers and are restricted to server access.
- `public.notification_deliveries`: queued event content, idempotency key, delivery status, retry count, and timestamps.

Both tables enable Row Level Security, revoke table access from `anon` and `authenticated`, and grant access to `service_role`. Separate rows are used instead of one column on `users`, because a user can opt in from more than one browser/device.

The migration has **not** been applied to the live Supabase project by this code change. Apply it in the Supabase SQL Editor before testing subscription persistence or delivery. Applying the migration is an explicit deployment step.

## Files changed for browser push

### Database and documentation

- `db/migrations/019_browser_push_notifications.sql` — creates the protected subscription and delivery queue tables.
- `.env.example` — documents VAPID settings as backend-only settings.
- `README.md` — adds a setup overview and Render Cron Job instructions.
- `CHROME_PUSH_NOTIFICATIONS.md` — this detailed implementation and operations guide.

### Flask backend

- `python/config.py` — reads the VAPID public key, private key, and subject from backend environment variables.
- `python/requirements.txt` — adds `pywebpush` for VAPID-authenticated Web Push.
- `python/app_factory.py` — registers push routes and permits `DELETE` in CORS for unsubscribe requests.
- `python/routes/push_routes.py` — authenticated endpoints for public push configuration, subscription save, and unsubscribe.
- `python/push_notifications.py` — validates Chrome subscriptions, detects eligible events, queues idempotently, sends encrypted pushes, retries failures, and removes expired subscriptions.
- `python/sync_jobs.py` — processes notification candidates after post-sync derived-state updates.
- `python/user_model.py` — returns candidates when budget alerts are newly detected, reopened, or escalated.
- `python/scripts/generate_vapid_keys.py` — generates a VAPID key pair for backend configuration.
- `python/scripts/send_monthly_reports.py` — hourly cron entry point for monthly reports and queued-delivery retries.
- `python/tests/test_push_notifications.py` — tests subscription validation, review rules, budget event queue behavior, key generation, and report timing.
- `python/tests/test_push_routes.py` — tests push route authentication, public-only config, validation, and subscription save.
- `python/tests/test_route_inventory.py` — includes the new API routes in the expected route set.

### Flutter web app

- `ssdemo_1/lib/core/config/api_config.dart` — defines the push API URLs.
- `ssdemo_1/lib/pages/settings_page.dart` — adds the opt-in control and notification status/error feedback.
- `ssdemo_1/lib/app/main_screen.dart` — connects Settings actions and handles notification-click destinations.
- `ssdemo_1/lib/services/push_notification_service.dart` — coordinates permission, backend configuration, subscription persistence, and unsubscribe.
- `ssdemo_1/lib/services/push_notifications_web.dart` — browser interop for the JavaScript push bridge.
- `ssdemo_1/lib/services/push_notifications_stub.dart` — non-web implementation that reports browser push as unsupported.
- `ssdemo_1/web/index.html` — loads the browser push bridge.
- `ssdemo_1/web/push_notifications.js` — registers the service worker and calls browser notification/push APIs.
- `ssdemo_1/web/push/sw.js` — displays background push notifications and safely handles notification clicks.

### Related budget display correction

- `ssdemo_1/lib/services/financial_snapshot_service.dart` — uses the month-specific budget rows already loaded from Supabase as a fallback if the backend budget-progress response is empty, so a saved budget is not hidden by that response.
- `ssdemo_1/test/services/financial_snapshot_server_budget_progress_test.dart` — adds a regression test for the empty-server-response case.

The generated Flutter plugin registrants and `.metadata` can also change when Flutter tooling runs. Those generated files are not part of the notification logic and should not be manually edited for push setup.

## Configuration and deployment

### 1. Apply the migration

Open the Supabase SQL Editor for the project's database and run all of `db/migrations/019_browser_push_notifications.sql`. Confirm that `push_subscriptions` and `notification_deliveries` exist in the `public` schema.

### 2. Configure backend secrets

Generate a VAPID pair from the repository's `python` directory:

```powershell
cd C:\dev\senior-capstone\python
.\venv\windows\Scripts\python.exe scripts\generate_vapid_keys.py
```

Set the printed values in `python/.env` for local work, or in the backend host's secret environment for production:

- `PUSH_VAPID_PUBLIC_KEY`
- `PUSH_VAPID_PRIVATE_KEY`
- `PUSH_VAPID_SUBJECT`

Use a real team contact address for the subject. Keep the **private** key on the backend only. Never put it in `ssdemo_1/.env`, Flutter `--dart-define` values, browser code, or a built web asset.

The backend also needs:

- `SUPABASE_URL`
- `SUPABASE_KEY` set to the Supabase server-side service-role/secret key, because these tables are backend-only under RLS.
- `INTERNAL_API_KEY`, matching the Flutter app's backend API key.
- `ALLOWED_ORIGINS` including the exact production web origin. For local Flutter development, the example config permits localhost ports.

Do not paste any `.env` values into issues, chat, logs, or documentation. If a real password or secret was previously placed in the Flutter `.env`, remove it and rotate it.

### 3. Run locally

Start the backend in one PowerShell terminal:

```powershell
Set-Location 'C:\dev\senior-capstone\python'
.\venv\windows\Scripts\Activate.ps1
python server.py
```

Start Flutter in a separate terminal; the Python environment is not needed for Flutter:

```powershell
Set-Location 'C:\dev\senior-capstone\ssdemo_1'
flutter run -d chrome --web-port 53000
```

Sign in, open Wallet → Settings, and enable Browser notifications. Allow notifications for the local origin in Chrome and in Windows notification settings. `localhost` is a secure context for browser APIs. For production, host the Flutter app on HTTPS.

### 4. Schedule monthly reports

For production, configure an hourly Render Cron Job using the same backend dependencies and secrets:

- Working directory: `python`
- Command: `python scripts/send_monthly_reports.py`
- Schedule: `0 * * * *` (hourly UTC)

The script sends the monthly report only when its current local time is the first day of a month at 9 AM America/New_York. It also drains queued notifications when run. Do not expect a report immediately after subscribing.

## Testing

### Automated checks completed during implementation

- Push notification and route tests: 16 passed in the last focused run.
- User-model tests: 25 passed.
- Route inventory tests: 3 passed.
- Budget snapshot regression tests: 11 passed.
- Flutter analysis of the changed snapshot files passed.
- Browser JavaScript syntax checks passed before the final budget-display-only change.

The full Python suite had one unrelated date-sensitive AI-summary test failure in its run; the focused push, user-model, and route tests passed. Real Web Push was not exercised against a live Supabase database and subscribed Chrome browser in that automated run.

### Manual smoke test

1. Apply the migration and configure the backend secrets above.
2. Start the backend and Flutter web app.
3. In Chrome, sign in and enable Browser notifications. Accept the permission prompt.
4. Verify in Supabase that a row for this user/device appears in `push_subscriptions`. Do not copy or share the endpoint or key values.
5. Trigger a qualifying event and wait for the backend sync/recompute:
   - create a new budget alert (saving a budget alone is not necessarily an alert);
   - leave a low-confidence or uncategorized transaction unresolved; or
   - leave a subscription marked as needing confirmation.
6. Confirm a queue record appears in `notification_deliveries`, reaches `sent`, and Chrome/Windows displays the generic notification.
7. Click it and confirm the app opens the intended section.
8. Disable Browser notifications in app Settings and confirm the current browser subscription is removed from the backend and unsubscribed in the browser.

Do not use a real user's financial transactions as test data if you can instead use a test account. Avoid sharing the notification endpoint, encryption keys, VAPID private key, Supabase service-role key, or user transaction details.

## Current limitations and behavior to expect

- **Chrome scope:** the backend currently validates Chrome's FCM endpoint format. Other browser push providers/endpoints are rejected; native mobile notifications are not implemented here.
- **Not immediate on opt-in:** enabling notifications registers the browser; it does not display a demo notification. Existing open review/budget items can be considered on registration, but delivery still requires working VAPID, Supabase, permission, and push infrastructure.
- **Budget alerts require alert computation:** simply editing or saving a budget does not guarantee a notification. A new/reopened/escalated alert must be computed during backend refresh.
- **Monthly timing:** monthly reports require the external hourly cron job. Without that scheduler, they are not generated automatically.
- **Network and OS controls:** Chrome permission, Windows notification settings, focus/quiet modes, browser policies, and device connectivity can suppress or delay visible notifications.
- **Push is best effort:** network/provider errors are retried up to five delivery attempts. Expired endpoints (HTTP 404/410) are removed. A push service does not guarantee that a device visibly displays every message.
- **Queue and subscription caps:** delivery processing is bounded per run, and the backend keeps a maximum of 20 subscriptions per user for delivery. Subscription/review candidate scans are bounded to 500 records.
- **Already-sent events are not replayed:** the queue is idempotent per user/event. Registering another browser later does not replay delivery records already marked sent.
- **Background operation requires hosted infrastructure:** local Chrome on `localhost` can use service workers and notifications, but background push delivery depends on the browser provider and a reachable backend. Production requires HTTPS and the correctly configured backend.
- **No live deployment was changed:** the migration has not been applied to Supabase, VAPID keys have not been generated/configured by this code change, and no production cron job was created.

## Related API routes

- `GET /api/push/config` — authenticated; returns whether push is configured and the public VAPID key only.
- `POST /api/push/subscriptions` — authenticated; validates and stores the current browser subscription, then attempts to process pending notifications.
- `DELETE /api/push/subscriptions` — authenticated; removes the current browser endpoint for the signed-in user.
