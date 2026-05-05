-- 1) Keep only the newest row per (user_id, rule_key)
with ranked as (
  select
    ctid,
    row_number() over (
      partition by user_id, rule_key
      order by updated_at desc nulls last, created_at desc nulls last, id desc
    ) as rn
  from public.category_match_rules
)
delete from public.category_match_rules t
using ranked r
where t.ctid = r.ctid
  and r.rn > 1;

-- 2) Enforce uniqueness for future writes
create unique index if not exists idx_category_match_rules_user_rule_key_unique
  on public.category_match_rules (user_id, rule_key);

-- 3) Helpful query index for read path
create index if not exists idx_category_match_rules_user
  on public.category_match_rules (user_id);
