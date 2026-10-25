-- Code-protected read access for the Combatrix web dashboard.
-- The access code is stored only as a bcrypt hash. Neither table is reachable
-- through the API (RLS on, no policies, no grants); only the function below reads them.

create table if not exists public.dashboard_access_code (
  id int primary key default 1 check (id = 1),
  code_hash text not null,
  updated_at timestamptz not null default now()
);
alter table public.dashboard_access_code enable row level security;
revoke all on public.dashboard_access_code from anon, authenticated;

create table if not exists public.dashboard_access_failure (
  id bigint generated always as identity primary key,
  attempted_at timestamptz not null default now()
);
create index if not exists dashboard_access_failure_at on public.dashboard_access_failure (attempted_at);
alter table public.dashboard_access_failure enable row level security;
revoke all on public.dashboard_access_failure from anon, authenticated;

-- Sets the access code. Not callable through the API.
create or replace function public.set_dashboard_code(p_code text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  insert into public.dashboard_access_code (id, code_hash, updated_at)
  values (1, extensions.crypt(p_code, extensions.gen_salt('bf', 10)), now())
  on conflict (id) do update set code_hash = excluded.code_hash, updated_at = now();
$$;
revoke all on function public.set_dashboard_code(text) from public, anon, authenticated;

-- Returns everything the dashboard shows, or {"error": ...} when the code is wrong.
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
      select m.id, m.name, m.phone_number, m.status, m.date_joined, l.end_date, l.price
      from combatrix_member m left join latest l on l.member_id = m.id
    ),
    periods as (
      select 'this_month' as period, v_month as month_start
      union all select 'last_month', (v_month - interval '1 month')::date
    )
    select jsonb_build_object(
      'generated_at', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD"T"HH24:MI:SS'),
      'summary', (
        select jsonb_build_object(
          'today', to_char(v_today, 'YYYY-MM-DD'),
          'pending',  count(*) filter (where status = 'pending'),
          'inactive', count(*) filter (where status = 'inactive'),
          'active',   count(*) filter (where status = 'active'),
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
        ) e)
    )
  );
end;
$$;
revoke all on function public.get_combatrix_dashboard(text) from public;
grant execute on function public.get_combatrix_dashboard(text) to anon, authenticated;

-- Codes are case-insensitive: compare and store upper-cased.
create or replace function public.set_dashboard_code(p_code text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  insert into public.dashboard_access_code (id, code_hash, updated_at)
  values (1, extensions.crypt(upper(trim(p_code)), extensions.gen_salt('bf', 10)), now())
  on conflict (id) do update set code_hash = excluded.code_hash, updated_at = now();
$$;
revoke all on function public.set_dashboard_code(text) from public, anon, authenticated;
