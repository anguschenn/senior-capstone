-- 010_drop_merchant_category_rules.sql
--
-- Drops merchant_category_rules. Confirmed empty in the live project on
-- 2026-09-17, and referenced by no application code — CategoryService uses
-- category_match_rules (user_id, rule_key) -> category name, which stays.
--
-- Migration 009 creates this table so that a database built from the repo
-- matches production; this removes it from both. 009 is left untouched so the
-- history stays honest about what production looked like at the time.

begin;

-- Guard: refuse to drop if anyone has written rows since the check.
do $$
declare
  n bigint;
begin
  if to_regclass('public.merchant_category_rules') is null then
    raise notice '010: merchant_category_rules already absent, nothing to do';
    return;
  end if;

  execute 'select count(*) from public.merchant_category_rules' into n;
  if n > 0 then
    raise exception
      '010: merchant_category_rules has % row(s); refusing to drop. Inspect the data and drop manually if it is disposable.', n;
  end if;

  drop policy if exists "Users can manage own merchant category rules" on public.merchant_category_rules;
  drop table public.merchant_category_rules;
  raise notice '010: dropped merchant_category_rules';
end $$;

commit;
