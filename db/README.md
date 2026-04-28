# SmartSpend Database Setup

## First Time Setup
1. Go to https://supabase.com and create a new project.
2. Open SQL Editor.
3. Copy and run `schema.sql`.
4. Add the project URL and publishable key to both `.env` files.

## Migrating The Current Project To Teller
The current Supabase project already has the Teller-backed tables:
`teller_enrollments`, `teller_accounts`, and `teller_transactions`.

For a fresh environment, run `migrations/001_teller_schema.sql` in Supabase SQL
Editor after creating `users` and `categories`.

## Supabase Credentials Needed
Add these to `python/.env` and `ssdemo_1/.env`:

```env
SUPABASE_URL=https://your-project-ref.supabase.co
SUPABASE_KEY=your_publishable_key
```

The Flutter app also needs:

```env
BACKEND_URL=http://localhost:8000
BACKEND_API_KEY=your_internal_api_key
DEMO_USER_ID=your_demo_user_uuid
```

The Python backend also needs:

```env
INTERNAL_API_KEY=your_internal_api_key
DEMO_USER_ID=your_demo_user_uuid
DEMO_BANK_CONNECTION_ID=your_teller_enrollments_row_uuid
TELLER_ENV=sandbox
```

For Teller development/production, also configure:

```env
TELLER_CERT_PATH=/absolute/path/to/cert.pem
TELLER_KEY_PATH=/absolute/path/to/key.pem
```

## Notes
- Never commit actual `.env` files.
- `access_token` in `teller_enrollments` is sensitive. Never log or expose it.
- `BACKEND_URL` is the Python service base URL used by the Flutter app.

## Local Backend
Start the backend with the repo script so you always use the correct virtualenv:

```sh
./scripts/dev_backend.sh
```
