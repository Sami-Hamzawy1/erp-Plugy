# Expense deletion / reversal SQL repair

Source repair: `54d4cd8332b41c59f991b2dd67e3b8ec7e206f23`. The compiled web application is unchanged.

The Expenses delete button calls the checked `public.void_expense(uuid)` RPC.
Dynamic authorization copied its implementation into a private function, leaving
an obsolete `void_expense.expense_id` reference. That can raise
`missing FROM-clause entry for table "void_expense"` before the reversal completes.

In Plugy's existing Supabase project, run the entire
[additive repair migration](20261108000000_expense_void_parameter_scope.sql), then retry the expense deletion. The repair
requires the installed dynamic-access wrapper and is safe to repeat. It patches
only the private implementation's parameter reference. Public authorization,
branch confinement and the transaction reversal implementation remain intact.

Local PostgreSQL verification reproduced the old error before the repair and
passed after it. Paid expense reversal restores the selected account balance
exactly once, retains the expense/document history, and writes one audited void.
Retries remain idempotent; cashiers and unrelated-branch admins remain denied.
Fresh installations and the accounting SQL validator include the regression.

This upload does not execute SQL or delete any production expense. Apply the SQL
separately as project owner. Existing accounting migration prerequisites remain
listed in [the accounting release notes](accounting-release.md).
