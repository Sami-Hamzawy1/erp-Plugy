# Egypt business time

Both EVOX and Plugy use `Africa/Cairo` for the system clock, receipts,
transaction history, attendance, and report calendar boundaries. Cairo's IANA
timezone rules handle summer and winter offsets; the browser/device timezone
does not select the business timezone.

`EgyptTime.from` converts an absolute timestamp for display. `EgyptTime.date`
and `calendar` construct Egyptian calendar values (including date picker values
and SQL DATE columns). Calendar arithmetic uses `addDays` across daylight-saving
boundaries. Timestamp writes and query limits use explicit UTC; DATE columns
keep their calendar fields.

The mobile and desktop top bars show a live date and clock, refreshed every
second and when the app resumes. Receipts use the original sale timestamp,
including when reprinting, converted to Cairo time.

This change needs an application release for each brand. No new database
migration is required, and no historical timestamps are rewritten. Existing
accounting RPCs already declare `timezone='Africa/Cairo'`.

Verification covers both brand configurations with the process timezone set to
UTC: November 15:22 UTC → 17:22 Cairo, summer time, midnight rollover, UTC write
round trips, English/Arabic clock behavior, and daily/accounting report limits.
English and Arabic A4 and 80mm receipts are generated for each brand and checked
for the correct time and layout.
