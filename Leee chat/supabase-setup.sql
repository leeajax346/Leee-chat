-- NEXUS CHAT - secure database and storage setup / migration
-- Run once in Supabase Dashboard > SQL Editor as project owner.
-- BACK UP important data before running this migration.
-- Passwords are handled ONLY by Supabase Auth. Never create a plaintext-password table.

create extension if not exists pgcrypto;

-- Public/searchable profile fields. Phone numbers are deliberately excluded.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  first_name text,
  last_name text,
  country text,
  avatar_url text,
  last_seen timestamptz default now(),
  created_at timestamptz not null default now()
);

-- Private contact details belong only to their account owner.
create table if not exists public.private_info (
  user_id uuid primary key references auth.users(id) on delete cascade,
  phone text,
  updated_at timestamptz not null default now()
);

-- Migrate phone values from an older profiles table, if that column exists, then remove it.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles' and column_name = 'phone'
  ) then
    execute $migrate$
      insert into public.private_info (user_id, phone)
      select id, phone from public.profiles where phone is not null and phone <> ''
      on conflict (user_id) do update set phone = excluded.phone, updated_at = now()
    $migrate$;
    execute 'alter table public.profiles drop column phone';
  end if;
end $$;

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id text not null,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  text text not null default '',
  media_type text not null default 'text' check (media_type in ('text','image','video','audio','file','sticker')),
  media_url text,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint messages_not_self check (sender_id <> recipient_id)
);
create index if not exists messages_conversation_created_idx on public.messages(conversation_id, created_at);
create index if not exists messages_recipient_read_idx on public.messages(recipient_id, read_at);

-- Contacts explicitly picked/imported by a user from their own device.
create table if not exists public.user_contacts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  contact_name text not null default '',
  phone text not null,
  created_at timestamptz not null default now(),
  unique(owner_id, phone)
);

create table if not exists public.moments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  video_url text not null,
  caption text not null default '' check (char_length(caption) <= 240),
  created_at timestamptz not null default now()
);
create index if not exists moments_created_idx on public.moments(created_at desc);

create table if not exists public.moment_likes (
  moment_id uuid not null references public.moments(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(moment_id, user_id)
);
create table if not exists public.moment_comments (
  id uuid primary key default gen_random_uuid(),
  moment_id uuid not null references public.moments(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists moment_comments_idx on public.moment_comments(moment_id, created_at);

-- Push subscriptions are private to the user. Actual push sending requires a configured server function + VAPID keys.
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null,
  subscription jsonb not null,
  created_at timestamptz not null default now(),
  unique(user_id, endpoint)
);

-- Create/synchronize profile and private phone details at signup; never store a password in app tables.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, first_name, last_name, country, avatar_url)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'first_name',
    new.raw_user_meta_data ->> 'last_name',
    new.raw_user_meta_data ->> 'country',
    new.raw_user_meta_data ->> 'avatar_url'
  ) on conflict (id) do update set email = excluded.email;

  insert into public.private_info as existing (user_id, phone, updated_at)
  values (new.id, new.raw_user_meta_data ->> 'phone', now())
  on conflict (user_id) do update set
    phone = coalesce(excluded.phone, existing.phone),
    updated_at = now();
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Backfill accounts created before this setup was installed.
insert into public.profiles (id, email, first_name, last_name, country, avatar_url)
select id, email, raw_user_meta_data ->> 'first_name', raw_user_meta_data ->> 'last_name',
       raw_user_meta_data ->> 'country', raw_user_meta_data ->> 'avatar_url'
from auth.users on conflict (id) do nothing;
insert into public.private_info (user_id, phone)
select id, raw_user_meta_data ->> 'phone' from auth.users
where coalesce(raw_user_meta_data ->> 'phone', '') <> ''
on conflict (user_id) do nothing;

-- Enable RLS on application tables.
alter table public.profiles enable row level security;
alter table public.private_info enable row level security;
alter table public.messages enable row level security;
alter table public.user_contacts enable row level security;
alter table public.moments enable row level security;
alter table public.moment_likes enable row level security;
alter table public.moment_comments enable row level security;
alter table public.push_subscriptions enable row level security;

