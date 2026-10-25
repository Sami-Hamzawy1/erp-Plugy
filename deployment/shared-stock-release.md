# Complete Plugy feature release

Includes shared installation inventory (Installations -> Shared installation inventory),
bank deletion/deactivation controls on Transactions, readable itemized sale audits,
user deactivation fixes, image loading/retry improvements, and separate installation
financials. Quotation materials consume the shared pool on sale and restore it on
refund; ordinary branch stock remains separate. Existing Plugy branding and backend
are preserved. EVOX-only print customization and test backend settings are excluded.

## Database deployment required

Read-only production API probes found the financials endpoint, but the installation
inventory and detailed audit endpoints were absent from the API schema cache.
Run sql_editor_release_preflight.sql and review installed definitions. If still
missing, apply 20261112000000_global_installation_inventory.sql after existing
accounting/refund/fee/balance-sheet/financials migrations, then apply
20261113000000_detailed_sale_audit.sql. The financials SQL is included for reference;
its endpoint already exists, so do not blindly replay it or older migrations.
No live SQL or business transactions were executed for this release.

After SQL deployment, grant intended users the global installation_inventory.read,
installation_inventory.use and installation_inventory.manage permissions and refresh
their sessions. The shared pool starts empty; explicitly add its materials and
quantities. Existing branch inventory is not copied automatically.

## Hosting activation

cPanel: Update from Remote -> Deploy HEAD Commit. Existing .cpanel.yml, relative
base URL, worker retirement and versioned entrypoints are preserved. A repository
push does not activate cPanel hosting.

## Verification

109 focused Plugy tests and 25 EVOX compatibility tests passed; affected Dart files
passed analysis. Four isolated stock/audit database scenarios passed, plus two stock
scenarios rerun with the financials migration included and the financial reporting
SQL fixture with stock/audit migrations installed. Authenticated live workflows
were not exercised.
