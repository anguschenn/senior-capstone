-- Browser push endpoints are secrets: only the service-role backend may read
-- them or send a notification to them. Each browser/device gets its own row.
begin;

create table if not exists public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade,
  endpoint    text not null unique check (char_length(endpoint) between 1 and 2048),
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;
grant all on public.push_subscriptions to service_role;

-- Durable queue and idempotency key prevent repeated syncs from repeating pushes.
create table if not exists public.notification_deliveries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade,
  event_key   text not null check (char_length(event_key) between 1 and 512),
  kind        text not null check (
    kind in ('budget_alert', 'subscription_review', 'transaction_review', 'monthly_report')
  ),
  title       text not null check (char_length(title) between 1 and 120),
  body        text not null check (char_length(body) between 1 and 240),
  url         text not null check (char_length(url) between 1 and 512),
  status      text not null default 'pending'
              check (status in ('pending', 'sending', 'sent', 'failed')),
  attempts    integer not null default 0 check (attempts >= 0),
  last_error  text,
  created_at  timestamptz not null default now(),
  claimed_at  timestamptz,
  sent_at     timestamptz,
  unique (user_id, event_key)
);

create index if not exists notification_deliveries_pending_idx
  on public.notification_deliveries (user_id, created_at)
  where status = 'pending';

alter table public.notification_deliveries enable row level security;
revoke all on public.notification_deliveries from anon, authenticated;
grant all on public.notification_deliveries to service_role;

commit;
