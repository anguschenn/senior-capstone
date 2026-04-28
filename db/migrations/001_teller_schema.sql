-- Run this in Supabase SQL Editor if a new environment is missing Teller tables.
-- Your current Supabase project already has these tables.

create table if not exists teller_enrollments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  teller_enrollment_id text unique,
  access_token text not null,
  institution_id text,
  institution_name text,
  last_synced_at timestamp,
  created_at timestamp default now()
);

create table if not exists teller_accounts (
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

create table if not exists teller_transactions (
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
