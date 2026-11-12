-- Additive campaign-platform foundation for KubangYT.
-- Existing YouTube account/channel tables and their data are intentionally untouched.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','participant','reviewer')),
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'))
  on conflict (id) do nothing;
  insert into public.user_roles (user_id, role)
  values (new.id, 'participant')
  on conflict do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created_campaign_profile
after insert on auth.users
for each row execute function public.handle_new_auth_user();

-- Backfill existing accounts without changing their authentication records.
insert into public.profiles (id, display_name)
select id, coalesce(raw_user_meta_data ->> 'full_name', raw_user_meta_data ->> 'name')
from auth.users on conflict (id) do nothing;
insert into public.user_roles (user_id, role)
select id, 'participant' from auth.users on conflict do nothing;

create or replace function public.is_campaign_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_roles ur
    where ur.user_id = (select auth.uid()) and ur.role in ('admin','reviewer')
  );
$$;

create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users(id),
  title text not null check (char_length(title) between 3 and 160),
  description text not null default '',
  platform text not null check (platform in ('youtube','instagram','tiktok','facebook','website','other')),
  destination_url text,
  status text not null default 'draft' check (status in ('draft','active','paused','completed','archived')),
  starts_at timestamptz,
  ends_at timestamptz,
  target_participants integer check (target_participants is null or target_participants > 0),
  max_participants integer check (max_participants is null or max_participants > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or starts_at is null or ends_at > starts_at),
  check (destination_url is null or destination_url ~ '^https?://')
);

create table public.campaign_tasks (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 160),
  instructions text not null,
  task_type text not null check (task_type in ('content_review','survey','feedback','watch_voluntary','other')),
  reward_points bigint not null default 0 check (reward_points >= 0),
  max_completions integer check (max_completions is null or max_completions > 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, campaign_id)
);

create table public.campaign_participants (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'joined' check (status in ('joined','in_progress','completed','withdrawn','blocked')),
  joined_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (campaign_id, user_id),
  unique (id, campaign_id)
);

create table public.task_submissions (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  task_id uuid not null,
  participant_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  response_text text,
  evidence_url text,
  status text not null default 'submitted' check (status in ('submitted','approved','rejected','needs_revision')),
  reviewer_id uuid references auth.users(id),
  reviewer_note text,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  unique (participant_id, task_id),
  foreign key (task_id, campaign_id) references public.campaign_tasks(id, campaign_id) on delete cascade,
  foreign key (participant_id, campaign_id) references public.campaign_participants(id, campaign_id) on delete cascade,
  check (evidence_url is null or evidence_url ~ '^https?://')
);

