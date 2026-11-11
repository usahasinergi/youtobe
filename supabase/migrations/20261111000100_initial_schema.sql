create table if not exists public.yt_accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  email text,
  label text,
  status text not null default 'active' check (status in ('active','inactive','needs_reauth')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists yt_accounts_owner_created_idx on public.yt_accounts(owner_id, created_at desc);
alter table public.yt_accounts enable row level security;
create policy "Users manage their own YouTube account records" on public.yt_accounts
  for all to authenticated using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

create table if not exists public.yt_channels (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  youtube_channel_id text,
  title text not null,
  channel_url text,
  connection_status text not null default 'not_connected' check (connection_status in ('not_connected','connected','needs_reauth')),
  created_at timestamptz not null default now(),
  unique(owner_id, youtube_channel_id)
);
alter table public.yt_channels enable row level security;
create policy "Users manage their own channels" on public.yt_channels
  for all to authenticated using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

create table if not exists public.yt_activity_logs (
  id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  account_id uuid references public.yt_accounts(id) on delete set null,
  event_type text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists yt_activity_owner_created_idx on public.yt_activity_logs(owner_id, created_at desc);
alter table public.yt_activity_logs enable row level security;
create policy "Users read and add their own activity logs" on public.yt_activity_logs
  for all to authenticated using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

create table if not exists public.yt_comment_drafts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  channel_id uuid references public.yt_channels(id) on delete set null,
  video_id text,
  comment_text text not null,
  status text not null default 'draft' check (status in ('draft','approved','published','rejected')),
  created_at timestamptz not null default now()
);
alter table public.yt_comment_drafts enable row level security;
create policy "Users manage their own comment drafts" on public.yt_comment_drafts
  for all to authenticated using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

create table if not exists public.yt_browser_slots (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  slot_number smallint not null check (slot_number between 1 and 4),
  start_url text not null default 'https://www.youtube.com/',
  label text,
  updated_at timestamptz not null default now(),
  unique(owner_id, slot_number)
);
alter table public.yt_browser_slots enable row level security;
create policy "Users manage their own browser slots" on public.yt_browser_slots
  for all to authenticated using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);
