# Employee branch access

In **Settings → Users**, add or edit an employee and use **Branch access → Choose
branches**. Select one or more branches, mark a default, and keep the appropriate
View data / Manage setting for each branch. The default branch must be viewable.
Profile-only edits and employees without branch-assignment permission cannot
change these settings.

The permissions editor also supports multiple branches and shows all assigned
branches. Saving an unrelated permission no longer replaces multiple memberships
with the first branch or clears the employee's role assignments. Retained branches
keep their existing permissions and denials. Newly selected branches copy the
previous default branch's scoped rights and expiry dates; global and personal
rights stay in their original scope. The employee can switch between authorized
branches after their access context refreshes.

## Deployment

Apply `supabase/migrations/20261105142438_employee_multi_branch_access.sql`
separately to EVOX and Plugy before deploying the updated app. It requires the
existing security hardening, dynamic authorization, admin role, safe-update and
branch-confinement migrations through `20261027000000_branch_scope_confinement.sql`.
The SQL Editor packet includes it after the existing release migrations.

This additive migration exposes an atomic employee save command and adds branch
memberships to the protected access overview. Invalid, unauthorized or stale
branch edits roll back the employee save, including new credentials. It does not
change existing records or grant access to existing employees when applied.
No live deployment is performed by implementing or building this feature.
