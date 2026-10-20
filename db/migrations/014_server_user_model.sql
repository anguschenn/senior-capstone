-- 014_server_user_model.sql
--
-- Server-owned derived state, rebuilt by the backend after every bank sync
-- (python/user_model.py, called from sync_jobs.run_post_sync), so budgets,
-- alerts and the chat have numbers ready without the app being open.
--
--   category_month_stats  spend per user, month and budget category
--   budget_alerts         this month's at-risk budget categories
--   budget_suggestions    suggested monthly limits awaiting the user's decision
--   chat_question_log     masked chat questions and how they were answered
--   chat_rewrite_cache    model rewrites of chat wordings the rules didn't know
--
-- Only the backend (service_role, which bypasses RLS) inserts rows. The app may
-- read its own stats, alerts and suggestions, dismiss its own alerts and record
-- its decision on its own suggestions. The two chat tables have RLS on and no
-- policies: nothing but the backend can read or write them.
--
-- Idempotent and safe to re-run. Apply in the Supabase SQL editor.

begin;

-- ── category_month_stats ───────────────────────────────────────────────
-- Categories are the Budget page's buckets (python/budget_progress.py), so
-- these rows line up with budget rows by category name.
create table if not exists public.category_month_stats (
  user_id    uuid not null references public.users(id) on delete cascade,
  month      text not null check (month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  category   text not null check (char_length(category) between 1 and 64),
  spent      numeric(12, 2) not null default 0,
  tx_count   integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, month, category)
);

alter table public.category_month_stats enable row level security;

drop policy if exists "Users can view own category month stats" on public.category_month_stats;
create policy "Users can view own category month stats"
  on public.category_month_stats for select to authenticated using (user_id = auth.uid());

-- ── budget_alerts ──────────────────────────────────────────────────────
-- One row per user, month and budget category; kind is the current severity.
-- resolved_at is set when the category stops being at risk. notified_at is
-- for a future push sender, so each escalation is sent once.
create table if not exists public.budget_alerts (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references public.users(id) on delete cascade,
  month               text not null check (month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  category_id         uuid not null references public.categories(id) on delete cascade,
  category            text not null,
  kind                text not null check (kind in ('approaching', 'projected_over', 'over_budget')),
  spent               numeric(12, 2) not null,
  limit_amount        numeric(12, 2) not null,
  projected_month_end numeric(12, 2),
  used_ratio          numeric(8, 4) not null,
  first_detected_at   timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  resolved_at         timestamptz,
  dismissed_at        timestamptz,
  notified_at         timestamptz,
  unique (user_id, month, category_id)
);

create index if not exists budget_alerts_user_open_idx
  on public.budget_alerts (user_id, month) where resolved_at is null;

alter table public.budget_alerts enable row level security;

drop policy if exists "Users can view own budget alerts"    on public.budget_alerts;
drop policy if exists "Users can dismiss own budget alerts" on public.budget_alerts;
create policy "Users can view own budget alerts"
  on public.budget_alerts for select to authenticated using (user_id = auth.uid());
create policy "Users can dismiss own budget alerts"
  on public.budget_alerts for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- The app may only set dismissed_at; every other column is the backend's.
revoke update on public.budget_alerts from authenticated, anon;
grant update (dismissed_at) on public.budget_alerts to authenticated;

-- ── budget_suggestions ─────────────────────────────────────────────────
-- Product rule: a limit never changes without the user's approval. The backend
-- writes 'pending' rows and never touches a decided one; the app records the
-- decision here and changes the budget row itself.
create table if not exists public.budget_suggestions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users(id) on delete cascade,
  budget_id       uuid not null references public.budgets(id) on delete cascade,
  category_id     uuid not null references public.categories(id) on delete cascade,
  category        text not null,
  month           text not null check (month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  current_limit   numeric(12, 2) not null,
  suggested_limit numeric(12, 2) not null check (suggested_limit >= 0),
  basis           jsonb not null default '{}'::jsonb,
  status          text not null default 'pending'
                  check (status in ('pending', 'accepted', 'edited', 'dismissed')),
  decided_limit   numeric(12, 2),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  decided_at      timestamptz,
  unique (user_id, category_id, month)
);

alter table public.budget_suggestions enable row level security;

drop policy if exists "Users can view own budget suggestions"   on public.budget_suggestions;
drop policy if exists "Users can decide own budget suggestions" on public.budget_suggestions;
create policy "Users can view own budget suggestions"
  on public.budget_suggestions for select to authenticated using (user_id = auth.uid());
create policy "Users can decide own budget suggestions"
  on public.budget_suggestions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- The app may only record its decision; the suggestion itself is the backend's.
revoke update on public.budget_suggestions from authenticated, anon;
grant update (status, decided_limit, decided_at) on public.budget_suggestions to authenticated;

-- ── chat_question_log ──────────────────────────────────────────────────
-- Masked wording only (ai/question_log.py): no user id, no account, no amounts.
create table if not exists public.chat_question_log (
  id            bigint generated always as identity primary key,
  asked_at      timestamptz not null default now(),
  question      text not null check (char_length(question) between 1 and 300),
  intent        text not null default '',
  answer_source text not null default '',
  outcome       text not null check (outcome in ('answered', 'rewritten', 'partial', 'unclear', 'error')),
  missing       text not null default ''
);

create index if not exists chat_question_log_asked_idx
  on public.chat_question_log (asked_at desc);

alter table public.chat_question_log enable row level security;

-- ── chat_rewrite_cache ─────────────────────────────────────────────────
-- question_key is the normalized wording; only wordings with nothing masked
-- (no amounts, emails or long numbers) are stored.
create table if not exists public.chat_rewrite_cache (
  question_key text primary key check (char_length(question_key) between 1 and 300),
  rewritten    text not null check (char_length(rewritten) between 1 and 160),
  hits         integer not null default 0,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);

alter table public.chat_rewrite_cache enable row level security;

commit;
