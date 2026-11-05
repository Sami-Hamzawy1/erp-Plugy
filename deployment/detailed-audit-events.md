# Detailed audit entries

New audit entries show recorded item names, SKUs, units, signed quantity changes,
stock before/after, branch, document reference, supplier/account/party where
applicable, operator and Cairo timestamp. Lists preview two items with a remaining
count; View details shows every item and readable field changes. Existing detailed
sale/refund views remain in place. Both Arabic and English are supported.

## Separate database deployment

Apply `supabase/migrations/20261105194016_detailed_audit_events.sql` separately to
EVOX and Plugy **after** the existing combined 5 November production update and
`20261113000000_detailed_sale_audit.sql`. The CLI-generated filename predates those
prerequisite filenames; do not run this migration first solely because of lexical
ordering. It fails when its required reader/installation pool is absent. This
feature does not run SQL, build or publish automatically.

The additive migration records future events only. It does not backfill history,
change stock, replay sales, edit balances, or grant users new permissions.
Reapplication is supported. Historical missing details remain “Not recorded”.
The client can still display legacy entries before this SQL is deployed; complete
new snapshots require the migration.

## Capture and access

Balance-row triggers capture OLD/NEW quantities while the transaction holds its
row locks. Movement triggers attach those snapshots to the matching movement;
document audit events consume them once. Failed transactions roll everything back.
Product, employee, service and company-settings metadata changes also record
readable field snapshots. Existing stock/sale business functions remain unchanged.

Private, RLS-enabled snapshot tables are inaccessible to application roles. Public
audit JSON excludes costs, balances, contacts and all private item lists. The
existing invoker audit reader retains its branch/snapshot checks; a guarded helper
projects permitted fields and per-branch items. Opposite-branch cost values are
conservatively omitted. Existing authorized sale-phone handling is retained.
Credentials and account numbers are never persisted in the new snapshots; salary
fields and generic contact fields are omitted. No historical stock values are
inferred from current quantities.

Only safe, known fields appear in the UI; technical identifiers and raw JSON are
excluded from the detail view. Unknown legacy fields stay hidden rather than
being interpreted as trustworthy descriptions.
