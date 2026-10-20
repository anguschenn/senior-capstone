-- Users Table, no access-token
create table users (
  -- Mirrors auth.users. Rows are created by the handle_new_user() trigger
  -- (migration 009), never by the client.
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  name text,
  created_at timestamp default now()
);

-- NEW: One row per connected bank (replaces storing token on users)
create table plaid_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  access_token text not null,      -- secret, never send to Flutter frontend
  item_id text unique not null,    -- Plaid's identifier for this bank connection
  institution_id text,
  institution_name text,
  cursor text,                     -- for /transactions/sync pagination
  last_synced_at timestamp,
  created_at timestamp default now()
);

-- Accounts
create table accounts (
  id uuid primary key default gen_random_uuid(),
  plaid_item_id uuid references plaid_items(id) on delete cascade,
  user_id uuid references users(id) on delete cascade,
  plaid_account_id text unique not null,
  name text,
  official_name text,
  account_type text,               -- depository, credit, loan, investment
  subtype text,                    -- checking, savings, credit card, etc.
  current_balance decimal,
  available_balance decimal,
  mask text,                       -- last 4 digits, safe to show in UI
  updated_at timestamp default now()
);

-- Categories (hybrid: Plaid's system + your custom ones)
create table categories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id),  -- NULL = global/Plaid category
  name text not null,
  parent_category text,
  is_custom boolean default false,    -- true = user-created
  icon_url text,
  color_hex text
);

-- Transactions (expanded to match Plaid's actual response)
create table transactions (
  id uuid primary key default gen_random_uuid(),
  plaid_account_id text references accounts(plaid_account_id),
  user_id uuid references users(id) on delete cascade,
  plaid_transaction_id text unique not null,
  amount decimal not null,
  date date not null,
  name text,                            -- raw name Plaid returns
  merchant_name text,                   -- cleaned merchant name
  
  -- Plaid's legacy category (still widely used)
  category text,                        -- e.g. "Food and Drink"
  category_id text,                     -- Plaid's own category ID
  
  -- Plaid's NEW category system (better, use this for AI)
  pfc_primary text,                     -- e.g. "FOOD_AND_DRINK"
  pfc_detailed text,                    -- e.g. "FOOD_AND_DRINK_FAST_FOOD"
  pfc_confidence text,                  -- VERY_HIGH, HIGH, MEDIUM, LOW
  
  -- Your custom override (user can recategorize)
  custom_category_id uuid references categories(id),   -- user override
  ai_category_id uuid references categories(id),       -- AI suggestion
  
  -- Location data Plaid sometimes returns
  location_city text,
  location_region text,
  location_lat decimal,
  location_lon decimal,
  
  pending boolean default false,
  user_note text,                       -- your teammate's good idea, kept
  created_at timestamp default now()
);

-- Budgets
create table budgets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  category_id uuid references categories(id),
  monthly_limit decimal not null,
  rollover_amount decimal default 0,
  month_year text not null,
  unique (user_id, category_id, month_year)
);

-- Subscriptions
create table subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  plaid_account_id text references accounts(plaid_account_id),
  merchant_name text,
  amount decimal,
  frequency text,                      -- monthly, weekly, annual
  next_charge_date date,
  is_active boolean default true
);

create table category_match_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  rule_key text not null,
  category text not null,
  confidence text not null default 'high',
  created_at timestamp default now(),
  updated_at timestamp default now(),
  unique (user_id, rule_key)
);

-- Last successful bank sync per user (webhook or app). Readable by the app so it
-- can skip the launch sync when data is fresh; see migrations/012_sync_status.sql.
create table sync_status (
  user_id uuid primary key references users(id) on delete cascade,
  last_synced_at timestamptz not null,
  source text not null check (source in ('webhook', 'app'))
);

-- AI assistant chat history, newest 30 questions per user and account scope;
-- see migrations/013_ai_chat_messages.sql for RLS and the trimming trigger.
create table ai_chat_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  account_scope text not null,
  prompt text not null,
  response jsonb not null,
  asked_at timestamptz not null default now()
);

-- Server-owned derived state, rebuilt after every sync (python/user_model.py); see
-- migrations/014_server_user_model.sql for RLS, column grants and checks.
create table category_month_stats (
  user_id uuid not null references users(id) on delete cascade,
  month text not null,
  category text not null,
  spent numeric(12, 2) not null default 0,
  tx_count integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, month, category)
);

create table budget_alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  month text not null,
  category_id uuid not null references categories(id) on delete cascade,
  category text not null,
  kind text not null,                -- approaching | projected_over | over_budget
  spent numeric(12, 2) not null,
  limit_amount numeric(12, 2) not null,
  projected_month_end numeric(12, 2),
  used_ratio numeric(8, 4) not null,
  first_detected_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz,
  dismissed_at timestamptz,
  notified_at timestamptz,
  unique (user_id, month, category_id)
);

create table budget_suggestions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  budget_id uuid not null references budgets(id) on delete cascade,
  category_id uuid not null references categories(id) on delete cascade,
  category text not null,
  month text not null,
  current_limit numeric(12, 2) not null,
  suggested_limit numeric(12, 2) not null,
  basis jsonb not null default '{}'::jsonb,
  status text not null default 'pending',  -- pending | accepted | edited | dismissed
  decided_limit numeric(12, 2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz,
  unique (user_id, category_id, month)
);

-- Backend-only (RLS on, no policies): masked chat questions and cached rewrites.
create table chat_question_log (
  id bigint generated always as identity primary key,
  asked_at timestamptz not null default now(),
  question text not null,
  intent text not null default '',
  answer_source text not null default '',
  outcome text not null,
  missing text not null default ''
);

create table chat_rewrite_cache (
  question_key text primary key,
  rewritten text not null,
  hits integer not null default 0,
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Row-level security, the auth.users -> public.users trigger, NOT NULL
-- constraints and indexes all live in db/migrations/009_security_model.sql.
-- Run every migration in order after applying this file; this schema alone is
-- NOT safe to expose to the Flutter client.
-- ─────────────────────────────────────────────────────────────────────────────
