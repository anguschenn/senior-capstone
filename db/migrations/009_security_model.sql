-- 009_security_model.sql
--
-- Brings a database built from schema.sql + migrations 002..008 in line with the
-- live Supabase project as of 2026-09-17. Everything here is idempotent and safe
-- to re-run, including against the live project.
--
-- Summary:
--   1. auth.users -> public.users provisioning via trigger (replaces the old
--      client-side upsert in AuthService.ensurePublicUserRecord)
--   2. public.users.id is now a real FK to auth.users(id)
--   3. RLS policies scoped to the `authenticated` role, least-privilege per table
--   4. NOT NULL on user-owned scoping columns
--   5. Unique constraint on (user_id, category_id, month_year) for budgets
--   6. Schema drift picked up from the live project (ai_category_id,
--      merchant_category_rules, dropped category_rules)
--   7. Redundant index removed

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. User provisioning
-- ─────────────────────────────────────────────────────────────────────────────

-- NOTE: hardened relative to the live version with `on conflict (id) do nothing`.
-- Without it, any pre-existing public.users row (a hand-created account, a retry,
-- a race) raises a unique violation inside the trigger, which aborts the whole
-- auth.users insert and fails signup with an opaque error.
--
-- Caveat left in place deliberately: public.users.email is NOT NULL, so a signup
-- with no email address (phone or certain OAuth providers) will still fail here.
-- That is correct for SmartSpend today, which is email/password only.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.users (id, email, name)
  values (new.id, new.email, new.raw_user_meta_data->>'name')
  on conflict (id) do nothing;

  return new;
end;
$function$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. public.users.id -> auth.users.id
-- ─────────────────────────────────────────────────────────────────────────────

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'users_id_fkey' and conrelid = 'public.users'::regclass
  ) then
    alter table public.users
      add constraint users_id_fkey
      foreign key (id) references auth.users(id) on delete cascade;
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Row-level security
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.users                enable row level security;
alter table public.plaid_items          enable row level security;
alter table public.accounts             enable row level security;
alter table public.transactions         enable row level security;
alter table public.categories           enable row level security;
alter table public.budgets              enable row level security;
alter table public.subscriptions        enable row level security;
alter table public.category_match_rules enable row level security;

-- users: read and update your own row. No INSERT policy — rows come from the
-- trigger above, which runs as SECURITY DEFINER and bypasses RLS. No DELETE
-- policy — deletion cascades from auth.users.
drop policy if exists "Users can view own row"   on public.users;
drop policy if exists "Users can update own row" on public.users;
create policy "Users can view own row"   on public.users for select to authenticated using (id = auth.uid());
create policy "Users can update own row" on public.users for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- plaid_items: NO policies, deliberately. RLS is on and nothing is granted, so
-- the anon/authenticated client cannot read access_token under any query. The
-- Flask backend reaches this table with the service_role key, which bypasses RLS.
-- Do not add a policy here.

-- accounts: read-only to the client. Balances are written by the backend during sync.
drop policy if exists "Users can read own accounts" on public.accounts;
create policy "Users can read own accounts" on public.accounts for select to authenticated using (user_id = auth.uid());

-- transactions: read plus update only. Inserts and deletes belong to the Plaid
-- sync path on the backend; the client only edits categories and notes.
drop policy if exists "Users can read own transactions"   on public.transactions;
drop policy if exists "Users can update own transactions" on public.transactions;
create policy "Users can read own transactions"   on public.transactions for select to authenticated using (user_id = auth.uid());
create policy "Users can update own transactions" on public.transactions for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- categories: global rows (user_id is null) are readable by everyone but writable
-- by no one; user-owned rows are fully manageable by their owner.
drop policy if exists "Users can read categories"       on public.categories;
drop policy if exists "Users can create own categories" on public.categories;
drop policy if exists "Users can update own categories" on public.categories;
drop policy if exists "Users can delete own categories" on public.categories;
create policy "Users can read categories"       on public.categories for select to authenticated using (user_id = auth.uid() or user_id is null);
create policy "Users can create own categories" on public.categories for insert to authenticated with check (user_id = auth.uid());
create policy "Users can update own categories" on public.categories for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Users can delete own categories" on public.categories for delete to authenticated using (user_id = auth.uid());

-- budgets: fully user-owned.
drop policy if exists "Users can manage own budgets" on public.budgets;
create policy "Users can manage own budgets" on public.budgets for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- subscriptions: read, insert and update. No DELETE policy — the app dismisses a
-- subscription by setting is_active = false, never by deleting the row.
drop policy if exists users_read_own_subscriptions   on public.subscriptions;
drop policy if exists users_insert_own_subscriptions on public.subscriptions;
drop policy if exists users_update_own_subscriptions on public.subscriptions;
create policy users_read_own_subscriptions   on public.subscriptions for select to authenticated using (auth.uid() = user_id);
create policy users_insert_own_subscriptions on public.subscriptions for insert to authenticated with check (auth.uid() = user_id);
create policy users_update_own_subscriptions on public.subscriptions for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- category_match_rules: fully user-owned; this is the learned merchant -> category map.
drop policy if exists "Users can manage own category match rules" on public.category_match_rules;
create policy "Users can manage own category match rules" on public.category_match_rules for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ─────────────────────────────────────────────────────────────────────────────
-- 3b. Safety net: auto-enable RLS on any new public table
-- ─────────────────────────────────────────────────────────────────────────────
-- Catches the case where someone adds a table and forgets to enable RLS, which
-- would otherwise leave it fully readable through the anon key. It only enables
-- RLS; it does not create policies, so a new table starts locked down with no
-- access until policies are written for it.
--
-- Creating an event trigger needs elevated privileges. It works from the Supabase
-- SQL editor (which runs as `postgres`); on a plain Postgres instance without a
-- superuser role this whole block can be skipped without affecting anything else.

