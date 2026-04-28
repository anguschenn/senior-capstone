-- SmartSpend database schema for Teller-backed bank data.

create table users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  name text,
  created_at timestamp default now()
);

create table teller_enrollments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  teller_enrollment_id text unique,
  access_token text not null,       -- secret, never send to Flutter frontend
  institution_id text,
  institution_name text,
  last_synced_at timestamp,
  created_at timestamp default now()
);

create table teller_accounts (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid references teller_enrollments(id) on delete cascade,
  user_id uuid references users(id) on delete cascade,
  teller_account_id text unique not null,
  name text,
  account_type text,
  subtype text,
  status text,
  currency text,
  last_four text,
  institution_id text,
  institution_name text,
  ledger_balance decimal,
  available_balance decimal,
  updated_at timestamp default now()
);

create table categories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id), -- NULL = global category
  name text not null,
  parent_category text,
  is_custom boolean default false,
  icon_url text,
  color_hex text
);

create table teller_transactions (
  id uuid primary key default gen_random_uuid(),
  teller_account_id text references teller_accounts(teller_account_id),
  user_id uuid references users(id) on delete cascade,
  teller_transaction_id text unique not null,
  amount decimal not null,
  amount_abs decimal,
  is_debit boolean,
  date date not null,
  description text,
  teller_category text,
  counterparty_name text,
  counterparty_type text,
  processing_status text,
  running_balance decimal,
  transaction_type text,
  status text,
  custom_category_id uuid references categories(id),
  category_source text,
  needs_review boolean default false,
  user_note text,
  created_at timestamp default now()
);

create table budgets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  category_id uuid references categories(id),
  monthly_limit decimal not null,
  rollover_amount decimal default 0,
  month_year text not null
);

create table subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  teller_account_id text references teller_accounts(teller_account_id),
  merchant_name text,
  amount decimal,
  frequency text,                   -- monthly, weekly, annual
  next_charge_date date,
  is_active boolean default true
);

create table category_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  rule_key text not null,
  category text not null,
  confidence text not null default 'medium',
  created_at timestamp default now(),
  updated_at timestamp default now(),
  unique (user_id, rule_key)
);
