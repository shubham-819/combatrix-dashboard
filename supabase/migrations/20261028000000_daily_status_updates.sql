-- Daily member status updates, run by pg_cron at 10:00 AM IST.
-- Rules, applied in this order (dates are in IST):
--   1. pending/inactive -> active   when their latest membership covers today
--   2. active -> pending            when their latest membership has ended
--   3. pending -> inactive          after 30 days in pending
-- Members with no membership at all, and 'deleted' members, are never touched.
-- status_changed_at is kept up to date by the combatrix_member_track_status trigger.

create or replace function public.combatrix_update_statuses()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_activated int;
  v_to_pending int;
  v_to_inactive int;
begin
  with latest as (
    select distinct on (member_id) member_id, start_date, end_date
    from public.combatrix_membership
    order by member_id, end_date desc, id desc
  )
  update public.combatrix_member m set status = 'active'
  from latest l
  where l.member_id = m.id
    and m.status in ('pending', 'inactive')
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
    'to_active', v_activated,
    'to_pending', v_to_pending,
    'to_inactive', v_to_inactive);
end;
$$;
revoke all on function public.combatrix_update_statuses() from public, anon, authenticated;

-- Replace the weekly pending -> inactive job with one daily job.
-- 04:30 UTC = 10:00 AM IST.
select cron.unschedule(jobid) from cron.job where jobname = 'combatrix-pending-to-inactive';
select cron.schedule(
  'combatrix-daily-status-update',
  '30 4 * * *',
  'select public.combatrix_update_statuses()'
);

-- The old weekly function is folded into combatrix_update_statuses().
drop function if exists public.combatrix_expire_pending();
