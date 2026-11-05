# Installation, invoice and loan changes

Shared feature branch: `codex/installation-operations-edits`, based on `main`.
Both brand configuration files and app defaults are unchanged.

## Behavior

- Installations includes the existing inventory and stock receipt tools, with a
  route to the existing material/product editor for photo uploads.
- Stock selection searches the full paginated product catalog. Multiple materials
  can be selected across pages and added together to a quotation or stock receipt.
- Saved services can be activated/deactivated and pinned to new quotations.
  Service costs belong to the saved quotation and become cost snapshots on the
  resulting sale. They are excluded from customer receipts and redacted without
  `report_cost.read`.
- Deleting a quotation archives it and voids its unpaid financial document;
  records remain available for audit. Any sale or settlement history blocks it.
- Inventory valuation uses recorded purchase costs, excluding wholesale/retail
  selling-price fallbacks. Previously recorded balances are not rewritten.
- Sales search uses its own catalog state, searches across categories, and can
  load more results beyond the previous eight-item limit.
- Invoices scroll as one page. Cards show dates, product names and installation
  badges. Search includes invoice numbers, barcodes, customers, phone numbers,
  cashiers and branches, with Arabic digit/name normalization.
- Operations includes company loans. Creating a loan records incoming treasury
  cash; repayments record outgoing cash. Both are classified as loan financing,
  rather than sales or operating expenses. Installments support manual amounts,
  dates and partial repayments, using the existing payment-method catalog and references. Editing the schedule preserves rows with payment
  history. Each create/payment request is idempotent; overpayment and cross-branch
  access are rejected. General void/reversal commands cannot silently detach a
  loan's cash movement from its repayment history.

## Database deployment

No hosted database has been changed. Apply additive SQL separately to EVOX and
Plugy after the existing operations, authorization v2, checkout v3 and quotation
receipt-text migrations. Use an existing backup and each project's own SQL Editor
or reviewed migration workflow; do not run fresh setup/reset scripts.

1. `supabase/migrations/20261112000000_installation_workflow.sql`
2. `supabase/migrations/20261112000001_company_loans.sql`

Company loans additionally requires the existing integrated accounting migration
`20261106000000_integrated_accounting.sql`. Install it only if missing; it is not
an idempotent script. The loan migration stops before changes if this prerequisite
is missing. Existing subsequent accounting migrations remain applicable.

The new scripts are dated after the repository's existing latest migration so
normal ordered deployment does not run them ahead of their prerequisites. Neither
script changes saved balances or inventory quantities. Both can be reapplied.
Existing records whose costs were historically estimated from selling prices need
separate reconciliation; this change does not guess or overwrite historical cost.

Permissions reuse `installation.update`, `report_cost.read`, `transaction.read`,
`manual_transaction.create`, `transaction_settlement.create`, and the existing
branch memberships and treasury-account permissions. No default grants are added.

## Focused verification

- Local PGlite integration test: `tools/database-tests/installation-loans-workflow.test.mjs`.
- Flutter: invoice grid/search, installation receipts, catalog picker, receipt
  failure/retry and inventory valuation tests under each brand configuration.
- Static analysis of the affected feature files and `git diff --check`.

No release build or publication is part of this change.