create or replace function public.rls_auto_enable()
returns event_trigger
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  cmd record;
begin
  for cmd in
    select *
      from pg_event_trigger_ddl_commands()
     where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
       and object_type in ('table', 'partitioned table')
  loop
    if cmd.schema_name = 'public' then
      begin
        execute format('alter table if exists %s enable row level security', cmd.object_identity);
        raise log 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      exception
        when others then
          raise log 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      end;
    else
      raise log 'rls_auto_enable: skipped % (schema %)', cmd.object_identity, cmd.schema_name;
    end if;
  end loop;
end;
$function$;

drop event trigger if exists ensure_rls;
create event trigger ensure_rls
  on ddl_command_end
  execute function public.rls_auto_enable();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. NOT NULL on scoping columns
-- ─────────────────────────────────────────────────────────────────────────────
-- Verified to contain no nulls before applying. categories.user_id stays nullable
-- on purpose: null means a global/default category.

alter table public.accounts             alter column user_id set not null;
alter table public.budgets              alter column user_id set not null;
alter table public.category_match_rules alter column user_id set not null;
alter table public.plaid_items          alter column user_id set not null;
alter table public.subscriptions        alter column user_id set not null;
alter table public.transactions         alter column user_id set not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. One budget row per category per month
-- ─────────────────────────────────────────────────────────────────────────────
-- BudgetService.ensureMonthlyBudgetRows relied on a SELECT-then-INSERT that could
-- race; this makes the invariant the database's job and lets callers upsert.

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'budgets_user_category_month_unique'
       and conrelid = 'public.budgets'::regclass
  ) then
    alter table public.budgets
      add constraint budgets_user_category_month_unique
      unique (user_id, category_id, month_year);
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Drift between schema.sql and the live project
-- ─────────────────────────────────────────────────────────────────────────────

-- Added by the AI-suggested-categories work; never made it into schema.sql.
alter table public.transactions
  add column if not exists ai_category_id uuid references public.categories(id);

-- Exists live, absent from schema.sql. No application code references it.
-- Kept so the repo reproduces production; see the note at the bottom of this file.
create table if not exists public.merchant_category_rules (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users(id),
  merchant_name text not null,
  category_id   uuid references public.categories(id),
  unique (user_id, merchant_name)
);
alter table public.merchant_category_rules enable row level security;
drop policy if exists "Users can manage own merchant category rules" on public.merchant_category_rules;
create policy "Users can manage own merchant category rules" on public.merchant_category_rules for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create index if not exists idx_merchant_category_rules_user_id on public.merchant_category_rules (user_id);

-- Defined in schema.sql but never created in the live project, and unreferenced
-- by any code. CategoryService uses category_match_rules instead.
drop table if exists public.category_rules;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Indexes
-- ─────────────────────────────────────────────────────────────────────────────

create index if not exists idx_accounts_user_id             on public.accounts (user_id);
create index if not exists idx_budgets_user_id              on public.budgets (user_id);
create index if not exists idx_categories_user_id           on public.categories (user_id);
create index if not exists idx_category_match_rules_user    on public.category_match_rules (user_id);
create index if not exists idx_plaid_items_user_id          on public.plaid_items (user_id);
create index if not exists idx_subscriptions_user_id        on public.subscriptions (user_id);
create index if not exists idx_transactions_user_date       on public.transactions (user_id, date desc);

-- Redundant: idx_transactions_user_date already covers user_id as its leading
-- column, so any plan that could use this one can use that one instead.
drop index if exists public.idx_transactions_user_id;

commit;

-- ─────────────────────────────────────────────────────────────────────────────
-- Follow-ups, deliberately not done here
-- ─────────────────────────────────────────────────────────────────────────────
-- * merchant_category_rules and its index are dead weight — nothing in
--   ssdemo_1/lib or python/ reads or writes them. Confirm there is no data worth
--   keeping, then drop the table in a later migration.
-- * public.users has no INSERT policy by design. If a future feature needs the
--   client to create user rows directly, add the policy rather than loosening
--   the trigger.
-- * Supabase's own event triggers (pgrst_ddl_watch, pgrst_drop_watch,
--   issue_pg_graphql_access, issue_graphql_placeholder, issue_pg_cron_access,
--   issue_pg_net_access) live in the `extensions` schema and are managed by the
--   platform. They are deliberately not reproduced here — do not add them.
