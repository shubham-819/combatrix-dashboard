# Instructions for agents

- The dashboard is hosted on GitHub. Merging to the default branch (`claude/admiring-hawking-p97q1x`) deploys it: once merged, the change is live. No separate deploy step.
- Because a merge goes live, only merge when the user has asked for it.
- Database changes live in `supabase/migrations/`. Ask the user before applying any migration.
