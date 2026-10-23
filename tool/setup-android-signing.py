#!/usr/bin/env python3
"""Generate a signing identity once and store it atomically in GitHub Secrets."""
import base64
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile


IDENTITY = "ANDROID_SIGNING_IDENTITY"
LEGACY = {"ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD",
          "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD"}


def github(environment, *arguments, value=None):
    result = subprocess.run(
        ["gh", *arguments], input=value, text=True, capture_output=True,
        env=dict(os.environ, **environment),
    )
    if result.returncode:
        raise ValueError("GitHub secret access failed. Check ANDROID_SIGNING_SETUP_TOKEN has repository Secrets read/write permission.")
    return result.stdout


def setup(environment):
    if environment.get("GITHUB_EVENT_NAME") != "workflow_dispatch" or environment.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Signing setup must be run manually from main.")
    repo = environment.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("Invalid repository.")
    if not environment.get("GH_TOKEN"):
        raise ValueError("Add ANDROID_SIGNING_SETUP_TOKEN once with repository Secrets read/write permission, then run this action again.")

    def existing():
        return {item["name"] for item in json.loads(github(
            environment, "secret", "list", "--repo", repo, "--json", "name",
        ))}

    names = existing()
    legacy = names & LEGACY
    if legacy and legacy != LEGACY:
        raise ValueError("Existing Android signing secrets are incomplete. Restore that key's missing secrets; setup will not replace it.")
    if IDENTITY in names or legacy == LEGACY:
        print("Existing Android signing identity preserved. No key was generated or replaced.")
        return False

    # The workflow serializes setup runs. The private key never enters caches,
    # artifacts, logs, job outputs or version control.
    with tempfile.TemporaryDirectory(prefix="auralis-signing-") as temporary:
        key = Path(temporary) / "release.jks"
        password = secrets.token_urlsafe(48)
        subprocess.run([
            "keytool", "-genkeypair", "-keystore", str(key), "-storetype", "PKCS12",
            "-alias", "auralis", "-keyalg", "RSA", "-keysize", "4096", "-validity", "10000",
            "-dname", "CN=Auralis Android Release", "-storepass:env", "SIGNING_PASSWORD",
            "-keypass:env", "SIGNING_PASSWORD", "-noprompt",
        ], env=dict(os.environ, SIGNING_PASSWORD=password), check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(key, 0o600)
        encoded = base64.b64encode(key.read_bytes()).decode()
        if environment.get("GITHUB_ACTIONS") == "true":
            for value in (password, encoded):
                print("::add-mask::" + value)
        identity = json.dumps(dict(KEYSTORE=encoded, STORE_PASSWORD=password,
                                   KEY_ALIAS="auralis", KEY_PASSWORD=password))
        if existing() & (LEGACY | {IDENTITY}):
            raise ValueError("Signing secrets appeared during setup. No existing key was replaced; rerun this action.")
        github(environment, "secret", "set", IDENTITY, "--repo", repo, value=identity)
    print("Android signing identity saved securely. Future builds will reuse it automatically.")
    return True


if __name__ == "__main__":
    try:
        setup(dict(os.environ))
    except (ValueError, subprocess.CalledProcessError) as error:
        # Native diagnostics and GitHub responses may contain private material.
        raise SystemExit(str(error) if isinstance(error, ValueError) else "Signing key generation failed.") from None
