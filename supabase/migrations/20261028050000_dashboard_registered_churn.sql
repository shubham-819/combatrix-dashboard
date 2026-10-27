-- Dashboard: adds the registered list and monthly churn.
--
-- Churn, per month M (this month and the 5 before it):
--   * A membership "lapses" in M when it ends in M and no later membership for the same member
--     starts within 30 days of that end date (the same 30-day window as pending -> inactive).
--   * churned       = lapsed and the 30-day window is over
--   * still_pending = ended in M, window not over yet, not renewed so far (may still renew)
--   * active_start  = members with a membership covering the 1st of M
--   * churn rate    = churned / active_start (computed in the page)

create or replace function public.get_combatrix_dashboard(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_recent_failures int;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_month date := date_trunc('month', now() at time zone 'Asia/Kolkata')::date;
begin
  -- Throttle guessing: after 30 wrong codes in 15 minutes, refuse everything briefly.
  delete from dashboard_access_failure where attempted_at < now() - interval '1 day';
  select count(*) into v_recent_failures
  from dashboard_access_failure where attempted_at > now() - interval '15 minutes';
  if v_recent_failures >= 30 then
    return jsonb_build_object('error', 'too_many_attempts');
  end if;

  select code_hash into v_hash from dashboard_access_code where id = 1;
  if v_hash is null or p_code is null or crypt(upper(trim(p_code)), v_hash) <> v_hash then
    insert into dashboard_access_failure default values;
    return jsonb_build_object('error', 'invalid_code');
  end if;

  return (
    with latest as (
      select distinct on (member_id) member_id, end_date, price
      from combatrix_membership
      order by member_id, end_date desc, id desc
    ),
    ml as (
      select m.id, m.name, m.phone_number, m.status, m.date_joined, m.form_submitted_at, l.end_date, l.price
      from combatrix_member m left join latest l on l.member_id = m.id
    ),
    periods as (
      select 'this_month' as period, v_month as month_start
      union all select 'last_month', (v_month - interval '1 month')::date
    ),
    churn_months as (
      select (v_month - make_interval(months => g))::date as month_start
      from generate_series(0, 5) g
    ),
    ended as (
      select ms.member_id, ms.end_date,
        exists (
          select 1 from combatrix_membership nx
          where nx.member_id = ms.member_id and nx.id <> ms.id
            and nx.end_date > ms.end_date
            and nx.start_date <= ms.end_date + 30
        ) as renewed
      from combatrix_membership ms
    )
    select jsonb_build_object(
      'generated_at', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD"T"HH24:MI:SS'),
      'summary', (
        select jsonb_build_object(
          'today', to_char(v_today, 'YYYY-MM-DD'),
          'pending',  count(*) filter (where status = 'pending'),
          'inactive', count(*) filter (where status = 'inactive'),
          'active',   count(*) filter (where status = 'active'),
          'registered', count(*) filter (where status = 'registered'),
          'lapsed_active', count(*) filter (where status = 'active' and end_date < v_today),
          'expiring_7d',  count(*) filter (where status = 'active' and end_date between v_today and v_today + 7),
          'expiring_30d', count(*) filter (where status = 'active' and end_date between v_today and v_today + 30))
        from ml where status <> 'deleted'),
      'expired', coalesce((
        select jsonb_agg(jsonb_build_object(
          'member_id', id, 'phone', phone_number, 'name', name,
          'expired_on', end_date, 'days_since_expiry', v_today - end_date, 'last_fee', price)
          order by end_date desc nulls last, name)
        from ml where status = 'pending'), '[]'::jsonb),
      'expiring', coalesce((
        select jsonb_agg(jsonb_build_object(
          'member_id', id, 'phone', phone_number, 'name', name,
          'expires_on', end_date, 'days_left', end_date - v_today, 'current_fee', price)
          order by end_date, name)
        from ml where status = 'active' and end_date between v_today and v_today + 30), '[]'::jsonb),
      'registered', coalesce((
        select jsonb_agg(jsonb_build_object(
          'member_id', id, 'phone', phone_number, 'name', name,
          'signed_at', to_char(form_submitted_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD"T"HH24:MI:SS'),
          'days_since_signed', v_today - (form_submitted_at at time zone 'Asia/Kolkata')::date)
          order by form_submitted_at desc nulls last, name)
        from ml where status = 'registered'), '[]'::jsonb),
      'inactive', coalesce((
        select jsonb_agg(jsonb_build_object(
          'member_id', id, 'phone', phone_number, 'name', name,
          'last_expired_on', end_date, 'days_since_expiry', v_today - end_date,
          'last_fee', price, 'date_joined', date_joined)
          order by end_date desc nulls last, name)
        from ml where status = 'inactive'), '[]'::jsonb),
      'earnings', (
        select jsonb_agg(row_to_json(e)::jsonb order by e.month_start desc)
        from (
          select p.period, p.month_start, to_char(p.month_start, 'FMMonth YYYY') as month_label,
            count(ms.id)::int as payments,
            coalesce(sum(ms.price), 0) as total,
            coalesce(sum(ms.combatrix_share), 0) as combatrix,
            coalesce(sum(ms.fitshala_share), 0) as fitshala,
            round(coalesce(sum(ms.combatrix_share) / nullif(sum(ms.price), 0), 0), 4) as combatrix_pct,
            round(coalesce(sum(ms.fitshala_share) / nullif(sum(ms.price), 0), 0), 4) as fitshala_pct
          from periods p
          left join combatrix_membership ms
            on ms.start_date >= p.month_start and ms.start_date < (p.month_start + interval '1 month')::date
          group by p.period, p.month_start
        ) e),
      'churn', (
        select jsonb_agg(row_to_json(c)::jsonb order by c.month_start)
        from (
          select cm.month_start,
            to_char(cm.month_start, 'Mon YYYY') as month_label,
            (select count(distinct a.member_id) from combatrix_membership a
              where a.start_date <= cm.month_start and a.end_date >= cm.month_start)::int as active_start,
            (select count(distinct e.member_id) from ended e
              where e.end_date >= cm.month_start
                and e.end_date < (cm.month_start + interval '1 month')::date
                and not e.renewed and e.end_date + 30 < v_today)::int as churned,
            (select count(distinct e.member_id) from ended e
              where e.end_date >= cm.month_start
                and e.end_date < (cm.month_start + interval '1 month')::date
                and not e.renewed and e.end_date + 30 >= v_today and e.end_date < v_today)::int as still_pending
          from churn_months cm
        ) c)
    )
  );
end;
$$;
revoke all on function public.get_combatrix_dashboard(text) from public;
grant execute on function public.get_combatrix_dashboard(text) to anon, authenticated;
