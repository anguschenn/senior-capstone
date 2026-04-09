# SmartSpend Database Setup

## First Time Setup
1. Go to https://supabase.com and create a new project
2. Once created, go to the SQL Editor (left sidebar)
3. Copy and paste the contents of `schema.sql` and hit Run
4. Ask [your name] for the project URL and anon key to add to your .env

## Supabase Credentials Needed
Add these to your `.env` file:
SUPABASE_URL=your_project_url
SUPABASE_KEY=your_anon_key
BACKEND_URL=http://localhost:8000

## Notes
- Never commit your actual .env file
- `BACKEND_URL` is the Python service base URL used by the Flutter app
- access_token in plaid_items is sensitive, never log or expose it

## Local backend
Start the backend with the repo script so you always use the correct virtualenv:
`./scripts/dev_backend.sh`
