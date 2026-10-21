-- 016_accounts_hidden.sql
--
-- Accounts the user hid in Settings (swipe left). A hidden account is treated
-- as never linked: the backend leaves its transactions out of budgets, alerts,
-- suggestions and chat answers (python/budget_progress.py
-- fetch_hidden_account_ids). Showing it again sets the flag back to false.
--
-- Add-only: the new column defaults to false, so code that doesn't know about
-- it keeps working. Plaid sync upserts accounts with its own columns only, so
-- it never resets the flag.
--
-- accounts stays read-only to the client except for this one column: the
-- table-wide UPDATE privilege is revoked and only UPDATE (hidden) is granted,
-- and the policy limits it to the user's own rows. Balances are still written
-- only by the backend (service_role).
--
-- Idempotent and safe to re-run. Apply in the Supabase SQL editor.

begin;

alter table public.accounts
  add column if not exists hidden boolean not null default false;

revoke update on public.accounts from anon, authenticated;
grant update (hidden) on public.accounts to authenticated;

drop policy if exists "Users can hide own accounts" on public.accounts;
create policy "Users can hide own accounts"
  on public.accounts for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

commit;
