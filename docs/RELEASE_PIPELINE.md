# Build, publish, cleanup and update notes

Auralis 0.1.64 adapts the Yutaka pipeline to Android and Windows.

1. **Android APK build** (`android.yml`) analyzes/tests the app, checks the sync
   service and release policy, builds the APK and saves its artifacts.
2. **Windows x64 build** (`windows.yml`) independently checks/builds Windows and
   creates the ZIP, custom EXE installer, source and checksums. Existing native
   caches, signing setup, installer checks and streaming smoke checks are retained.
3. **Publish Auralis release** (`publish-release.yml`) runs after either build.
   It waits until both Android arm64 and Windows have successful artifacts for
   the exact same `main` commit. Fork and pull-request artifacts cannot publish.
   It downloads those build artifacts, verifies them with the existing publishers,
   uploads Android to the draft, then verifies Windows and publishes the release.
   A receipt records the exact consumed build-run IDs only after publication.
4. **Clean completed Auralis runs** (`cleanup-runs.yml`) removes completed green
   publisher/deployment/signing/older-cleanup runs. Successful `main` build runs
   are kept until a publication receipt proves their artifacts were consumed.
   Successful feature/PR/tag builds do not wait for publication. Active runs,
   cancellations and the currently executing cleanup run are retained.
5. Failed/timed-out runs become eligible **ten minutes after completion**. Cleanup
   runs on workflow completion and on a five-minute schedule. GitHub scheduling
   and queues can delay deletion beyond ten minutes; it is not an exact timer.

Use a fresh app version for app changes and push the complete project to `main`.
A tag-only build is an artifact build; automatic publication waits for matching
trusted `main` builds. Manual **Publish Auralis release** retries matching builds
for its selected main revision. A build that fails checks produces no release.
Published releases and tags are not overwritten; matching drafts can be resumed.
Existing retained Android signing remains required for seamless APK upgrades.
Without a retained key, the existing explicitly labeled development-release APK
path remains available; changing signing keys cannot preserve an installed app.

No workflow or release has been run or modified on GitHub from this workspace.
Add the source to your repository and run the new workflows on that commit.

## Release notes

Write changes under `## <version>` at the top of `CHANGELOG.md`, bump `pubspec.yaml`,
then run:

```sh
python3 tool/release-notes.py --write
```

This generates `assets/release-notes.json`. Both builds check that it exactly
matches the changelog and current version. The publisher extracts the same current
changes into the GitHub release body. In the app, **Settings → What’s new** shows
the installed version's changes; the first launch after an upgrade shows them
once. An available-update banner and **What changed** show the verified GitHub
release's notes, bounded to 12,000 characters.

Automatic checks are on by default: startup, at most every five minutes on resume,
and every thirty minutes while running. Android retains automatic verified
APK download; both platforms require the user to confirm installation. Turning
automatic updates off stops those automatic checks. GitHub API/network errors
remain visible; no release check uses Telegram credentials.

## Local verification

```sh
node --test cloud/worker/worker.test.mjs tool/release-policy.test.cjs
python3 -m unittest discover -s tool -p 'test_android*.py'
python3 tool/release-notes.py
flutter analyze --no-pub --fatal-infos
flutter test --no-pub --reporter expanded
```

Node service/policy and Python tooling checks can run without Flutter. Native
builds, actual GitHub publishing/cleanup and device installations require their
respective runners and accounts.

Completed successful builds for an abandoned commit are also eligible after a paired failure has been completed for ten minutes, provided no paired build retry is active in the cleanup snapshot. Active runs are never deleted.

Optional Android x64 artifacts from the same tested commit are also attached when available. Publication receipts include their run IDs. Older public releases predating 0.1.64 provide legacy cleanup proof through their stable tag and both platform assets; newer builds require exact run receipts.
