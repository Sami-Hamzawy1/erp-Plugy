# Asset photos

- Choose **Add photos** while creating an asset. Pictures are uploaded after the
  purchase has saved. If an upload fails, the purchase remains saved once and the
  app directs the user to the asset's Photos button to add the missing pictures.
- Existing assets, including old acquisitions, have a **Photos** action in the
  asset register. The asset editor also provides **View and edit photos**. Adding
  or removing pictures does not change acquisition amounts, dates or payments,
  and does not require opening a shift.
- Authorized readers can view images. Photo changes use the existing asset edit
  boundary: admin role, branch management access and `expense.replace` for v2.
  Images use a private bucket and short-lived signed URLs. Files are JPG, PNG or
  WebP, up to 10 MB each. Financial corrections retain the pictures on the
  replacement asset atomically. Unlinking a photo retains any historical copies.

Apply `supabase/migrations/20261105145638_asset_photos.sql` separately to EVOX and
Plugy before releasing the app. It requires the existing assets, dynamic access
and branch-confinement migrations through `20261027000000_branch_scope_confinement.sql`.
The SQL Editor packet includes it after the existing release changes. The
migration creates private photo metadata, a private `asset-photos` storage bucket,
branch-checked policies and a guarded photo API; it preserves records and balances.
It is safe to reapply. No live project is changed by implementation or app builds.

Focused verification covers old/new asset photos, Arabic/English mobile and
desktop flows, read-only users, upload failure after purchase, private signed URLs,
retry identity, branch isolation, unchanged balances and correction retries.
