-- Normalize rule_key so equivalent variants map to one canonical key.
-- Example: "income_salary" and "income salary" become "income salary".

-- 1) Delete duplicates after normalization (keep newest row per group).
with normalized as (
  select
    id,
    user_id,
    lower(regexp_replace(rule_key, '[_\s]+', ' ', 'g')) as canonical_key,
    row_number() over (
      partition by user_id, lower(regexp_replace(rule_key, '[_\s]+', ' ', 'g'))
      order by updated_at desc nulls last, created_at desc nulls last, id desc
    ) as rn
  from public.category_match_rules
)
delete from public.category_match_rules t
using normalized n
where t.id = n.id
  and n.rn > 1;

-- 2) Update remaining rows to canonical key.
with normalized as (
  select
    id,
    lower(regexp_replace(rule_key, '[_\s]+', ' ', 'g')) as canonical_key
  from public.category_match_rules
)
update public.category_match_rules t
set rule_key = n.canonical_key
from normalized n
where t.id = n.id
  and t.rule_key is distinct from n.canonical_key;
