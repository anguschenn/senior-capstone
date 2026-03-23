-- Users Table, no access-token
create table users (
  id uuid primary key default gen_random_uuid(),
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
  custom_category_id uuid references categories(id),
  
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
  month_year text not null
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