-- New status 'registered': signed the form/waiver but hasn't paid (day visitors, new joiners).
--   * The form sync now creates new people as 'registered' instead of 'active'.
--   * The daily status job moves registered -> active once a paid membership covers today.
--   * Registered people with no membership are otherwise left alone.

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
    'to_active', v_activated,
    'to_pending', v_to_pending,
    'to_inactive', v_to_inactive);
end;
$$;
revoke all on function public.combatrix_update_statuses() from public, anon, authenticated;

create or replace function public.combatrix_sync_form_rows(p_secret text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_marker int;
  v_new_marker int;
  v_inserted int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  r jsonb;
  v_email text;
  v_phone text;
  v_em_phone text;
  v_id bigint;
begin
  select secret_hash into v_hash from form_sync_secret where id = 1;
  if v_hash is null or p_secret is null or crypt(p_secret, v_hash) <> v_hash then
    return jsonb_build_object('error', 'invalid_secret');
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    return jsonb_build_object('error', 'rows_must_be_array');
  end if;

  -- Lock the marker so a form submit and the daily run can't import the same row twice.
  select last_row_count into v_marker
  from sheet_sync_state where key = 'contact_information_responses' for update;
  v_new_marker := v_marker;

  for r in
    select value from jsonb_array_elements(p_rows)
    where (value->>'n')::int > v_marker
    order by (value->>'n')::int
  loop
    v_new_marker := greatest(v_new_marker, (r->>'n')::int);
    v_email := lower(trim(coalesce(r->>'email', '')));
    if v_email = '' or coalesce(trim(r->>'name'), '') = '' then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    -- Keep the last 10 digits (drops +91 / leading 0 / spaces / dashes).
    v_phone := right(regexp_replace(coalesce(r->>'phone', ''), '\D', '', 'g'), 10);
    v_em_phone := right(regexp_replace(coalesce(r->>'emergency_phone', ''), '\D', '', 'g'), 10);

    select id into v_id from combatrix_member where lower(email) = v_email limit 1;
    if v_id is null then
      insert into combatrix_member
        (name, email, phone_number, emergency_contact_name, emergency_contact_number, date_joined, status)
      values
        (trim(r->>'name'), v_email, v_phone, trim(coalesce(r->>'emergency_name', '')), v_em_phone,
         coalesce(nullif(r->>'date', '')::date, (now() at time zone 'Asia/Kolkata')::date), 'registered');
      v_inserted := v_inserted + 1;
    else
      update combatrix_member set
        phone_number = case when phone_number = '' then v_phone else phone_number end,
        emergency_contact_name = case when emergency_contact_name = ''
          then trim(coalesce(r->>'emergency_name', '')) else emergency_contact_name end,
        emergency_contact_number = case when emergency_contact_number = ''
          then v_em_phone else emergency_contact_number end
      where id = v_id;
      v_updated := v_updated + 1;
    end if;
  end loop;

  update sheet_sync_state set
    last_row_count = v_new_marker,
    last_run_at = now(),
    last_run_summary = format('rows %s-%s: %s new, %s existing, %s skipped',
                              v_marker + 1, v_new_marker, v_inserted, v_updated, v_skipped)
  where key = 'contact_information_responses';

  return jsonb_build_object('inserted', v_inserted, 'existing', v_updated,
                            'skipped', v_skipped, 'marker', v_new_marker);
end;
$$;
revoke all on function public.combatrix_sync_form_rows(text, jsonb) from public;
grant execute on function public.combatrix_sync_form_rows(text, jsonb) to anon, authenticated;

-- Safan (id 77) signed the waiver but has no paid membership.
update public.combatrix_member set status = 'registered' where id = 77 and status = 'active'
  and not exists (select 1 from public.combatrix_membership where member_id = 77);
