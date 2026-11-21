# Plugy November web update

The November 17 edits add branch filters to analytics, separate installation
financials, material quantities and photos, bank-funded installation
receipts, wholesale prices and commissions, landed costs for imports, and
loan installments in Accounting. Accounting and Operations use the same
company loan schedules and payment records.

## Database deployment

Use the Plugy production project `orbovqzenjlyshhiuofx`. Take a current backup
and confirm that the [November 5 production update](../production-update-20261105.md)
and [separate audit migration](../20261105194016_detailed_audit_events.sql) are
installed. Review the installed definitions and migration history before
applying any pending files. Apply the pending migrations below in this order,
one complete file at a time. Keep each transaction boundary.

1. [20261117014031_access_revision_conflict_http_409.sql](20261117014031_access_revision_conflict_http_409.sql)
2. [20261117020203_analytics_branch_selection.sql](20261117020203_analytics_branch_selection.sql)
3. [20261117020624_case_insensitive_category_names.sql](20261117020624_case_insensitive_category_names.sql)
4. [20261117022328_installation_bank_stock_receipts.sql](20261117022328_installation_bank_stock_receipts.sql)
5. [20261117023143_wholesale_price_and_commission.sql](20261117023143_wholesale_price_and_commission.sql)
6. [20261117025100_purchase_landed_costs.sql](20261117025100_purchase_landed_costs.sql)
7. [20261117030300_loan_installments.sql](20261117030300_loan_installments.sql)

If the previous loan migration failed with
`ACCESS_UNGUARDED_RPC:public.quotes_admin_list_v1()`, retry the complete
corrected file in step 7. If the SQL Editor reports an aborted transaction,
run `ROLLBACK;` first. A previously successful installation needs no retry.
The quote endpoint remains subject to the separate authorization audit.

The loan migration uses the existing company-loan tables. It retains prior
funding documents, schedules and payments and uses the standard settlement
reversal workflow. Check a branch-scoped report and confirm the same loan
balances appear in both Accounting and Operations before enabling the release.

Once the database update is ready, use **Update from Remote → Deploy HEAD
Commit** in cPanel.

The migrations were tested in an isolated database. Production database
installation and hosted site activation remain separate steps.