-- Remove earlier app policies with known names before installing the current policies.
drop policy if exists "Signed-in users can find profiles" on public.profiles;
drop policy if exists "Users can update own profile" on public.profiles;
drop policy if exists "Users read own private info" on public.private_info;
drop policy if exists "Users insert own private info" on public.private_info;
drop policy if exists "Users update own private info" on public.private_info;
drop policy if exists "Participants read messages" on public.messages;
drop policy if exists "Users send messages as themselves" on public.messages;
drop policy if exists "Recipients mark messages read" on public.messages;
drop policy if exists "Users read their own contacts" on public.user_contacts;
drop policy if exists "Users add their own contacts" on public.user_contacts;
drop policy if exists "Users update their own contacts" on public.user_contacts;
drop policy if exists "Users delete their own contacts" on public.user_contacts;
drop policy if exists "Signed-in users view moments" on public.moments;
drop policy if exists "Users publish own moments" on public.moments;
drop policy if exists "Users update own moments" on public.moments;
drop policy if exists "Users delete own moments" on public.moments;
drop policy if exists "Members read moment likes" on public.moment_likes;
drop policy if exists "Users like as themselves" on public.moment_likes;
drop policy if exists "Users remove own likes" on public.moment_likes;
drop policy if exists "Members read moment comments" on public.moment_comments;
drop policy if exists "Users comment as themselves" on public.moment_comments;
drop policy if exists "Users delete own comments" on public.moment_comments;
drop policy if exists "Users manage own push subscriptions" on public.push_subscriptions;
drop policy if exists "Users read own push subscriptions" on public.push_subscriptions;

create policy "Signed-in users can find profiles" on public.profiles
  for select to authenticated using (true);
create policy "Users can update own profile" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

create policy "Users read own private info" on public.private_info
  for select to authenticated using (auth.uid() = user_id);
create policy "Users insert own private info" on public.private_info
  for insert to authenticated with check (auth.uid() = user_id);
create policy "Users update own private info" on public.private_info
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "Participants read messages" on public.messages
  for select to authenticated using (auth.uid() = sender_id or auth.uid() = recipient_id);
create policy "Users send messages as themselves" on public.messages
  for insert to authenticated with check (
    auth.uid() = sender_id and sender_id <> recipient_id and
    conversation_id = least(sender_id::text, recipient_id::text) || '_' || greatest(sender_id::text, recipient_id::text)
  );
create policy "Recipients mark messages read" on public.messages
  for update to authenticated using (auth.uid() = recipient_id) with check (auth.uid() = recipient_id);
-- Recipients can update only read_at, not message content, sender, or participants.
revoke update on public.messages from authenticated;
grant update(read_at) on public.messages to authenticated;
grant select, insert on public.messages to authenticated;

create policy "Users read their own contacts" on public.user_contacts
  for select to authenticated using (auth.uid() = owner_id);
create policy "Users add their own contacts" on public.user_contacts
  for insert to authenticated with check (auth.uid() = owner_id);
create policy "Users update their own contacts" on public.user_contacts
  for update to authenticated using (auth.uid() = owner_id) with check (auth.uid() = owner_id);
create policy "Users delete their own contacts" on public.user_contacts
  for delete to authenticated using (auth.uid() = owner_id);

create policy "Signed-in users view moments" on public.moments
  for select to authenticated using (true);
create policy "Users publish own moments" on public.moments
  for insert to authenticated with check (auth.uid() = user_id);
create policy "Users update own moments" on public.moments
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "Users delete own moments" on public.moments
  for delete to authenticated using (auth.uid() = user_id);

create policy "Members read moment likes" on public.moment_likes
  for select to authenticated using (true);
create policy "Users like as themselves" on public.moment_likes
  for insert to authenticated with check (auth.uid() = user_id);
create policy "Users remove own likes" on public.moment_likes
  for delete to authenticated using (auth.uid() = user_id);
create policy "Members read moment comments" on public.moment_comments
  for select to authenticated using (true);
create policy "Users comment as themselves" on public.moment_comments
  for insert to authenticated with check (auth.uid() = user_id);
create policy "Users delete own comments" on public.moment_comments
  for delete to authenticated using (auth.uid() = user_id);

create policy "Users manage own push subscriptions" on public.push_subscriptions
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Keep profile and phone data permissions narrow.
revoke all on public.private_info from anon, authenticated;
grant select, insert, update on public.private_info to authenticated;
revoke update on public.profiles from authenticated;
grant update(first_name, last_name, country, avatar_url, last_seen) on public.profiles to authenticated;
grant select on public.profiles to authenticated;
grant select, insert, update, delete on public.user_contacts to authenticated;
grant select, insert, update, delete on public.moments to authenticated;
grant select, insert, delete on public.moment_likes to authenticated;
grant select, insert, delete on public.moment_comments to authenticated;
grant select, insert, update, delete on public.push_subscriptions to authenticated;

