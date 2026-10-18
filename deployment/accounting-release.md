# Integrated accounting release — October 18, 2026

Built from shared source `d7b32743a68f8aced449d06dadcfdf7b1cee11cd` with Plugy's explicit configuration. This
release includes the branch creation fix already published here, plus the new
Accounting workspace: P&L, monthly budgets, balance sheet and assets, cash flow,
product cost allocation, expense classifications, scoped permissions and audit.

## Database prerequisite

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
