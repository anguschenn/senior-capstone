-- 015_budget_limit_source.sql
--
-- Who set each monthly limit, so a new month can start from sensible numbers:
--
--   'user'  the user typed it or accepted a suggestion. Carried forward to the
--           next month unchanged.
--   'auto'  the app or backend filled it in when the month's rows were created
--           (history-based, see budget_auto_limit_contract.json). Recalculated
--           from history for the next month.
--
-- Existing rows: a $0 limit was always the app's placeholder (the app created
-- every new month at $0), so those become 'auto'; anything else was set by
-- someone and stays 'user'.
--
-- Idempotent and safe to re-run. Apply in the Supabase SQL editor.

begin;

-- Classify existing rows only the first time, so a re-run never turns a $0 the
-- user set on purpose into 'auto'.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'budgets' and column_name = 'limit_source'
  ) then
    alter table public.budgets add column limit_source text not null default 'user';
    update public.budgets set limit_source = 'auto' where monthly_limit = 0;
  end if;
end $$;

alter table public.budgets drop constraint if exists budgets_limit_source_check;
alter table public.budgets
  add constraint budgets_limit_source_check check (limit_source in ('auto', 'user'));

commit;