-- Public bucket: profile pictures and public short videos only. 50 MiB maximum per file.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('nexus-public-media', 'nexus-public-media', true, 52428800,
  array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime','application/pdf','text/plain','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do update set public = true, file_size_limit = 52428800,
  allowed_mime_types = excluded.allowed_mime_types;

-- Private bucket: one-to-one chat media and voice notes. 50 MiB maximum per file.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('nexus-chat-media', 'nexus-chat-media', false, 52428800,
  array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime','audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav','audio/x-wav','application/pdf','text/plain','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do update set public = false, file_size_limit = 52428800,
  allowed_mime_types = excluded.allowed_mime_types;

-- Make legacy bucket private. Existing old public links may need re-uploading or migration.
update storage.buckets set public = false where id = 'nexus-media';

drop policy if exists "Public can view NEXUS media" on storage.objects;
drop policy if exists "Authenticated users upload NEXUS media" on storage.objects;
drop policy if exists "Users delete own NEXUS media" on storage.objects;
drop policy if exists "Upload own public NEXUS media" on storage.objects;
drop policy if exists "Read public NEXUS media" on storage.objects;
drop policy if exists "Delete own public NEXUS media" on storage.objects;
drop policy if exists "Upload own private chat media" on storage.objects;
drop policy if exists "Read private chat media participants" on storage.objects;
drop policy if exists "Delete own private chat media" on storage.objects;
drop policy if exists "Read old media only by owner or chat participants" on storage.objects;
drop policy if exists "Upload own old media" on storage.objects;
drop policy if exists "Delete own old media" on storage.objects;

create policy "Upload own public NEXUS media" on storage.objects for insert to authenticated
  with check (bucket_id = 'nexus-public-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Read public NEXUS media" on storage.objects for select to public
  using (bucket_id = 'nexus-public-media');
create policy "Delete own public NEXUS media" on storage.objects for delete to authenticated
  using (bucket_id = 'nexus-public-media' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Upload own private chat media" on storage.objects for insert to authenticated
  with check (bucket_id = 'nexus-chat-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Read private chat media participants" on storage.objects for select to authenticated
  using (bucket_id = 'nexus-chat-media' and (
    (storage.foldername(name))[1] = auth.uid()::text or
    exists (select 1 from public.messages m where m.media_url = 'private:' || name
      and (m.sender_id = auth.uid() or m.recipient_id = auth.uid()))
  ));
create policy "Delete own private chat media" on storage.objects for delete to authenticated
  using (bucket_id = 'nexus-chat-media' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Read old media only by owner or chat participants" on storage.objects for select to authenticated
  using (bucket_id = 'nexus-media' and (
    (storage.foldername(name))[1] = auth.uid()::text or
    exists (select 1 from public.messages m where m.media_url like '%' || name
      and (m.sender_id = auth.uid() or m.recipient_id = auth.uid()))
  ));
create policy "Upload own old media" on storage.objects for insert to authenticated
  with check (bucket_id = 'nexus-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Delete own old media" on storage.objects for delete to authenticated
  using (bucket_id = 'nexus-media' and (storage.foldername(name))[1] = auth.uid()::text);

-- Private realtime signaling channels: call:<uuid1>:<uuid2> (UUIDs sorted by the app).
-- Only the two authenticated participants can read/write broadcast signaling messages.
alter table realtime.messages enable row level security;
drop policy if exists "NEXUS call participants can read signaling" on realtime.messages;
drop policy if exists "NEXUS call participants can send signaling" on realtime.messages;
create policy "NEXUS call participants can read signaling" on realtime.messages
  for select to authenticated using (
    case when realtime.topic() ~ '^call:[0-9a-fA-F-]{36}:[0-9a-fA-F-]{36}$' then
      extension = 'broadcast' and split_part(realtime.topic(), ':', 1) = 'call' and
      auth.uid() in (split_part(realtime.topic(), ':', 2)::uuid, split_part(realtime.topic(), ':', 3)::uuid)
    else false end
  );
create policy "NEXUS call participants can send signaling" on realtime.messages
  for insert to authenticated with check (
    case when realtime.topic() ~ '^call:[0-9a-fA-F-]{36}:[0-9a-fA-F-]{36}$' then
      extension = 'broadcast' and split_part(realtime.topic(), ':', 1) = 'call' and
      auth.uid() in (split_part(realtime.topic(), ':', 2)::uuid, split_part(realtime.topic(), ':', 3)::uuid)
    else false end
  );

-- Add tables to Realtime publication if not already present.
do $$ begin alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; when others then raise notice 'Could not add messages to realtime publication: %', SQLERRM; end $$;
do $$ begin alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null; when others then raise notice 'Could not add profiles to realtime publication: %', SQLERRM; end $$;
do $$ begin alter publication supabase_realtime add table public.moments;
exception when duplicate_object then null; when others then raise notice 'Could not add moments to realtime publication: %', SQLERRM; end $$;

-- PASSWORD SECURITY:
-- Supabase Auth stores password hashes and handles verification/reset flows.
-- Do not create a passwords table and never store users' readable passwords.
