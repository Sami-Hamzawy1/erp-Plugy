# Checkout and installations v3 deployment

Apply database changes before distributing the updated Flutter application.

## Existing databases

1. Back up the database and confirm the existing migrations through `20261028000000_sale_refund_warranty_integrity.sql` are applied in their documented order.
2. Apply `supabase/migrations/20261029000000_checkout_installations_v3.sql` once. It extends existing checkout and quotation functions while retaining their authorization, branch confinement, stock, warranty, settlement and idempotency behavior.
3. Distribute the application after the migration succeeds. No fresh setup, reset, historical financial backfill, or live data cleanup is required.

The migration adds explicit tax modes, saved net/gross line amounts, service templates and safe treasury account removal. Existing invoices retain `legacy` mode and their recorded amounts. Older application clients retain their original checkout behavior. Bank accounts remain subject to the existing account location and authorization rules; the new picker does not grant access to additional accounts.

## Empty databases

Use the updated `supabase/bootstrap/fresh_setup.sql` only on an empty database. Its source list includes the new migration. The existing setup guard prevents using it to replace a populated database. Follow the existing bootstrap instructions for subsequent authorization migrations.

## Focused verification

The Dart regression tests cover the three tax modes, included VAT, invoice discounts, cent allocation, decimal quantities, invoice mapping, repeated refunds, quotation snapshots and draft branch locks:

```sh
flutter test --no-pub test/features/pos/checkout_v3_test.dart test/features/pos/checkout_calculator_test.dart test/features/pos/discount_calculator_test.dart test/features/invoice/refund_calculation_service_test.dart test/core/security/branch_scope_test.dart test/features/installations/installation_calculation_test.dart test/features/invoice/egyptian_einvoice_service_test.dart test/features/operations/payment_methods_test.dart
```

`test/supabase/checkout_v3.sql` is a rollback-only integration fixture for a **disposable local database** after setup/migrations. It exercises the real finance functions, including bank selection/removal, immutable commission, repeated refunds, service snapshots, quotation conversion and deposit transfer. It also checks activated salesperson permissions and protected read projections when authorization v2 is installed. Do not run this fixture as a deployment migration.

Run the isolated PostgreSQL tests through the existing database test harness:

```sh
node --test tools/database-tests/checkout-v3.test.mjs tools/database-tests/fresh-setup.test.mjs
```

The compatibility guard in the existing refund migration also recognizes the new snapshot implementation when authorization migrations follow a fresh setup.

Before release, check checkout and quotation screens in Arabic/English, RTL, both themes and narrow layouts. Verify bank choices for the intended role and branch, branch lock/discard behavior, uncropped inventory pictures and quotation/invoice printing.

No application build or live database change was performed as part of this workspace implementation.
