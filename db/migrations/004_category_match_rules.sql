create table if not exists category_match_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  rule_key text not null,
  category text not null,
  confidence text not null default 'high',
  created_at timestamp default now(),
  updated_at timestamp default now(),
  unique (user_id, rule_key)
);

create index if not exists idx_category_match_rules_user
  on category_match_rules(user_id);
