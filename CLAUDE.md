# Instructions for agents

- The dashboard is hosted on GitHub. Merging to the default branch (`claude/admiring-hawking-p97q1x`) deploys it: once merged, the change is live. No separate deploy step.
- Because a merge goes live, only merge when the user has asked for it.
- Database changes live in `supabase/migrations/`. Ask the user before applying any migration.

## Recording payments (Supabase project `combatrix-db`, id `ucaulmnmpjxhdmzsfsdi`)

Writes are approved when the user asks to record payments; no need to re-inspect the schema.

- Find the member: `select id, name, status from combatrix_member where name ilike '%<name>%'`. Names are often longer than what the user types (e.g. "Aadav" is "Aadavkrishna Patinhatta Purayil"). Ask if there are several matches or none.
- Last plan: `select start_date, end_date, price from combatrix_membership where member_id = <id> order by end_date desc limit 1`.
- Insert into `combatrix_membership (member_id, start_date, end_date, price, combatrix_share, fitshala_share, created_at)`, with `created_at = now()`.
- Shares: Fitshala gets 20% of price by default (`combatrix_share = price * 0.8`). If the user says "0 Fitshala share", Combatrix gets the full price.
- End date = start + N months − 1 day (15 Oct → 14 Jan for 3 months; 26 Oct → 25 Nov for 1 month).
- "Extend by N months" = new row starting the day after the latest `end_date`.
- No length given: infer from price. 1-month plans are about ₹3,000–6,000, 3-month plans about ₹7,500–10,000. Say what you assumed.
- Status: the daily job (10 AM IST) sets status from memberships. To show it right away, run `update combatrix_member set status = 'active' where id in (...) and status in ('registered','pending','inactive')` when the new plan covers today. Don't touch `paused` or `deleted` members.

Example:
```sql
insert into combatrix_membership (member_id, start_date, end_date, price, combatrix_share, fitshala_share, created_at)
values (36, '2026-10-15', '2027-01-14', 9000, 7200, 1800, now());
```
