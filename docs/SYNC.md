# Multi-device sync

Auralis 0.1.68 uses the same deployment pattern as Yutaka: a private Cloudflare
Worker connected to a Turso database, with setup and redeployment inside the app.
Auralis stores music collection/listening metadata in Turso; Cloudflare Durable
Objects serialize requests and deliver live change notifications. Use a separate
Auralis Worker and database, rather than your Yutaka finance Worker.

## Deploy from Android or Windows

1. Create a dedicated database at <https://turso.tech/>. Copy its database URL
   (`libsql://…turso.io`, `turso://…turso.io` or its HTTPS equivalent) and a database
   **read/write auth token**. As in the inspected Yutaka setup, this flow prepares
   tables in an existing database; it does not create your Turso account/database
   through a platform-management token.
2. In Cloudflare Workers & Pages, note your 32-character Account ID and create an
   API token using **Edit Cloudflare Workers** for that account. Initialize the
   account's `workers.dev` subdomain once in Cloudflare if it has none.
3. In Auralis open **Settings → Multi-device sync → Set up / redeploy cloud sync**.
4. Enter a Worker name, Cloudflare Account ID/API token, and Turso URL/database
   token. Auralis generates a private sync key; retain it for redeployment.
5. Choose **Deploy and connect**. The app checks Cloudflare, prepares its four
   non-destructive SQL schema statements, uploads the bundled Worker modules and
   secret bindings together, enables its `workers.dev` address, verifies health
   and database access, and connects/merges this device's library.
6. On this device choose **Copy connection**. On each other device choose **Paste
   connection → Connect and merge**. Pairing shares only the service URL and sync
   key, not Cloudflare administration credentials or the Turso database token.

Deployment credentials are saved separately from Telegram/sync connection
credentials using Android Keystore or Windows DPAPI. Reopening the setup page
restores the protected values and offers **Redeploy and connect** to upload the
service included in the current app. Updates are explicit on this page, not an
unattended deployment. A failed request does not delete remote data. Saved inputs
and the generated key are retained for a retry even if an upload succeeded before
its health check timed out. An expired Turso database token can be replaced here.

## Existing Workers and older sync spaces

Redeployment authenticates the existing private sync key and verifies that the
Worker is an Auralis service connected to the same Turso URL. It refuses to
replace another service or silently switch an existing service to another
database. The Cloudflare namespace is preserved on code updates.

For the older Durable-Object-only service, use a **new Worker name** and dedicated
Turso database, then pair all devices to the new URL. This keeps the old cloud
space intact. Connecting merges local collections/statistics into the new space;
make a local backup first if some data exists only on an offline device. Existing
DO-only deployments continue to work when no Turso bindings are configured. A
partially configured or unavailable Turso backend never falls back to a different
local store. Removing a local connection or reinstalling does not delete your
Cloudflare Worker or Turso database.

## Optional GitHub deployment

The **Deploy Auralis sync service** workflow uses the same Worker modules and
non-destructive schema with an atomic multipart upload. Add repository secrets
`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `TURSO_DATABASE_URL`,
`TURSO_AUTH_TOKEN` and `AURALIS_SYNC_KEY`. Optionally set the repository variable
`CLOUDFLARE_WORKER_NAME` (default `auralis-sync`). Push the complete project to
`main` and run the workflow there. Use the same values if the app will later
redeploy that service. No Cloudflare/Turso resource is created merely by
installing the app or downloading this source.

Sign in to Telegram on each device and use the same channels. Sync references do
not grant access to channels that the Telegram account cannot read.

## What syncs

- Favorites, playlist membership/order, playlist deletion and recent tracks.
- Channel selections, library sort and repeat preference.
- Listening history: track/day totals and captured song metadata.

Playback, the current queue, volume, automatic-update preference, Telegram login,
API credentials, music files, artwork, imported lyrics and sleep timers remain
local. The service stores music collection and listening metadata; transport uses
HTTPS and a private bearer key. This is not an end-to-end encrypted music vault.
Disconnect keeps local and cloud data and stops syncing on that device.

## Merge and reliability

Local edits and their pending operations are written in the same atomic settings
file before upload. Requests are bounded batches and responses use a revision
cursor, so retries and repeated pages are safe. Missing connectivity keeps local
changes pending. Live WebSocket notifications trigger a sync; a 30-second poll
and return-to-app check recover missed notifications. Listening uploads are
throttled to thirty-second intervals; favorites and playlist changes use a short
debounce. In-flight counter changes remain pending rather than causing continuous
back-and-forth writes while both devices are playing. Final samples also get a best-effort sync on backgrounding and shutdown.
Sync is paused during backup/account restore. Credentials and sync internals are excluded from portable
backups.

Favorites and playlist entries carry deletion tombstones. Independent playlist
entries merge; conflicting changes to the same field use a logical clock and a
stable device-ID tie-break. Playlist names are compared without case, so `Mix`
and `mix` do not create duplicate playlists. Rename/delete/recreate conflicts use
that same deterministic rule; a later recreated playlist excludes older entries.
Tombstones are retained so an offline device cannot revive deleted entries.

Initial pairing pulls existing cloud components before uploading a baseline.
Already represented per-device time is subtracted from a restored aggregate, so
reconnecting or pairing a copied backup does not count that cloud history again.
The remaining pre-sync history uses a shared maximum per-track/day baseline. New listening after connection uses additive per-device counters. If two
devices have different partially overlapping histories before their first
connection, their exact overlap cannot be reconstructed; the baseline uses the
maximum rather than adding both complete histories. Restoring older statistics
while sync is connected does not subtract already synced listening time.

The service permits up to 32 live devices and 50,000 field records per sync space;
requests contain at most 100 operations and pulls contain at most 200 records.
Turso writes use conditional transactions with a revision compare-and-swap guard,
rollback on any statement failure and bounded retries when a competing writer
changes the revision. Notifications are sent only after the transaction commits.
Auralis's existing collection/backup validation also applies. Same-field
simultaneous edits resolve deterministically rather than presenting a merge dialog.

## Checks

`node --test cloud/worker/worker.test.mjs cloud/worker/turso.test.mjs cloud/worker/deploy.test.mjs`
tests the real handler, Turso transactions and deployment orchestration using
local SQLite protocol adapters and mock Cloudflare responses. Flutter regressions
cover the client document and atomic metadata persistence. These are local checks;
Cloudflare deployment, real-device timing and live multi-device Flutter execution
require your service and native builds. The editing environment has no Flutter SDK.
