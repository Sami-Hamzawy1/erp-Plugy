# Separate EV installation financials

This production release keeps Plugy's existing backend `orbovqzenjlyshhiuofx`.
Installations -> Financials shows separate revenue, saved material/landed costs,
linked payment fees, profit, refunds, deposits and outstanding invoice balances.
Installation invoices/refunds stay available for receipts and refund operations,
while ordinary sales, profit, dashboard and shift summaries exclude them.

The additive `20261112000000_separate_installation_financials.sql` is included
for review if missing. A read-only production probe found the new installation
report and invoice-classification endpoints (anonymous execution is denied).
Authenticated business operations were not exercised. This upload executes no
SQL, resets no data and changes no users or grants. Run the read-only preflight
and inspect installed definitions before applying only missing compatible
migrations; never run fresh/bootstrap/reset SQL on production.

The existing `.cpanel.yml`, relative base URL, service worker retirement and
versioned entrypoints are preserved. Activate through cPanel's Git interface:
**Update from Remote -> Deploy HEAD Commit**. A GitHub push alone does not
activate the live cPanel site.
