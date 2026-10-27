-- Store each member's form/waiver timestamp (as shown in the sheet) on combatrix_member.
-- New rows get it on insert; existing members get it filled in once if empty.
-- The sync marker is cleared so the next sync passes over every row once and backfills it.

alter table public.combatrix_member add column if not exists form_submitted_at timestamptz;
update public.sheet_sync_state set last_form_ts = null, last_run_summary = 'reset to backfill form_submitted_at'
where key = 'contact_information_responses';

create or replace function public.combatrix_sync_form_rows(p_secret text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_marker timestamptz;
  v_new_marker timestamptz;
  v_inserted int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  r jsonb;
  v_ts timestamptz;
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
  select last_form_ts into v_marker
  from sheet_sync_state where key = 'contact_information_responses' for update;
  v_new_marker := v_marker;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_ts := nullif(r->>'ts', '')::timestamptz;
    if v_ts is not null and v_marker is not null and v_ts <= v_marker then
      continue; -- already imported
    end if;
    if v_ts is not null then
      v_new_marker := greatest(coalesce(v_new_marker, v_ts), v_ts);
    end if;

    v_email := lower(trim(coalesce(r->>'email', '')));
    if v_email = '' or coalesce(trim(r->>'name'), '') = '' then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    -- Keep the last 10 digits (drops +91 / leading 0 / spaces / dashes).
    v_phone := right(regexp_replace(coalesce(r->>'phone', ''), '\D', '', 'g'), 10);
    v_em_phone := right(regexp_replace(coalesce(r->>'emergency_phone', ''), '\D', '', 'g'), 10);

    select id into v_id from combatrix_member where lower(trim(email)) = v_email limit 1;
    if v_id is null then
      insert into combatrix_member
        (name, email, phone_number, emergency_contact_name, emergency_contact_number, date_joined, status, form_submitted_at)
      values
        (trim(r->>'name'), v_email, v_phone, trim(coalesce(r->>'emergency_name', '')), v_em_phone,
         coalesce(nullif(r->>'date', '')::date, (now() at time zone 'Asia/Kolkata')::date), 'registered', v_ts);
      v_inserted := v_inserted + 1;
    else
      update combatrix_member set
        phone_number = case when phone_number = '' then v_phone else phone_number end,
        emergency_contact_name = case when emergency_contact_name = ''
          then trim(coalesce(r->>'emergency_name', '')) else emergency_contact_name end,
        emergency_contact_number = case when emergency_contact_number = ''
          then v_em_phone else emergency_contact_number end,
        form_submitted_at = coalesce(form_submitted_at, v_ts)
      where id = v_id;
      v_updated := v_updated + 1;
    end if;
  end loop;

  update sheet_sync_state set
    last_form_ts = v_new_marker,
    last_run_at = now(),
    last_run_summary = format('%s new, %s existing, %s skipped', v_inserted, v_updated, v_skipped)
  where key = 'contact_information_responses';

  return jsonb_build_object('inserted', v_inserted, 'existing', v_updated, 'skipped', v_skipped,
                            'marker', to_char(v_new_marker at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS'));
end;
$$;
revoke all on function public.combatrix_sync_form_rows(text, jsonb) from public;
grant execute on function public.combatrix_sync_form_rows(text, jsonb) to anon, authenticated;
