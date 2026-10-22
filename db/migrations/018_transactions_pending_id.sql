-- 018_transactions_pending_id.sql
--
-- When a pending transaction posts, Plaid removes the pending one and adds the
-- posted one under a NEW transaction_id; the posted one names the old id in
-- pending_transaction_id. The sync stores that id here and moves the user's
-- choices (transaction_decisions: a category pick, a payback link, an AA mark)
-- from the pending id to the posted id before the pending row is deleted
-- (python/plaid_sync.py _repoint_decisions), so a friend's payback linked to a
-- still-pending dinner keeps counting once the dinner posts.
--
-- Add-only: the column is null for every existing row and for transactions
-- that were never pending.
--
-- Idempotent and safe to re-run. Apply in the Supabase SQL editor.

begin;

alter table public.transactions
  add column if not exists pending_transaction_id text;

commit;
