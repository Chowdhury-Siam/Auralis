#!/usr/bin/env python3
"""Append verified Android assets; Windows remains the shared release publisher."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile


def gh(*args):
    result = subprocess.run(["gh", *args], check=True, capture_output=True, text=True)
    if args[0] == "api" or args[:2] == ("release", "view"):
        return json.loads(result.stdout)


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def publish(root, env):
    root = Path(root)
    repo = env.get("GITHUB_REPOSITORY", "")
    commit = env.get("GITHUB_SHA", "")
    ref_type, ref = env.get("GITHUB_REF_TYPE"), env.get("GITHUB_REF_NAME")
    if (env.get("GITHUB_EVENT_NAME") not in ("push", "workflow_dispatch") or
            not (ref_type == "tag" or (ref_type == "branch" and ref == "main"))):
        raise ValueError("Only main and stable version tags can publish Android assets.")
    if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("Invalid repository.")
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or git(root, "rev-parse", "HEAD") != commit:
        raise ValueError("The checkout must match the tested GitHub commit.")
    match = re.search(r"^version:\s*((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\+\d+\s*$",
                      (root / "pubspec.yaml").read_text(), re.MULTILINE)
    if not match:
        raise ValueError("A stable pubspec version is required.")
    version, abi = match[1], env.get("ABI")
    tag = "v" + version
    if ref_type == "tag" and ref != tag:
        raise ValueError("The triggering tag must match pubspec.yaml.")
    signed = env.get("SIGNED", "false")
    if signed not in ("true", "false") or abi not in ("arm64-v8a", "x86_64"):
        raise ValueError("A valid signing state and supported Android ABI are required.")
    mode = "release" if signed == "true" else "debug"
    suffix = "" if mode == "release" else "-debug"

    dist = root / "dist/android"
    apk = dist / f"auralis-{version}-android-{abi}-{mode}.apk"
    checksum = f"{digest(apk)}  {apk.name}"
    if checksum not in (dist / "SHA256SUMS.txt").read_text().splitlines():
        raise ValueError("The APK does not match its verified build checksum.")
    provenance = dist / f"auralis-{version}-android-{abi}{suffix}-provenance.zip"
    notices = [dist / name for name in ("build-manifest.json", "THIRD_PARTY_NOTICES.md", "ANDROID.md")]
    licenses = sorted(path for path in (dist / "licenses").rglob("*") if path.is_file())
    if not licenses or not all(path.is_file() for path in notices):
        raise ValueError("Android native provenance and license notices are required.")
    with zipfile.ZipFile(provenance, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in notices + licenses:
            entry = zipfile.ZipInfo(path.relative_to(dist).as_posix())
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, path.read_bytes())
    sums = dist / f"SHA256SUMS-android-{abi}{suffix}.txt"
    sums.write_text("".join(f"{digest(path)}  {path.name}\n" for path in (apk, provenance)))
    files = [apk, provenance, sums]

    pages = gh("api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100")
    releases = [release for page in pages for release in page if release["tag_name"] == tag]
    if len(releases) > 1 or (releases and releases[0]["prerelease"]):
        raise ValueError("Expected one stable release or draft for this version.")
    existing = releases[0] if releases else None
    # Same-version reruns preserve the already published Android downloads.
    if existing and not existing["draft"]:
        names = [asset["name"] for asset in existing.get("assets", [])]
        if all(names.count(path.name) == 1 for path in files):
            print(f"{tag}: Android {abi} assets already published; preserving them.")
            return

    refs = gh("api", f"repos/{repo}/git/matching-refs/tags/{tag}")
    refs = [item for item in refs if item["ref"] == f"refs/tags/{tag}"]
    if refs:
        tagged = gh("api", f"repos/{repo}/commits/{tag}")["sha"]
        if not re.fullmatch(r"[0-9a-f]{40}", tagged):
            raise ValueError("Invalid release tag commit.")
        if tagged != commit:
            try:
                git(root, "cat-file", "-e", tagged + "^{commit}")
            except subprocess.CalledProcessError:
                git(root, "fetch", "--no-tags", "--depth=1", "origin", tagged)
            # CI-only fixes may complete an existing version; app changes
            # require a new version and must never reuse another app's tag.
            git(root, "diff", "--exit-code", tagged, "HEAD", "--", "lib", "android",
                "assets", "third_party", "pubspec.yaml", "pubspec.lock",
                "tool/build-tdlib-android.sh", "THIRD_PARTY_NOTICES.md", "LICENSE")
    elif existing or ref_type == "tag":
        raise ValueError("The release tag is missing; no assets were changed.")
    else:
        gh("api", "--method", "POST", f"repos/{repo}/git/refs",
           "-f", f"ref=refs/tags/{tag}", "-f", f"sha={commit}")
    if not existing:
        gh("release", "create", tag, "--repo", repo, "--verify-tag", "--draft",
           "--prerelease=false", "--title", f"Auralis {version}", "--generate-notes")
    release_id = gh("release", "view", tag, "--repo", repo, "--json", "databaseId")["databaseId"]
    if type(release_id) is not int or release_id < 1:
        raise ValueError("GitHub returned an invalid release ID.")
    endpoint = f"repos/{repo}/releases/{release_id}"

    def metadata():
        release = gh("api", endpoint)
        if release["tag_name"] != tag or release["prerelease"] or type(release["draft"]) is not bool:
            raise ValueError("Release metadata changed; no further assets will be uploaded.")
        return release

    release = metadata()
    uploads = []
    replace_draft = False
    for path in files:
        assets = [asset for asset in release["assets"] if asset["name"] == path.name]
        if not assets:
            uploads.append(str(path))
        elif len(assets) != 1:
            raise ValueError(f"Duplicate release asset: {path.name}. No assets were changed.")
        elif (assets[0].get("digest") != "sha256:" + digest(path) or
              assets[0].get("size") != path.stat().st_size):
            if not release["draft"]:
                raise ValueError(f"Existing asset differs: {path.name}. Published files are never replaced. "
                                 "Bump pubspec.yaml and push the new version to main.")
            uploads.append(str(path))
            replace_draft = True
    if uploads:
        # Both platform publishers share one workflow concurrency group. Check
        # again immediately before any destructive draft-only replacement.
        current = metadata()
        if replace_draft and not current["draft"]:
            raise ValueError("Release was published before draft refresh. No assets were replaced; "
                             "bump pubspec.yaml for a new release.")
        gh("release", "upload", tag, *uploads, "--repo", repo,
           *(["--clobber"] if replace_draft else []))
    release = metadata()
    for path in files:
        assets = [asset for asset in release["assets"] if asset["name"] == path.name]
        if (len(assets) != 1 or assets[0].get("digest") != "sha256:" + digest(path) or
                assets[0].get("size") != path.stat().st_size):
            raise ValueError(f"GitHub digest/size mismatch for {path.name}.")
    print(f"{tag}: Android {abi} assets verified. " +
          ("The Windows publisher will publish the shared draft." if release["draft"]
           else "Added to the existing stable release."))


if __name__ == "__main__":
    publish(Path(__file__).resolve().parents[1], os.environ)
