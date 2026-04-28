alter table if exists public.category_rules
  add column if not exists confidence text not null default 'medium';
