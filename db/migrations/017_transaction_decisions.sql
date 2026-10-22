-- 017_transaction_decisions.sql
--
-- Per-transaction choices the user makes about money shared with other people
-- (Zelle, Venmo, PayPal, Cash App, Apple Cash). One row per transaction:
--
--   paid_back_purchase_id  this incoming payment pays back that purchase; it
--                          counts in the purchase's month and category.
--   category               this incoming payment is not a payback; it counts
--                          in this category in the month it arrived.
--   shared_amount          this purchase was split (AA); others will pay back
--                          this much, so only the rest counts as the user's.
--
-- Incoming person-to-person payments never use name-based rules
-- (category_match_rules): the same friend may pay back a meal one week and a
-- ride the next, so each one is decided on its own.
--
-- The app reads and writes its own rows directly; RLS limits every user to
-- their own. The backend reads them with service_role.
--
-- Idempotent and safe to re-run. Apply in the Supabase SQL editor.

begin;

create table if not exists public.transaction_decisions (
  user_id               uuid not null default auth.uid()
                        references public.users(id) on delete cascade,
  plaid_transaction_id  text not null check (char_length(plaid_transaction_id) between 1 and 128),
  category              text check (category is null or char_length(category) between 1 and 64),
  paid_back_purchase_id text check (paid_back_purchase_id is null or char_length(paid_back_purchase_id) between 1 and 128),
  shared_amount         numeric(12,2) check (shared_amount is null or shared_amount > 0),
  updated_at            timestamptz not null default now(),
  primary key (user_id, plaid_transaction_id)
);

alter table public.transaction_decisions enable row level security;

drop policy if exists "Users can view own transaction decisions"   on public.transaction_decisions;
drop policy if exists "Users can add own transaction decisions"    on public.transaction_decisions;
drop policy if exists "Users can change own transaction decisions" on public.transaction_decisions;
drop policy if exists "Users can delete own transaction decisions" on public.transaction_decisions;
create policy "Users can view own transaction decisions"
  on public.transaction_decisions for select to authenticated using (user_id = auth.uid());
create policy "Users can add own transaction decisions"
  on public.transaction_decisions for insert to authenticated with check (user_id = auth.uid());
create policy "Users can change own transaction decisions"
  on public.transaction_decisions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Users can delete own transaction decisions"
  on public.transaction_decisions for delete to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on public.transaction_decisions to authenticated;

commit;
