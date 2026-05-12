-- Temporarily disable the composite transaction de-dupe rule.
-- This index treats rows with the same account, date, amount, and name as duplicates,
-- which can block legitimate Plaid rows when the same merchant/amount appears again.
drop index if exists public.transactions_account_date_amount_name_key;

-- To re-enable later, run:
-- create unique index if not exists transactions_account_date_amount_name_key
--   on public.transactions using btree (plaid_account_id, date, amount, name)
--   tablespace pg_default;
