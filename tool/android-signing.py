#!/usr/bin/env python3
"""Prepare a saved signing identity without printing credentials."""
import base64
import json
import os
from pathlib import Path
import subprocess


def configure(directory, environment):
    names = ("KEYSTORE", "STORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD")
    values = [environment.get(name, "") for name in names]
    identity = environment.get("SIGNING_IDENTITY", "")
    if identity and not any(values):
        try:
            bundle = json.loads(identity)
            if set(bundle) != set(names) or not all(isinstance(bundle[name], str) and bundle[name] for name in names):
                raise ValueError()
            values = [bundle[name] for name in names]
        except (ValueError, TypeError):
            raise ValueError("Invalid ANDROID_SIGNING_IDENTITY secret. Do not replace an existing signing key.") from None
    if not any(values):
        return False
    if not all(values):
        raise ValueError("Set all four Android signing secrets, or leave all unset.")
    if environment.get("GITHUB_ACTIONS") == "true":
        for value in (values[0], values[1], values[3]):
            print("::add-mask::" + value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A"))
    blob = base64.b64decode(values[0], validate=True)
    if not 32 <= len(blob) <= 10 * 1024 * 1024:
        raise ValueError("Invalid keystore size.")
    key = directory / "auralis-release.jks"
    props = directory / "key.properties"
    try:
        with key.open("xb") as stream:
            os.chmod(key, 0o600)
            stream.write(blob)
        subprocess.run(["keytool", "-list", "-keystore", str(key), "-alias", values[2],
                        "-storepass:env", "STORE_PASSWORD"],
                       env=dict(os.environ, STORE_PASSWORD=values[1]),
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def escaped(value):
            return value.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t").replace(" ", "\\ ")
        with props.open("x") as stream:
            os.chmod(props, 0o600)
            stream.write("storeFile=auralis-release.jks\n")
            for name, value in zip(("storePassword", "keyAlias", "keyPassword"), values[1:]):
                stream.write(f"{name}={escaped(value)}\n")
        return True
    except Exception:
        key.unlink(missing_ok=True)
        props.unlink(missing_ok=True)
        raise ValueError("Could not configure release signing; check the keystore, alias and passwords.") from None


if __name__ == "__main__":
    signed = configure(Path(__file__).resolve().parents[1] / "android", os.environ)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"signed={str(signed).lower()}\n")
    print("Saved release signing configured." if signed else "No saved key: release-mode APK will use a temporary development signature. Run Set up Android signing for automatic upgrade signing.")
