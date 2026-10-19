-- 013_ai_chat_messages.sql
--
-- The AI assistant's chat history, one row per answered question, so a user
-- sees their conversation again after a reload or on another device. Kept per
-- user and account scope ('all' or a Plaid account id); only the newest 30
-- questions per scope are kept (trigger below).
--
-- The app reads and writes its own rows directly; RLS limits every user to
-- their own. No UPDATE policy: a saved answer is never edited.
--
-- Idempotent and safe to re-run. Apply in the Supabase SQL editor.

begin;

create table if not exists public.ai_chat_messages (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid()
                references public.users(id) on delete cascade,
  account_scope text not null check (char_length(account_scope) between 1 and 128),
  prompt        text not null check (char_length(prompt) between 1 and 2000),
  response      jsonb not null,
  asked_at      timestamptz not null default now()
);

create index if not exists ai_chat_messages_user_scope_asked_idx
  on public.ai_chat_messages (user_id, account_scope, asked_at desc);

alter table public.ai_chat_messages enable row level security;

drop policy if exists "Users can view own chat messages"   on public.ai_chat_messages;
drop policy if exists "Users can add own chat messages"    on public.ai_chat_messages;
drop policy if exists "Users can delete own chat messages" on public.ai_chat_messages;
create policy "Users can view own chat messages"
  on public.ai_chat_messages for select to authenticated using (user_id = auth.uid());
create policy "Users can add own chat messages"
  on public.ai_chat_messages for insert to authenticated with check (user_id = auth.uid());
create policy "Users can delete own chat messages"
  on public.ai_chat_messages for delete to authenticated using (user_id = auth.uid());

-- Keep the newest 30 questions per user and scope. Runs as the inserting user,
-- so RLS still applies: it can only ever delete that user's own rows.
create or replace function public.trim_ai_chat_messages()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  delete from public.ai_chat_messages
   where user_id = new.user_id
     and account_scope = new.account_scope
     and id not in (
       select id from public.ai_chat_messages
        where user_id = new.user_id and account_scope = new.account_scope
        order by asked_at desc
        limit 30
     );
  return null;
end;
$function$;

drop trigger if exists trim_ai_chat_messages on public.ai_chat_messages;
create trigger trim_ai_chat_messages
  after insert on public.ai_chat_messages
  for each row execute function public.trim_ai_chat_messages();

commit;
