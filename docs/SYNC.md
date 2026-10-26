# Account & sync

Auralis 0.1.76 supports username/password accounts on a self-hosted Cloudflare
Worker with a Turso database. Open Settings → Account & sync to validate a Worker,
deploy the service, and sign in or create an account. Other devices need the same
Worker URL, username and password.

## Deploy Database

1. Copy your Cloudflare Account ID. Create a token with Workers Scripts Edit
   permission and configure your workers.dev subdomain.
2. Create or select a dedicated Turso database and copy its database URL and
   read/write authentication token.
3. Enter those values and a Worker name in Deploy Database. Generate a JWT secret
   for a new service. Preserve it for all future updates.
4. Deploy Worker. Auralis prepares tables, uploads three modules, verifies the
   service and saves encrypted recovery values.
5. Return to Account & sync, validate the URL and create the owner account.
   Deployment proof is supplied automatically on the deploying device. On another
   device, enter the same setup secret. Knowing the public URL cannot claim ownership.
6. Save the recovery code shown after registration somewhere private.

The first account is the administrator. Later registrations get separate libraries.
The same ROOM Durable Object binding handles account records and private rooms;
no new Durable Object class or namespace migration is introduced.

## Existing private-key Workers

Redeploy the **same Worker name and Turso database**, using the **existing sync key
as the JWT secret**. Create the owner account on the deploying device, or enter the
old key as setup proof. That owner inherits the original private-library space;
other accounts get separate rooms and table namespaces. Once the owner exists,
legacy shared-key data access stops. Update other devices and sign in to the owner
account to merge their pending local edits.

Do not rotate the secret, change databases, rename the Worker or replace its
Durable Object namespace as part of an update. Deployment refuses an unrelated
Worker or a changed database. The registry holds accounts, revocable sessions and
the encrypted deployment recovery vault; Turso holds library records. DO-only
services also support isolated accounts when manually deployed without Turso.

## Accounts and local data

The first sign-in can merge an unassigned local library. Switching accounts loads
that account's saved snapshot and outbox or an empty library. It never uploads the
previous user's favorites or statistics to the next user. Settings and pending
operations are journaled in protected local storage before committing a switch;
startup can recover an interrupted settings write. Device volume, music, playback
and Telegram sign-in are kept outside shared fields.

Switch account lists remembered users and Workers. Expired sign-ins require a
password again. Forgetting a saved account is blocked while it has unsynced edits.
Sign out offers Keep local or Clear local; its saved snapshot and cloud library
remain available after signing in again. Offline sign-out removes the local token;
a server session that could not be revoked expires normally.

Restore cloud copy explicitly replaces shared local fields, retaining the prior
snapshot in the protected account journal. Upload local changes flushes the normal
merge outbox. Account deletion requires a password and removes only that user's
records and sessions. Deleting the owner also removes its recovery vault, without
promoting a new administrator or deleting other users.

## Recovery and automatic Worker updates

Sign in as owner after reinstalling to recover deployment values from the Worker
and protect them in this device's credential vault. Other accounts cannot read
them; they remain locked locally after owner sign-out. Values are encrypted with
AES-GCM. Passwords use salted, peppered PBKDF2 SHA-256 hashes. Signed tokens expire
after 30 days and every HTTP request checks the revocable session registry.
Logout and recovery close the affected live sockets; expiry closes notifications.

Automatic Worker updates redeploy only when the installed app bundles a newer
Worker. Checks run at startup, after sign-in and on resume. They preserve the
secret, name, database and namespace. Manual deployment and automatic updates
share an operation lock. Values and the automatic-update preference are stored
per Worker. Failures keep the local library and credentials for retry. Forget
saved deployment credentials removes the local values and, for a signed-in owner,
the remote recovery copy.

Use Recover with recovery code in the app or open `<Worker URL>/profile`.
A recovery code works once, rotates to a new code and revokes earlier sessions.
The owner can also sign in on `/profile` to reset another user's password. Losing
both the owner password and its recovery code has no application bypass.

## What syncs

Favorites, playlists, recent music, listening statistics, selected channels,
library sort and repeat preference. Music bytes, Telegram credentials, device
volume, downloads and live playback are excluded. Existing field clocks,
tombstones, per-device listening counters and durable outboxes remain unchanged.
WebSockets notify the matching account, with polling as fallback.

There is no hosted default cloud. The service limits accounts to 100 per Worker,
saved sessions to 32 per account, live sockets to 32 per room and records to 50,000
per account. Authentication attempts are limited by address and username.

## Deployment and validation

The GitHub deployment workflow uploads worker.mjs, turso.mjs and accounts.mjs,
retaining AURALIS_SYNC_KEY as JWT_SECRET. It installs both bindings in the same
upload and saves owner recovery credentials after verification.

Run `node --test cloud/worker/*.test.mjs` for handler, migration, isolation,
recovery, revocation and deployment checks. Flutter tests cover switching, offline
edits, rollback, restart recovery, owner credential access and responsive forms.
These checks use fakes and SQLite; live Cloudflare deployment and real-device
multi-account timing require your deployment credentials.

For this source delivery, 52 focused Flutter checks and 34 backend/release checks
passed, and static analysis reported no issues. The broader suite did not finish
in this runtime because an existing image-driven widget test stalled; no live
Worker deployment or device build was performed.
