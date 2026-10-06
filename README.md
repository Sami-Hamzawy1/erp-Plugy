# PLUGY EV — production web build

This repository contains the compiled Flutter web application. Serve this directory using an HTTPS static web host. The relative base URL supports both a domain root and a repository subpath; use a trailing slash for the application URL.

Build configuration: release mode, APP_ENV=production, Supabase project https://orbovqzenjlyshhiuofx.supabase.co. Only the public Supabase publishable key is included in the browser bundle.

## Backend prerequisites

Uploading these files does not apply database migrations or verify the live backend. The latest release requires the compatible operations/finance schema, authorization v2 and branch confinement through migration 27, checkout migration 29, and the five additive fixes from migration 30 through 20261103000000. Apply missing compatible migrations before activating the web release. See [customer, payment and payroll deployment instructions](deployment/customer-payment-access-fixes.md). Never run fresh setup on an existing database.

## Validation

The latest Flutter JavaScript release build completed successfully. Static analysis of the affected code reported no errors or warnings; the new SQL bodies passed syntax parsing. Release file checksums were generated and checked before upload. No new runtime tests were run, and live authentication, business transactions and visual layouts were not exercised.

## cPanel deployment

The repository-root `.cpanel.yml` deploys only the web application files into the cPanel account's `$HOME/public_html/`. Keep the Git checkout outside `public_html`, for example `$HOME/repositories/erp-Plugy`.

In cPanel, open Git Version Control, manage this repository, and choose Pull or Deploy → Update from Remote → Deploy HEAD Commit. Pull deployment from GitHub is manual; a GitHub push alone does not trigger it. For another domain's document root, adjust DEPLOYPATH in `.cpanel.yml`.

Deployment overwrites matching application files but does not delete unrelated files or copy repository metadata. If another application already occupies the document root, use a dedicated document root instead. No Flutter build is required on the hosting server.

## Latest release: stock receipt administration and inventory cost

Admins can edit/delete posted stock receipts from Transactions → Vendor purchase details. Corrections reverse inventory and payments atomically and retain the original receipt for audit. Inventory analytics → category product details shows recorded unit and stock costs, including unsold products and branch-specific costs.

Before deploying this app, apply the additive SQL files in `deployment/` in filename order, if not already applied. They require the existing compatible finance/security schema. The SQL is not executed by cPanel and is not copied into public_html. See [receipt deployment notes](deployment/stock-receipt-corrections.md). No live database changes were performed during the release upload.

## Latest release: supplier receipts in Operations

Operations → Inventory and Stock → Supplier receipts opens the branch purchase history. Admins can open a receipt and edit or delete it using the secured correction commands. New paid stock receipts explicitly create purchase documents before posting their linked outgoing payments, and refresh the transaction and treasury views.

Before deploying, apply [the additive receipt visibility SQL](deployment/20261021_stock_receipt_transaction_visibility.sql) after migration 20261020. Missing historical headers are restored without replaying payments, inventory or treasury balances; historical payment matching is not guessed. See [deployment notes](deployment/supplier-receipts.md).

## Latest release: 2026-10-06

Rebuilt from source commit `b496759` with Flutter 3.47.4 / Dart 3.13.3. This release includes Sentry error reporting and the checkout fix that keeps walk-in customer details on the invoice when the user lacks permission to create a customer. Production Sentry reporting is enabled; the startup test error is disabled.

Validation: 19 focused checkout and Sentry tests passed; static analysis of the eight affected source/test files reported no issues; the Flutter JavaScript release build succeeded; 10 local HTTP resource checks passed. Production Supabase configuration, the public publishable key, Sentry project, cache-versioned entrypoints and release checksums were verified. No live authentication or business transaction was exercised.

The Sentry and walk-in checkout changes require no database migration. The latest source also contains an additive refund-valuation migration, copied to `deployment/20261028000000_sale_refund_warranty_integrity.sql`. If it has not already been applied, review it against the existing compatible finance backend before applying it separately in Supabase. It preserves deployed behavior outside refund valuation and fails when the existing refund implementation is incompatible. This upload does not apply SQL or activate the cPanel deployment.

Publish through cPanel: **Update from Remote → Deploy HEAD Commit**, then hard-refresh the app.

## Checkout and installations v3 release

This release includes three checkout tax modes, checkout invoice discounts, deterministic line/refund cent allocation, before-tax salesperson commission, invoice branch locking, eligible payment accounts and safe account removal, saved installation quotations with reusable service snapshots, and uncropped inventory pictures. Existing invoice amounts and commission snapshots remain unchanged.

**Apply database compatibility changes before publishing the app.** Confirm the existing schema has migrations through 20261028000000, then apply `deployment/20261029000000_checkout_installations_v3.sql`. See [deployment instructions](deployment/checkout-installations-v3.md). Do not run fresh setup on an existing database. The SQL is not executed by cPanel or copied to public_html. No live database changes have been performed for this release.

Validation: 86 focused Dart tests and three isolated PostgreSQL scenarios passed; static analysis reported no errors or warnings. The Flutter JavaScript release build completed. Ten staged HTTP resources and file checksums were verified. Arabic/English layouts, themes, narrow screens and print layouts still require visual checks before release. Live authentication and business transactions were not exercised.

Production configuration matches the existing Supabase project and public publishable key. Entry points carry a release cache version. Publish in cPanel with **Update from Remote → Deploy HEAD Commit** after applying the database migration.


## Latest release: POS permissions, full payments, installations and payroll

Built from source commit `024d2ea1214f436c25b24af6969b3cb0fa45b302` on 2026-10-06. This release includes:

- Dedicated Installations navigation and improved service editor and quotation-list spacing.
- Branch-linked POS customer creation and separate global customer permissions / branch checks.
- Transaction details with permission-filtered costs and bank selection without exposing balances.
- Branch-aware payment methods, direct full-payment checkout, required references and optional cash change; partial payments keep their split dialog.
- Payroll lists filtered by authorized employee branches, filter-preserving refreshes and explicit feedback when a saved salary is outside the current view.

**Database compatibility must be deployed before the web app.** After the existing compatible authorization, branch and checkout migrations, apply any missing files in this order:

1. [Transaction details cost redaction](deployment/20261030000000_transaction_details_cost_redaction.sql).
2. [Customer RPC permission scope](deployment/20261031000000_customer_rpc_permission_scope.sql).
3. [Payment account selection without balance access](deployment/20261101000000_settlement_account_selection_without_balance.sql).
4. [Branch-aware payment method catalog](deployment/20261102000000_branch_payment_method_catalog.sql).
5. [Branch-aware salary record reads](deployment/20261103000000_branch_salary_record_reads.sql).

The SQL files are supplied for manual Supabase deployment and are excluded from cPanel's web copy. This repo upload does not execute SQL or change live records, balances or role grants. See [deployment instructions and required permissions](deployment/customer-payment-access-fixes.md).

After the migrations, publish in cPanel with **Update from Remote → Deploy HEAD Commit**, then reload the app. Entry points use release cache version `b0d2fd5ed17c27e4`. The existing production Supabase project, public publishable key and Sentry configuration are retained; the startup test error is disabled.


## Latest release: corrected product quantity

Rebuilt the current workspace as `1.0.0+024d2ea.localf78c04bb`. Includes the local correction that displays the actual product quantity without adding 10. The source edit remains staged in the development repository. The Flutter JavaScript release build succeeded. No additional tests or live database changes were performed. Existing backend prerequisites above still apply.

Publish in cPanel with **Update from Remote → Deploy HEAD Commit**, then reload the app. Release cache version: `beb214d749d1c9a5`.
