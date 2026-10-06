# Customer creation and payment details fixes

## Customer creation

The checkout quick-add form now uses the existing `create_customer_v1` RPC.
It creates the customer and branch membership atomically, avoiding the direct
insert rejected by `customers_unit_guard`. The form receives the invoice's local
branch and requires `customer.create` (or the existing legacy `manageCustomers`
permission). Users without it can enter walk-in details on the invoice.

This client fix requires a rebuilt application. It does not relax customer RLS.

If the error is `ACCESS_PERMISSION_DENIED:customer.create` despite an effective
global grant, apply
`20261031000000_customer_rpc_permission_scope.sql` after the
authorization and branch-confinement migrations (normally after migration 30).
The old guard passes the invoice branch to `customer.create`, even though it is
a global permission; the evaluator always rejects a non-null scope for global
permissions. Customer search has the same mismatch for `customer.read`.
Migration 31 checks these permissions globally and separately validates an
active, authorized branch. It preserves the customer creation RPC, atomic branch
membership, RLS, legacy behavior, records and role grants. Global customer grants
must still be effective; a branch-only role assignment does not grant global
permissions. This server fix needs no web rebuild if the running client already
uses `create_customer_v1`.

## Payment details

After the existing authorization migrations and checkout migration 29, apply
`20261030000000_transaction_details_cost_redaction.sql`.
It removes the extra `report_cost.read` requirement from opening transaction
details and redacts line costs, commission and customer-contact fields according
to their individual permissions. Existing transaction-detail permissions, branch
checks, account eligibility, payment creation and reversal checks remain active.
The migration changes functions only; it does not replay payments or change
records, balances or grants. It works with existing clients.

For a new empty database, apply this migration after the documented subsequent
authorization migrations; the fresh foundation bundle does not activate v2 itself.

Authorized users still need `transaction_detail.read` to open the document,
`transaction_settlement.create` to add payments, and
`transaction_settlement.reverse` to reverse payments in the relevant branch.
Checkout payments use `sale_settlement.create`. No role grants are changed
automatically.

## Selecting bank accounts without seeing balances

Apply `20261101000000_settlement_account_selection_without_balance.sql`
after migrations 30 and 31. Account selection now requires
`settlement_account.select` in the invoice branch, independently of
`treasury_account.balance.read`. The list returns active accounts in that branch,
including shared bank, wallet and Instapay accounts. It omits the balance field
unless the actor has balance-read permission for the account's own scope; it
never exposes account numbers or opening balances. Existing checkout already
shows names/types, and payment dialogs show a balance only when returned.

Shared non-cash accounts may receive invoice payments through checkout or
transaction settlement in an authorized branch. Submission still requires the
original sale/payment permissions and branch write access. Account eligibility,
inactive-account rejection, method matching and balance validation stay on the
server. Account transfers, ledger access and treasury management retain their
original restrictions. Cash remains tied to its branch. This migration updates
functions only, preserves legacy behavior, and needs no client rebuild.

For a salesperson, enable `settlement_account.select` and
`sale_settlement.create` for their invoice branch, together with the existing
sale permissions. Leave `treasury_account.balance.read` disabled if balances
should be hidden. Payment creation in Transactions additionally needs
`transaction_settlement.create`. Recheck branch and shared-bank selection,
balance omission, submission, inactive accounts and other-branch rejection after
deployment.

## Full payments and branch payment methods

Apply `20261102000000_branch_payment_method_catalog.sql`
before publishing the updated web application. It provides
`list_payment_methods_v3(location_id,active_only)`, which checks
`payment_method.read` for the requested invoice branch instead of reading shared
catalog rows with a null branch scope. Direct catalog RLS is unchanged, and the
RPC is registered with the authorization coverage registry when v2 exists. The
fresh setup sources include this API without activating v2.
If authorization v2 is installed later on a fresh foundation, reapply this
idempotent migration after installing v2 and before activating enforcement so
the RPC is registered with its coverage registry.

Enable **Payment method · View / طريقة الدفع · عرض** (`payment_method.read`)
for the salesperson's invoice branch. Missing permission now produces the
actual permission denial rather than silently returning an empty catalog. No
accounts or payment methods are created automatically.

Full payments use the selected account and method directly from checkout.
Required references and optional cash tender/change are entered there. Partial
payments retain the split-payment dialog. Checkout revalidates active methods
and eligible accounts immediately before confirming. Empty lists display access
guidance instead of the misleading “Create an active account and payment method”
state exception. These client changes require a rebuilt, published web release.

## Salary records disappearing after creation

Apply `20261103000000_branch_salary_record_reads.sql`
before publishing the updated app. Payroll lists now filter employee membership
on the server, rather than requiring the client to read `profile_locations`
before it can see salary rows. Activated users retain the existing per-employee
`salary.read_own` / `salary.read_all` and branch predicates. Legacy rows retain
their original RLS. Profile names remain protected by profile visibility.
No salary, balance, role assignment or permission grant is changed.

The app preserves its employee/status filters during refreshes, reloads after
branch or access changes, and discards superseded list responses. Creating a
draft clears the approved/paid status filter. It confirms that the saved record
appears before displaying the ordinary success message. If saving succeeds but
the read fails or the record is outside the selected branch/read permissions,
the message says the salary is already saved and must not be created again.

For existing hidden records, select the employee's assigned branch or **All
branches** if authorized, and **All statuses**. Employees must be assigned to
the selected branch to appear in its payroll list. Creation permission
`salary.generate` and viewing permission `salary.read_all` are separate; no
extra user-assignment read permission is needed for the list. The salesperson
needs `salary.read_own` to see their own record.

The fresh setup bundle includes this API. If v2 is installed later, reapply the
idempotent migration before enforcement activation to register the API. These
changes require the database migration followed by a rebuilt web release.

No live database changes were made. Recheck opening a branch transaction without
cost permission, adding/reversing an authorized payment, and rejecting a document
in another branch after deployment.
