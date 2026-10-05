# PLUGY EV — production web build

This repository contains the compiled Flutter web application. Serve this directory using an HTTPS static web host. The relative base URL supports both a domain root and a repository subpath; use a trailing slash for the application URL.

Build configuration: release mode, APP_ENV=production, Supabase project https://orbovqzenjlyshhiuofx.supabase.co. Only the public Supabase publishable key is included in the browser bundle.

## Backend prerequisites

Uploading these files does not apply database migrations or verify the live backend. Before activating this release, confirm the compatible operations/finance foundations and the additive migrations through 20261021_stock_receipt_transaction_visibility.sql are deployed and verified. This includes unified transactions, setup checks, treasury account locations, security hardening, expense assets, product stock editing, opening costs and salesperson commissions. Follow the deployment guides in the source workspace. Never run fresh setup on an existing database.

## Validation

The Flutter production web build completed successfully. The latest receipt changes passed eight focused database tests and 17 Flutter tests, plus static analysis. Static entrypoint and asset checks passed before upload. Live authentication and business transactions were not tested.

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
