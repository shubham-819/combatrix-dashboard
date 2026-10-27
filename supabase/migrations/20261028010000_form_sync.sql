-- Google Form -> combatrix_member sync.
-- An Apps Script bound to the "Contact Information (Responses)" sheet posts its rows here
-- (on every form submit, plus a daily catch-up). Only rows after the marker in
-- sheet_sync_state are processed, so historical rows are never re-imported.
--   * New email      -> new member, status 'active', date_joined = form date (IST).
--   * Existing email -> only blank contact fields are filled in; status is never changed.
-- The script authenticates with a shared secret, stored here only as a bcrypt hash.

create table if not exists public.form_sync_secret (
  id int primary key default 1 check (id = 1),
  secret_hash text not null,
  updated_at timestamptz not null default now()
);
alter table public.form_sync_secret enable row level security;
revoke all on public.form_sync_secret from anon, authenticated;

-- Sets the shared secret. Not callable through the API.
create or replace function public.set_form_sync_secret(p_secret text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  insert into public.form_sync_secret (id, secret_hash, updated_at)
  values (1, extensions.crypt(p_secret, extensions.gen_salt('bf', 10)), now())
  on conflict (id) do update set secret_hash = excluded.secret_hash, updated_at = now();
$$;
revoke all on function public.set_form_sync_secret(text) from public, anon, authenticated;

-- p_rows: [{ "n": <data row number, 1 = first response>, "date": "YYYY-MM-DD", "name", "email",
--            "phone", "emergency_name", "emergency_phone" }, ...]
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
         coalesce(nullif(r->>'date', '')::date, (now() at time zone 'Asia/Kolkata')::date), 'active');
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
