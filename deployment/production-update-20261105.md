# Plugy production update — 5 November 2026

Includes per-branch inventory revision PDFs for ordinary and shared installation stock,
multiple employee branches, asset photos on new/existing assets, Cairo system clock and
receipt/report date alignment, searchable vendor stock product selection, readable audit
summaries and secure email password recovery at `/reset-password`.

## Activate

1. In production Supabase project `orbovqzenjlyshhiuofx`, run the entire
   [`plugy_production_update_20261105.sql`](plugy_production_update_20261105.sql)
   file in SQL Editor. This is the ONE update file for this release. It checks
   existing prerequisites first and commits all four incremental migrations together.
   Success returns `PLUGY_UPDATE_COMPLETE`. If it fails, stop and share the error;
   do not remove checks or run the historical accounting/reset installers.
2. In cPanel Git Version Control, use **Update from Remote → Deploy HEAD Commit**.
3. Reload the app and refresh employee access after assigning branch permissions.
   Shared installation inventory starts empty if newly created; no branch stock is copied.

For password reset emails, Authentication → URL Configuration must use the actual
cPanel production website as Site URL and include its `/reset-password` path or
`/**` pattern in allowed Redirect URLs. Keep `https://plugy-test.web.app/**` if
Firebase testing remains needed. The literal `/**` is an allow-list pattern, not
a webpage. Send a fresh reset email after configuration. Auth URL settings are
not SQL database objects and are not changed by the included SQL file.

## Preservation and verification

The SQL preserves existing accounts, branch memberships, invoices, purchases,
settlements, balances and stock. It retains private photo access and existing
branch/role authorization. Counts and sales/expense/stock totals are checked
within the transaction. Detailed audit snapshots apply to future sales; old
missing audit details are not invented. Existing photos/memberships remain intact
on reapplication. No fresh setup/reset scripts or invoice-specific data repairs
are included. A compatible existing operations/security/accounting schema is required.

The release build passed. 32 auth and 15 audit checks passed for each brand;
11 focused isolated database scenarios passed, including the exact combined SQL,
reapplication and prerequisite failure. Brand/backend identities and versioned
cache refresh entrypoints were verified. No live SQL, password resets or business
transactions were performed. GitHub upload alone does not activate cPanel hosting.
