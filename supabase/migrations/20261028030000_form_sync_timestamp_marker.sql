-- Form sync now remembers the newest form timestamp it has imported, instead of a row count.
-- Deleting, sorting or reordering sheet rows can no longer cause new signups to be skipped.
-- Rows without a readable timestamp are always processed; that is harmless because
-- matching is by email (existing members only get blank contact fields filled in).
--
-- The marker starts empty, so the first sync after this migration passes over every row once:
-- people in the sheet but not in the DB are created as 'registered'.

alter table public.sheet_sync_state add column if not exists last_form_ts timestamptz;
alter table public.sheet_sync_state drop column if exists last_row_count;
update public.sheet_sync_state set last_form_ts = null, last_run_summary = 'reset to timestamp marker'
where key = 'contact_information_responses';

-- p_rows: [{ "ts": "<ISO timestamp of the form response>", "date": "YYYY-MM-DD", "name", "email",
--            "phone", "emergency_name", "emergency_phone" }, ...]
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