create table public.reward_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id),
  submission_id uuid unique references public.task_submissions(id),
  entry_type text not null check (entry_type in ('credit','debit','adjustment')),
  points bigint not null check (points <> 0),
  description text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.reward_withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  points_requested bigint not null check (points_requested > 0),
  payout_details jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','approved','rejected','paid')),
  admin_note text,
  reviewed_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.notification_queue (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  notification_type text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','processing','sent','failed')),
  attempts smallint not null default 0 check (attempts >= 0),
  available_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index profiles_display_name_idx on public.profiles using btree (display_name);
create index user_roles_user_role_idx on public.user_roles (user_id, role);
create index campaigns_status_dates_idx on public.campaigns (status, starts_at, ends_at);
create index campaigns_created_by_idx on public.campaigns (created_by, created_at desc);
create index campaign_tasks_campaign_active_order_idx on public.campaign_tasks (campaign_id, is_active, sort_order);
create index campaign_participants_user_joined_idx on public.campaign_participants (user_id, joined_at desc);
create index campaign_participants_campaign_status_idx on public.campaign_participants (campaign_id, status);
create index task_submissions_user_status_idx on public.task_submissions (user_id, status, submitted_at desc);
create index task_submissions_campaign_status_idx on public.task_submissions (campaign_id, status, submitted_at desc);
create index task_submissions_reviewer_idx on public.task_submissions (reviewer_id, reviewed_at desc);
create index reward_ledger_user_created_idx on public.reward_ledger (user_id, created_at desc);
create index reward_withdrawals_user_created_idx on public.reward_withdrawals (user_id, created_at desc);
create index reward_withdrawals_status_created_idx on public.reward_withdrawals (status, created_at);
create index audit_logs_actor_created_idx on public.audit_logs (actor_id, created_at desc);
create index notification_queue_pending_idx on public.notification_queue (available_at, id) where status = 'pending';

create trigger profiles_touch_updated_at before update on public.profiles
for each row execute function public.touch_updated_at();
create trigger campaigns_touch_updated_at before update on public.campaigns
for each row execute function public.touch_updated_at();
create trigger campaign_tasks_touch_updated_at before update on public.campaign_tasks
for each row execute function public.touch_updated_at();

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.campaigns enable row level security;
alter table public.campaign_tasks enable row level security;
alter table public.campaign_participants enable row level security;
alter table public.task_submissions enable row level security;
alter table public.reward_ledger enable row level security;
alter table public.reward_withdrawals enable row level security;
alter table public.audit_logs enable row level security;
alter table public.notification_queue enable row level security;

create policy "Profiles readable by signed-in users" on public.profiles
for select to authenticated using (true);
create policy "Users update own profile" on public.profiles
for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "Users read own roles; admins read all" on public.user_roles
for select to authenticated using (user_id = (select auth.uid()) or public.is_campaign_admin());

create policy "Active campaigns visible to participants; admins see all" on public.campaigns
for select to authenticated using (status = 'active' or public.is_campaign_admin());
create policy "Admins manage campaigns" on public.campaigns
for all to authenticated using (public.is_campaign_admin()) with check (public.is_campaign_admin());

create policy "Tasks visible for active campaigns or admins" on public.campaign_tasks
for select to authenticated using (
  public.is_campaign_admin() or
  (is_active and exists (select 1 from public.campaigns c where c.id = campaign_id and c.status = 'active'))
);
create policy "Admins manage campaign tasks" on public.campaign_tasks
for all to authenticated using (public.is_campaign_admin()) with check (public.is_campaign_admin());

create policy "Participants see own memberships; admins see all" on public.campaign_participants
for select to authenticated using (user_id = (select auth.uid()) or public.is_campaign_admin());
create policy "Users join campaigns as themselves" on public.campaign_participants
for insert to authenticated with check (user_id = (select auth.uid()) and status = 'joined');

create policy "Users see own submissions; reviewers see all" on public.task_submissions
for select to authenticated using (user_id = (select auth.uid()) or public.is_campaign_admin());
create policy "Participants submit own task evidence" on public.task_submissions
for insert to authenticated with check (
  user_id = (select auth.uid()) and status = 'submitted' and reviewer_id is null and reviewed_at is null
  and exists (
    select 1 from public.campaign_participants cp
    where cp.id = participant_id and cp.campaign_id = campaign_id
      and cp.user_id = (select auth.uid()) and cp.status in ('joined','in_progress')
  )
  and exists (
    select 1 from public.campaign_tasks t
    where t.id = task_id and t.campaign_id = campaign_id and t.is_active
  )
);
create policy "Reviewers update submissions" on public.task_submissions
for update to authenticated using (public.is_campaign_admin()) with check (public.is_campaign_admin());

create policy "Users read own reward ledger; admins read all" on public.reward_ledger
for select to authenticated using (user_id = (select auth.uid()) or public.is_campaign_admin());
create policy "Users read own withdrawals; admins read all" on public.reward_withdrawals
for select to authenticated using (user_id = (select auth.uid()) or public.is_campaign_admin());
create policy "Users request own withdrawals" on public.reward_withdrawals
for insert to authenticated with check (user_id = (select auth.uid()) and status = 'pending' and reviewed_by is null and reviewed_at is null);
create policy "Admins review withdrawals" on public.reward_withdrawals
for update to authenticated using (public.is_campaign_admin()) with check (public.is_campaign_admin());

create policy "Admins read audit logs" on public.audit_logs
for select to authenticated using (public.is_campaign_admin());
create policy "Authenticated users enqueue own notifications" on public.notification_queue
for select to authenticated using (user_id = (select auth.uid()));
 
create or replace function public.join_campaign(p_campaign_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_campaign public.campaigns%rowtype;
  v_count integer;
  v_participant_id uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select * into v_campaign from public.campaigns where id = p_campaign_id for update;
  if not found or v_campaign.status <> 'active' then raise exception 'Campaign is not available'; end if;
  if v_campaign.starts_at is not null and v_campaign.starts_at > now() then raise exception 'Campaign has not started'; end if;
  if v_campaign.ends_at is not null and v_campaign.ends_at <= now() then raise exception 'Campaign has ended'; end if;
  select count(*) into v_count from public.campaign_participants
    where campaign_id = p_campaign_id and status <> 'withdrawn';
  if v_campaign.max_participants is not null and v_count >= v_campaign.max_participants then
    raise exception 'Campaign participant limit reached';
  end if;
  insert into public.campaign_participants(campaign_id,user_id)
    values (p_campaign_id,v_user)
    on conflict (campaign_id,user_id) do nothing
    returning id into v_participant_id;
  if v_participant_id is null then
    select id into v_participant_id from public.campaign_participants
      where campaign_id = p_campaign_id and user_id = v_user;
  end if;
  return v_participant_id;
end;
$$;

create or replace function public.review_task_submission(
  p_submission_id uuid,
  p_decision text,
  p_note text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_submission public.task_submissions%rowtype;
  v_points bigint;
begin
  if not public.is_campaign_admin() then raise exception 'Administrator permission required'; end if;
  if p_decision not in ('approved','rejected','needs_revision') then raise exception 'Invalid review decision'; end if;
  select * into v_submission from public.task_submissions where id = p_submission_id for update;
  if not found or v_submission.status <> 'submitted' then raise exception 'Submission is not awaiting review'; end if;

  update public.task_submissions
    set status = p_decision, reviewer_id = auth.uid(), reviewer_note = left(p_note,2000), reviewed_at = now()
    where id = p_submission_id;

  if p_decision = 'approved' then
    select reward_points into v_points from public.campaign_tasks where id = v_submission.task_id;
    if v_points > 0 then
      insert into public.reward_ledger(user_id,submission_id,entry_type,points,description,created_by)
      values (v_submission.user_id,v_submission.id,'credit',v_points,'Reward for approved campaign task',auth.uid())
      on conflict (submission_id) do nothing;
    end if;
  end if;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values (auth.uid(),'submission_' || p_decision,'task_submission',p_submission_id::text,
    jsonb_build_object('user_id',v_submission.user_id,'campaign_id',v_submission.campaign_id));
end;
$$;

revoke all on function public.join_campaign(uuid) from public;
grant execute on function public.join_campaign(uuid) to authenticated;
revoke all on function public.review_task_submission(uuid,text,text) from public;
grant execute on function public.review_task_submission(uuid,text,text) to authenticated;

grant select, update on public.profiles to authenticated;
grant select on public.user_roles to authenticated;
grant select, insert, update, delete on public.campaigns to authenticated;
grant select, insert, update, delete on public.campaign_tasks to authenticated;
grant select, insert on public.campaign_participants to authenticated;
grant select, insert on public.task_submissions to authenticated;
grant select on public.reward_ledger to authenticated;
grant select, insert, update on public.reward_withdrawals to authenticated;
grant select on public.audit_logs to authenticated;
grant select on public.notification_queue to authenticated;
