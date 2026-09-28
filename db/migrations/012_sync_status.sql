-- 012_sync_status.sql
--
-- When each user's bank data was last synced with Plaid, by any path (the Plaid
-- webhook or the app's sync call). The app reads its own row straight from
-- Supabase on launch and skips the bank-sync round trip to the backend when the
-- data is fresh, so Render never has to wake up just to confirm nothing changed.
--
-- Why not plaid_items.last_synced_at: plaid_items holds access tokens and is
-- deliberately unreadable by the app (see 009). This table holds nothing secret.
--
-- Idempotent and safe to re-run. Apply in the Supabase SQL editor.

begin;

create table if not exists public.sync_status (
  user_id        uuid primary key references public.users(id) on delete cascade,
  last_synced_at timestamptz not null,
  source         text not null check (source in ('webhook', 'app'))
);

alter table public.sync_status enable row level security;

-- Read your own row only. No INSERT/UPDATE/DELETE policies: only the backend
-- (service_role, which bypasses RLS) writes here, so a client cannot fake a
-- fresh sync time to suppress its own sync.
drop policy if exists "Users can view own sync status" on public.sync_status;
create policy "Users can view own sync status"
  on public.sync_status for select to authenticated using (user_id = auth.uid());

commit;
