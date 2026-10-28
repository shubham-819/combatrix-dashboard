-- New status 'paused': a member freezes their membership for a set number of days.
--   * combatrix_pause_member() (called by the agent) sets status 'paused', records the resume
--     date and pushes the latest membership's end_date forward by the pause length.
--   * The daily status job (10:00 AM IST) moves paused -> active on the resume date and clears
--     the resume date. Paused members are skipped by every other rule in that job.
-- Dates are in IST.

alter table public.combatrix_member
  add column if not exists pause_resume_date date;  -- first day back after a pause

create or replace function public.combatrix_pause_member(
  p_member_id bigint,
  p_days int,
  p_start date default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_start date := coalesce(p_start, v_today);
  v_status text;
  v_mid bigint;
  v_end date;
  v_new_end date;
begin
  if p_days is null or p_days < 1 then
    raise exception 'pause length must be at least 1 day';
  end if;

  select status into v_status from public.combatrix_member where id = p_member_id for update;
  if v_status is null then
    raise exception 'member % not found', p_member_id;
  end if;
  if v_status <> 'active' then
    raise exception 'only active members can be paused (member % is %)', p_member_id, v_status;
  end if;

  select id, end_date into v_mid, v_end
  from public.combatrix_membership
  where member_id = p_member_id
  order by end_date desc, id desc
  limit 1;
  if v_mid is null or v_end < v_start then
    raise exception 'member % has no membership covering %', p_member_id, v_start;
  end if;

  v_new_end := v_end + p_days;
  update public.combatrix_membership set end_date = v_new_end where id = v_mid;

  update public.combatrix_member set
    status = 'paused',
    pause_resume_date = v_start + p_days
  where id = p_member_id;

  return jsonb_build_object(
    'member_id', p_member_id,
    'pause_start', v_start,
    'resume_date', v_start + p_days,
    'old_end_date', v_end,
    'new_end_date', v_new_end);
end;
$$;
revoke all on function public.combatrix_pause_member(bigint, int, date) from public, anon, authenticated;

create or replace function public.combatrix_update_statuses()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_resumed int;
  v_activated int;
  v_to_pending int;
  v_to_inactive int;
begin
  -- 0. paused -> active once the pause is over (the membership end date was already extended).
  update public.combatrix_member set
    status = 'active', pause_resume_date = null
  where status = 'paused' and pause_resume_date <= v_today;
  get diagnostics v_resumed = row_count;

  with latest as (
    select distinct on (member_id) member_id, start_date, end_date
    from public.combatrix_membership
    order by member_id, end_date desc, id desc
  )
  update public.combatrix_member m set status = 'active'
  from latest l
  where l.member_id = m.id
    and m.status in ('registered', 'pending', 'inactive')
    and l.start_date <= v_today and l.end_date >= v_today;
  get diagnostics v_activated = row_count;

  with latest as (
    select distinct on (member_id) member_id, end_date
    from public.combatrix_membership
    order by member_id, end_date desc, id desc
  )
  update public.combatrix_member m set status = 'pending'
  from latest l
  where l.member_id = m.id
    and m.status = 'active'
    and l.end_date < v_today;
  get diagnostics v_to_pending = row_count;

  update public.combatrix_member set status = 'inactive'
  where status = 'pending'
    and status_changed_at is not null
    and status_changed_at <= now() - interval '30 days';
  get diagnostics v_to_inactive = row_count;

  return jsonb_build_object(
    'resumed', v_resumed,
    'to_active', v_activated,
    'to_pending', v_to_pending,
    'to_inactive', v_to_inactive);
end;
$$;
revoke all on function public.combatrix_update_statuses() from public, anon, authenticated;
