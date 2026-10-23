"""Exercise the real publisher with local Git and a process-local GitHub stand-in."""
import copy
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


spec = importlib.util.spec_from_file_location("android_publisher", Path(__file__).with_name("publish-android.py"))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class GitHub:
    def __init__(self, commit):
        self.tag = commit
        self.release = dict(id=101, tag_name="v0.9.0", draft=False, prerelease=False,
                            assets=[dict(name="windows-setup.exe", digest="sha256:" + "a" * 64, size=12)])
        self.calls = []
        self.bad_digest = False
        self.uploaded = False
        self.release_reads = 0
        self.publish_on_read = None

    def __call__(self, *args):
        self.calls.append(args)
        if args[0] == "api":
            endpoint = next(arg for arg in args if arg.startswith("repos/"))
            if endpoint.endswith("releases?per_page=100"):
                return [[], [copy.deepcopy(self.release)] if self.release else []]
            if "/git/matching-refs/" in endpoint:
                return [dict(ref="refs/tags/v0.9.0")] if self.tag else []
            if "/commits/" in endpoint:
                return {"sha": self.tag}
            if endpoint.endswith("/git/refs"):
                self.tag = next(arg[4:] for arg in args if arg.startswith("sha="))
                return {}
            if endpoint.endswith("/releases/101"):
                self.release_reads += 1
                if self.release_reads == self.publish_on_read:
                    self.release["draft"] = False
                result = copy.deepcopy(self.release)
                if self.bad_digest and self.uploaded:
                    result["assets"][-1]["digest"] = "sha256:" + "0" * 64
                return result
        if args[:2] == ("release", "create"):
            self.release = dict(id=101, tag_name=args[2], draft=True, prerelease=False, assets=[])
            return
        if args[:2] == ("release", "view"):
            return {"databaseId": self.release["id"]}
        if args[:2] == ("release", "upload"):
            self.uploaded = True
            for name in args[3:args.index("--repo")]:
                path = Path(name)
                matches = [asset for asset in self.release["assets"] if asset["name"] == path.name]
                if matches and "--clobber" not in args:
                    raise RuntimeError("fixture: asset already exists")
                if "--clobber" in args:
                    self.release["assets"] = [asset for asset in self.release["assets"]
                                              if asset["name"] != path.name]
                self.release["assets"].append(dict(name=path.name, digest="sha256:" + publisher.digest(path),
                                                   size=path.stat().st_size))
            return
        raise AssertionError(f"Unexpected GitHub command: {args}")


class AndroidPublishTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="auralis android release ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name, content in {
            "pubspec.yaml": "name: fixture\nversion: 0.9.0+1\n",
            "pubspec.lock": "fixture lock\n",
            "lib/main.dart": "void main() {}\n",
            "tool/build-tdlib-android.sh": "# Fixture only\n",
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        publisher.git(self.root, "init")
        publisher.git(self.root, "add", ".")
        self.commit()
        self.env = dict(GITHUB_EVENT_NAME="push", GITHUB_REF_TYPE="branch", GITHUB_REF_NAME="main",
                        GITHUB_REPOSITORY="fixture/auralis", GITHUB_SHA=publisher.git(self.root, "rev-parse", "HEAD"),
                        ABI="arm64-v8a", SIGNED="true")
        self.github = GitHub(self.env["GITHUB_SHA"])
        self.dist = self.root / "dist/android"
        (self.dist / "licenses").mkdir(parents=True)
        for name in ("build-manifest.json", "THIRD_PARTY_NOTICES.md", "ANDROID.md", "licenses/native.txt"):
            (self.dist / name).write_text("Original harmless fixture\n")
        self.apk = self.dist / "auralis-0.9.0-android-arm64-v8a-release.apk"
        self.apk.write_bytes(b"Harmless APK fixture; never installed or executed.")
        self.checksum()

    def commit(self):
        publisher.git(self.root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                      "-c", "commit.gpgsign=false", "commit", "-m", "Fixture")

    def checksum(self):
        (self.dist / "SHA256SUMS.txt").write_text(f"{publisher.digest(self.apk)}  {self.apk.name}\n")

    def run_publish(self, **overrides):
        with patch.object(publisher, "gh", self.github):
            publisher.publish(self.root, dict(self.env, **overrides))

    def mutations(self):
        return [args for args in self.github.calls if args[0] == "release" and args[1] != "view"
                or "POST" in args]

    def test_attaches_to_existing_windows_release_without_replacing_any_asset(self):
        windows = copy.deepcopy(self.github.release["assets"])
        self.run_publish()
        self.assertEqual(self.github.release["assets"][:1], windows)
        self.assertFalse(self.github.release["draft"])
        self.assertEqual([args[:2] for args in self.mutations()], [("release", "upload")])
        self.assertFalse(any("--clobber" in args for args in self.github.calls))
        self.assertEqual(len(self.github.release["assets"]), 4)
        provenance = self.dist / "auralis-0.9.0-android-arm64-v8a-provenance.zip"
        with zipfile.ZipFile(provenance) as archive:
            self.assertIsNone(archive.testzip())
            self.assertIn("licenses/native.txt", archive.namelist())
        self.assertIn(self.apk.name, (self.dist / "SHA256SUMS-android-arm64-v8a.txt").read_text())

    def test_android_first_creates_verified_draft_for_existing_windows_publisher(self):
        self.github.release = None
        self.github.tag = None
        self.run_publish()
        self.assertEqual(self.github.tag, self.env["GITHUB_SHA"])
        self.assertTrue(self.github.release["draft"])
        self.assertEqual(len(self.github.release["assets"]), 3)
        self.assertTrue(any(args[:2] == ("release", "create") for args in self.github.calls))
        self.assertFalse(any(args[:2] == ("release", "edit") for args in self.github.calls))

    def test_existing_draft_accepts_android_before_windows_uploads(self):
        self.github.release["draft"] = True
        self.run_publish()
        self.assertTrue(self.github.release["draft"])
        self.assertEqual([args[:2] for args in self.mutations()], [("release", "upload")])

    def test_rebuilt_development_apk_refreshes_only_owned_assets_in_unpublished_draft(self):
        self.development_artifact()
        self.github.release["draft"] = True
        self.run_publish(SIGNED="false")
        windows = copy.deepcopy(self.github.release["assets"][:1])
        original_tag = self.github.tag
        self.github.calls.clear()
        self.apk.write_bytes(b"Another CI development signing key/build; harmless fixture")
        self.checksum()
        (self.dist / "build-manifest.json").write_text("Fresh native build provenance\n")
        self.run_publish(SIGNED="false")
        self.assertTrue(self.github.release["draft"])
        self.assertEqual(self.github.release["assets"][:1], windows)
        self.assertEqual(self.github.tag, original_tag)
        self.assertEqual(len(self.github.release["assets"]), 4)
        upload, = self.mutations()
        self.assertIn("--clobber", upload)
        self.assertEqual(len(upload[3:upload.index("--repo")]), 3)
        for path in self.dist.glob("*development*"):
            asset, = [a for a in self.github.release["assets"] if a["name"] == path.name]
            self.assertEqual(asset["digest"], "sha256:" + publisher.digest(path))
            self.assertEqual(asset["size"], path.stat().st_size)

    def test_partial_draft_refreshes_changed_apk_and_missing_checksums(self):
        self.github.release["draft"] = True
        self.run_publish()
        self.github.release["assets"].pop()
        self.github.calls.clear()
        self.apk.write_bytes(b"Rebuilt same app after an interrupted draft upload")
        self.checksum()
        self.run_publish()
        upload, = self.mutations()
        names = {Path(path).name for path in upload[3:upload.index("--repo")]}
        self.assertEqual(names, {self.apk.name, "SHA256SUMS-android-arm64-v8a.txt"})
        self.assertIn("--clobber", upload)
        self.assertTrue(self.github.release["draft"])
        self.assertEqual(len(self.github.release["assets"]), 4)

    def test_draft_published_before_refresh_never_clobbers_assets(self):
        self.github.release["draft"] = True
        self.run_publish()
        before = copy.deepcopy(self.github.release["assets"])
        self.github.calls.clear()
        self.github.release_reads = 0
        self.github.publish_on_read = 2
        self.apk.write_bytes(b"Rebuilt APK fixture")
        self.checksum()
        with self.assertRaisesRegex(ValueError, "published before draft refresh"):
            self.run_publish()
        self.assertEqual(self.github.release["assets"], before)
        self.assertEqual(self.mutations(), [])

    def test_duplicate_draft_assets_are_rejected_without_mutation(self):
        self.github.release["draft"] = True
        self.run_publish()
        self.github.release["assets"].append(copy.deepcopy(self.github.release["assets"][1]))
        self.github.calls.clear()
        with self.assertRaisesRegex(ValueError, "Duplicate release asset"):
            self.run_publish()
        self.assertEqual(self.mutations(), [])

    def test_completed_android_release_is_immutable_on_rerun(self):
        self.run_publish()
        before = copy.deepcopy(self.github.release)
        self.github.calls.clear()
        self.apk.write_bytes(b"Another build of the same app, never executed")
        self.checksum()
        self.run_publish()
        self.assertEqual(self.github.release, before)
        self.assertEqual(self.mutations(), [])

    def test_partial_upload_can_resume_with_identical_artifacts(self):
        self.run_publish()
        self.github.release["assets"].pop()
        self.github.calls.clear()
        self.run_publish()
        upload = next(args for args in self.mutations() if args[:2] == ("release", "upload"))
        self.assertEqual(len(upload[3:upload.index("--repo")]), 1)
        self.assertTrue(upload[3].endswith("SHA256SUMS-android-arm64-v8a.txt"))

    def test_different_existing_asset_is_never_clobbered(self):
        self.run_publish()
        self.github.release["assets"].pop()
        self.github.release["assets"][1]["digest"] = "sha256:" + "0" * 64
        self.github.calls.clear()
        with self.assertRaisesRegex(ValueError, "never replaced"):
            self.run_publish()
        self.assertEqual(self.mutations(), [])

    def test_ci_only_commit_can_fill_existing_tag_but_app_change_cannot(self):
        (self.root / "README.md").write_text("Publishing-only update\n")
        publisher.git(self.root, "add", "README.md")
        self.commit()
        self.env["GITHUB_SHA"] = publisher.git(self.root, "rev-parse", "HEAD")
        self.run_publish()
        self.github.release["assets"] = self.github.release["assets"][:1]
        self.github.calls.clear()
        (self.root / "lib/main.dart").write_text("void main() { print('different app'); }\n")
        publisher.git(self.root, "add", "lib/main.dart")
        self.commit()
        self.env["GITHUB_SHA"] = publisher.git(self.root, "rev-parse", "HEAD")
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_publish()
        self.assertEqual(self.mutations(), [])

    def test_untrusted_refs_invalid_signing_state_and_wrong_version_never_contact_github(self):
        for env in (dict(GITHUB_EVENT_NAME="pull_request"), dict(GITHUB_REF_NAME="feature"),
                    dict(SIGNED="invalid"), dict(ABI="armeabi-v7a"),
                    dict(GITHUB_REF_TYPE="tag", GITHUB_REF_NAME="v0.9.1"),
                    dict(GITHUB_REPOSITORY="bad/repo/extra"), dict(GITHUB_SHA="0" * 40)):
            with self.subTest(env=env), self.assertRaises(ValueError):
                self.run_publish(**env)
        self.assertEqual(self.github.calls, [])

    def development_artifact(self):
        target = self.apk.with_name(self.apk.name.replace('-release.apk', '-development-release.apk'))
        self.apk.rename(target)
        self.apk = target
        self.checksum()

    def test_development_apk_is_published_without_custom_signing(self):
        self.development_artifact()
        self.run_publish(SIGNED="false")
        names = {asset['name'] for asset in self.github.release['assets']}
        self.assertIn(self.apk.name, names)
        self.assertIn('SHA256SUMS-android-arm64-v8a-development.txt', names)
        self.assertIn('auralis-0.9.0-android-arm64-v8a-development-provenance.zip', names)
        self.assertNotIn('auralis-0.9.0-android-arm64-v8a-release.apk', names)

    def test_absent_signing_state_defaults_to_development(self):
        self.development_artifact()
        self.env.pop('SIGNED')
        self.run_publish()
        self.assertIn(self.apk.name, {asset['name'] for asset in self.github.release['assets']})

    def test_development_and_release_assets_coexist_without_replacing_each_other(self):
        self.run_publish()
        before = copy.deepcopy(self.github.release['assets'])
        self.development_artifact()
        self.run_publish(SIGNED="false")
        self.assertEqual(self.github.release['assets'][:len(before)], before)
        self.assertEqual(len(self.github.release['assets']), 7)

    def test_tampered_artifact_and_missing_licenses_never_contact_github(self):
        self.apk.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.run_publish()
        self.checksum()
        (self.dist / "licenses/native.txt").unlink()
        with self.assertRaisesRegex(ValueError, "license"):
            self.run_publish()
        self.assertEqual(self.github.calls, [])

    def test_digest_mismatch_does_not_publish_draft(self):
        self.github.release["draft"] = True
        self.github.bad_digest = True
        with self.assertRaisesRegex(ValueError, "digest/size mismatch"):
            self.run_publish()
        self.assertTrue(self.github.release["draft"])
        self.assertFalse(any(args[:2] == ("release", "edit") for args in self.github.calls))

    def test_prerelease_or_invalid_release_id_cannot_upload(self):
        self.github.release["prerelease"] = True
        with self.assertRaises(ValueError):
            self.run_publish()
        self.github.release["prerelease"] = False
        self.github.release["id"] = "invalid/id"
        with self.assertRaisesRegex(ValueError, "release ID"):
            self.run_publish()
        self.assertEqual(self.mutations(), [])

    def test_api_failure_never_mutates_release(self):
        with patch.object(publisher, "gh", side_effect=RuntimeError("fixture permission failure")):
            with self.assertRaisesRegex(RuntimeError, "permission failure"):
                publisher.publish(self.root, self.env)
        self.assertEqual(self.mutations(), [])


if __name__ == "__main__":
    unittest.main()
