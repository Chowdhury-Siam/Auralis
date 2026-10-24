# Multi-device sync

Auralis 0.1.64 adds a private sync space for Android and Windows. This adapts
Yutaka's self-hosted service, offline edits and live change notifications to music
data. It is a separate Auralis service: do not enter your Yutaka finance Worker URL.
It uses Cloudflare Durable Objects with SQLite; no Turso database is required.

## One-time deployment

1. In Auralis, open **Settings → Multi-device sync → Create key**. Keep the copied
   64-character key private. This is the key for your own sync space.
2. In your Auralis GitHub repository, add these Actions **secrets**:
   - `CLOUDFLARE_API_TOKEN`: a token created using Cloudflare's **Edit Cloudflare
     Workers** template for your account.
   - `CLOUDFLARE_ACCOUNT_ID`: the account ID shown in Cloudflare.
   - `AURALIS_SYNC_KEY`: the key created in the app.
3. Optionally add the Actions **variable** `CLOUDFLARE_WORKER_NAME`. The default is
   `auralis-sync`; use a unique lowercase name if you already have one with that name.
4. Commit this complete source to `main`. Run **Actions → Deploy Auralis sync
   service → Run workflow**. The job tests the service, deploys it and sets its
   private key. Open the deployed worker in Cloudflare and copy its HTTPS
   `workers.dev` URL. It is also printed by the deployment while its logs remain
   available; cleanup may remove the completed green workflow run.
5. Enter that URL and the same key in the app and choose **Connect and merge**.
   The key and URL are stored in Android Keystore-protected storage or Windows
   DPAPI, separately from Telegram credentials.
6. On your connected device, choose **Copy connection**. On another device choose
   **Paste connection**, then **Connect and merge**. These connection details
   include the private key; share them only with your own devices.

Sign in to Telegram on each device and use the same music channels. Synced
references do not grant access to channels that the Telegram account cannot read.
No service is deployed, credential created in your account or GitHub repository
changed merely by downloading this source archive. Run the deployment workflow
with your own settings to activate cloud sync. Changing the service key requires
reconnecting your devices with the new key.

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
Auralis's existing collection/backup validation also applies. Same-field
simultaneous edits resolve deterministically rather than presenting a merge dialog.

## Checks

`node --test cloud/worker/worker.test.mjs` tests the real service handler and merge
logic against local SQLite with a Cloudflare storage adapter. Flutter regressions
cover the client document and atomic metadata persistence. These are local checks;
Cloudflare deployment, real-device timing and live multi-device Flutter execution
require your service and native builds. The editing environment has no Flutter SDK.
