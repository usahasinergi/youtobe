-- Security and reward-flow hardening for campaign platform.
-- Keep the existing tables and user data intact.

revoke all on function public.handle_new_auth_user() from public, anon, authenticated;
revoke all on function public.is_campaign_admin() from public, anon, authenticated;
grant execute on function public.is_campaign_admin() to authenticated;
revoke all on function public.join_campaign(uuid) from public, anon, authenticated;
grant execute on function public.join_campaign(uuid) to authenticated;
revoke all on function public.review_task_submission(uuid,text,text) from public, anon, authenticated;
grant execute on function public.review_task_submission(uuid,text,text) to authenticated;

drop policy if exists "Admins manage campaigns" on public.campaigns;
create policy "Admins create campaigns" on public.campaigns
for insert to authenticated with check (public.is_campaign_admin());
create policy "Admins update campaigns" on public.campaigns
for update to authenticated using (public.is_campaign_admin()) with check (public.is_campaign_admin());
create policy "Admins delete campaigns" on public.campaigns
for delete to authenticated using (public.is_campaign_admin());

drop policy if exists "Admins manage campaign tasks" on public.campaign_tasks;
create policy "Admins create campaign tasks" on public.campaign_tasks
for insert to authenticated with check (public.is_campaign_admin());
create policy "Admins update campaign tasks" on public.campaign_tasks
for update to authenticated using (public.is_campaign_admin()) with check (public.is_campaign_admin());
create policy "Admins delete campaign tasks" on public.campaign_tasks
for delete to authenticated using (public.is_campaign_admin());

drop policy if exists "Users request own withdrawals" on public.reward_withdrawals;
drop policy if exists "Admins review withdrawals" on public.reward_withdrawals;
drop policy if exists "Users read own withdrawals; admins read all" on public.reward_withdrawals;
grant select on public.reward_withdrawals to authenticated;
revoke insert, update, delete on public.reward_withdrawals from authenticated;
create policy "Users read own withdrawals; admins read all" on public.reward_withdrawals
for select to authenticated using (user_id = (select auth.uid()) or public.is_campaign_admin());

create index notification_queue_user_idx on public.notification_queue (user_id);
create index reward_ledger_created_by_idx on public.reward_ledger (created_by);
create index reward_withdrawals_reviewer_idx on public.reward_withdrawals (reviewed_by);
create index task_submissions_participant_campaign_idx on public.task_submissions (participant_id, campaign_id);
create index task_submissions_task_campaign_idx on public.task_submissions (task_id, campaign_id);
create index yt_activity_logs_account_idx on public.yt_activity_logs (account_id);
create index yt_comment_drafts_channel_idx on public.yt_comment_drafts (channel_id);
create index yt_comment_drafts_owner_idx on public.yt_comment_drafts (owner_id);

create or replace function public.request_reward_withdrawal(
  p_points bigint,
  p_payout_details jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_balance bigint;
  v_reserved bigint;
  v_id uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_points is null or p_points <= 0 then raise exception 'Requested points must be positive'; end if;
  if p_payout_details is null or pg_column_size(p_payout_details) > 8192 then
    raise exception 'Invalid payout details';
  end if;

  perform 1 from public.profiles where id = v_user for update;
  select coalesce(sum(points),0) into v_balance
    from public.reward_ledger where user_id = v_user;
  select coalesce(sum(points_requested),0) into v_reserved
    from public.reward_withdrawals where user_id = v_user and status in ('pending','approved');

  if p_points > v_balance - v_reserved then raise exception 'Insufficient available reward balance'; end if;

  insert into public.reward_withdrawals(user_id,points_requested,payout_details)
    values (v_user,p_points,p_payout_details) returning id into v_id;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
    values (v_user,'withdrawal_requested','reward_withdrawal',v_id::text,jsonb_build_object('points',p_points));
  return v_id;
end;
$$;

create or replace function public.review_reward_withdrawal(
  p_withdrawal_id uuid,
  p_decision text,
  p_note text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_withdrawal public.reward_withdrawals%rowtype;
begin
  if not public.is_campaign_admin() then raise exception 'Administrator permission required'; end if;
  if p_decision not in ('approved','rejected','paid') then raise exception 'Invalid withdrawal decision'; end if;

  select * into v_withdrawal from public.reward_withdrawals where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found'; end if;

  if p_decision = 'approved' and v_withdrawal.status <> 'pending' then
    raise exception 'Only pending withdrawals can be approved';
  elsif p_decision = 'rejected' and v_withdrawal.status not in ('pending','approved') then
    raise exception 'Withdrawal cannot be rejected in its current state';
  elsif p_decision = 'paid' and v_withdrawal.status <> 'approved' then
    raise exception 'Only approved withdrawals can be marked paid';
  end if;

  update public.reward_withdrawals
    set status = p_decision, admin_note = left(p_note,2000),
        reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_withdrawal_id;

  if p_decision = 'paid' then
    insert into public.reward_ledger(user_id,entry_type,points,description,created_by)
      values (v_withdrawal.user_id,'debit',-v_withdrawal.points_requested,
              'Reward withdrawal paid',auth.uid());
  end if;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
    values (auth.uid(),'withdrawal_' || p_decision,'reward_withdrawal',p_withdrawal_id::text,
            jsonb_build_object('user_id',v_withdrawal.user_id,'points',v_withdrawal.points_requested));
end;
$$;

revoke all on function public.request_reward_withdrawal(bigint,jsonb) from public, anon, authenticated;
grant execute on function public.request_reward_withdrawal(bigint,jsonb) to authenticated;
revoke all on function public.review_reward_withdrawal(uuid,text,text) from public, anon, authenticated;
grant execute on function public.review_reward_withdrawal(uuid,text,text) to authenticated;
