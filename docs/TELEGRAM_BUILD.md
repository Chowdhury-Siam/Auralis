# Telegram application credentials in release builds

Starting with 0.1.67+68, Android and Windows releases can use one Telegram API
application registered for Auralis. Users then sign in with their own phone
number, Telegram verification code and optional two-step password. They do not
enter API credentials. Existing/restored sessions keep their saved API identity;
a fresh sign-in after logout uses the configured build identity.

## One-time repository setup

1. Register your Auralis application at <https://my.telegram.org/apps>.
2. Open <https://github.com/Chowdhury-Siam/Auralis/settings/secrets/actions>.
3. Add these **repository secrets**, using the values from that application:

   | Secret | Value |
   | --- | --- |
   | `TELEGRAM_API_ID` | Positive numeric application ID |
   | `TELEGRAM_API_HASH` | 32-character hexadecimal application hash |

4. Push the complete source to `main`, or run both build workflows on the same
   updated main commit. Both builds read the same pair.

The workflow changes are included in this source. Actual credentials were not
provided, and repository secrets have not been created from this workspace.
Non-PR builds stop with an explicit setup error if either value is missing or
invalid; they do not silently publish a release that asks users for API details.

## Build behavior

`tool/telegram-build-config.py` validates the secret values and writes
`auralis-telegram-build.json` under the runner's temporary directory. Flutter
receives only its path through `--dart-define-from-file`; secret values are not
printed or interpolated into shell commands. The temporary file is removed
after the build, including when compilation fails. It is outside the packaged
source and artifact directories. GitHub secrets protect source/log handling;
application credentials included in a client binary can still be extracted.
They do not authenticate a user's Telegram account by themselves.

PR builds deliberately use an empty define file and retain manual API setup.
Local builds without defines do the same. For a local configured build, set
`TELEGRAM_API_ID` and `TELEGRAM_API_HASH` in your environment, then run:

```sh
python3 tool/telegram-build-config.py --output auralis-telegram-build.json
flutter build apk --release --dart-define-from-file=auralis-telegram-build.json
```

Use `flutter build windows --release` with the same define argument on Windows.
The generated filename is ignored by Git. Delete it when finished; do not upload
it or commit actual API credentials. The app still protects saved credentials
with Android Keystore or Windows DPAPI and does not save login codes or two-step
passwords. No Telegram login, Flutter compilation or device installation was
verified in this workspace.

## Country selection and number corrections

The sign-in phone step includes a searchable country/calling-code picker using
TDLib's `getCountries` data, including countries that share a calling code.
Users can instead paste a full international number; the selected prefix is not
added a second time. If the country list is unavailable, its dialog offers Retry
and the full-number fallback still works. Enter a national number exactly as it
appears after the international calling code; no global leading-zero removal is
applied because some countries retain that digit.

The verification-code step shows the phone number reported by Telegram and a
Change number action. Users can edit country and number, cancel without requesting
another code, or choose Send new code. This uses `setAuthenticationPhoneNumber`
in the existing waiting-for-code session rather than logging out or creating a
new database. The old OTP is cleared; Telegram errors leave the correction
editable for retry. The displayed phone number is held in memory for login and
is cleared after authorization, logout or shutdown; it is not added to the app
credential/settings export. Codes and passwords are not saved.
