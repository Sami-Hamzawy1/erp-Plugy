# Integrated accounting release — October 18, 2026

Built from shared source `d7b32743a68f8aced449d06dadcfdf7b1cee11cd` with Plugy's explicit configuration. This
release includes the branch creation fix already published here, plus the new
Accounting workspace: P&L, monthly budgets, balance sheet and assets, cash flow,
product cost allocation, expense classifications, scoped permissions and audit.

## Database prerequisite

Apply these files in order in **Plugy’s Supabase SQL Editor**:

1. [Checkout-v3 authorization registration](20261104000000_checkout_v3_access_registration.sql).
2. [Integrated accounting](20261106000000_integrated_accounting.sql).

The registration prerequisite is safe to repeat. It registers the existing checked
checkout endpoints with the authorization coverage audit and restores the service
catalog's restrictive read policy. It does not remove access checks, broaden role
grants or modify business records.

### If accounting fails with `ACCESS_UNGUARDED_RPC:public.installation_services_v3(jsonb)`

The registration prerequisite is missing from that database. Apply file 1 above,
then rerun the **entire** accounting file. A full-file accounting run uses a single
transaction; the reported coverage failure rolls that transaction back. Keep the
coverage check in place.

This exact missing-prerequisite state was reproduced in isolated PostgreSQL. The
registration prerequisite, including a repeated application, restored coverage
without changing the service function implementation. The accounting migration
and existing SQL scenarios then passed. No live database was modified.

Before activating the updated client, review and apply
[the additive accounting migration](20261106000000_integrated_accounting.sql) separately in Plugy's existing
Supabase project, if it has not already been applied. The migration requires the
existing operations, dynamic access, expense-assets and checkout-v3 schema through
`20261105000000_installation_receipt_text.sql`. Preserve all existing data; do not
run reset/bootstrap scripts. Git pushes and cPanel deployment do not execute SQL.

Grant the new accounting permissions, classify historical expenses, configure
asset depreciation schedules, and review opening balances and reconciliation
warnings. No live database changes or authenticated business transactions were
performed by this release upload.

The comparison of requirements and remaining implementation limits is in the
[source requirements comparison](https://github.com/Desha29/bayaa-platform/blob/d7b32743a68f8aced449d06dadcfdf7b1cee11cd/docs/accounting-requirements-comparison.md).
Some legacy financial reports remain on older calculations; the ABC table compares
purchase cohorts, and embedded purchase costs still require admin review.

## Hosting and validation

The existing cPanel deployment path and file-copy rules are preserved. Relative
base URLs, versioned entrypoints and retirement of previous Flutter offline caches
are retained. Public Supabase and Sentry settings match the previous release.
Deployment documents and SQL remain outside the copied public application files.

Local checks: 92 focused tests passed per brand, 7 default-configuration tests
passed per app branch, isolated accounting SQL scenarios passed, focused static
analysis passed, and GitHub checks passed on all three shared/app branches. The
web release built successfully; staged browser/resource checks are recorded in
`release.json`.

After prerequisites are ready, activate using cPanel Git Version Control:
**Update from Remote → Deploy HEAD Commit**. A GitHub push alone does not activate
the hosted website. The live deployment has not been verified by this upload.

## Expense reversal follow-up

If the Expenses delete action fails, review and apply the
[additive parameter-scope repair](20261108000000_expense_void_parameter_scope.sql).
It preserves the existing permission wrapper and reversal history.
See [the repair notes](expense-void-fix.md) for verified behavior.
