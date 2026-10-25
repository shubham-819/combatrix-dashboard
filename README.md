# Combatrix dashboard

A live web version of the Combatrix "Members & fees" dashboard. It is a single static page (`index.html`) that asks for an access code, then loads current figures from Supabase.

## How it works

- `index.html` calls the Supabase function `get_combatrix_dashboard(p_code)` with the project's public (publishable) key.
- The function checks the code against a bcrypt hash stored in `dashboard_access_code`. A wrong code gets `{"error": "invalid_code"}` and no data. After 30 wrong codes in 15 minutes it refuses all requests for a while.
- The member tables can't be read directly with the public key (row level security is on with no policies), so the code is the only way in.
- The code is not case-sensitive. "Remember on this device" keeps it in the browser's local storage; **Lock** clears it.

SQL is in `supabase/migrations/`.

## Changing the access code

Run this in the Supabase SQL editor (project `combatrix-db`):

```sql
select public.set_dashboard_code('NEW-CODE-HERE');
```

Anyone with the old code is locked out on their next visit.
