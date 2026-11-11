#!/usr/bin/env python3
"""Reject incomplete/wrong-ABI APKs and native libraries incompatible with 16 KiB pages."""
import re
import struct
import sys
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile


def verify_elf(data, abi):
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("Expected a little-endian 64-bit ELF library.")
    machine = struct.unpack_from("<H", data, 18)[0]
    if machine != {"arm64-v8a": 183, "x86_64": 62}[abi]:
        raise ValueError("Native library belongs to a different ABI.")
    offset = struct.unpack_from("<Q", data, 32)[0]
    entry, count = struct.unpack_from("<HH", data, 54)
    if entry < 56 or not 1 <= count <= 1000 or offset + entry * count > len(data):
        raise ValueError("Invalid ELF program headers.")
    loads = 0
    for i in range(count):
        header = struct.unpack_from("<IIQQQQQQ", data, offset + i * entry)
        if header[0] == 1:
            loads += 1
            if header[7] < 16384 or header[2] % 16384 != header[3] % 16384:
                raise ValueError("Native library does not support 16 KiB load alignment.")
    if not loads:
        raise ValueError("Native library has no loadable segments.")


def verify_apk(path, abi):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("Damaged APK.")
        names = set(archive.namelist())
        for name in ("AndroidManifest.xml", "classes.dex", f"lib/{abi}/libtdjson.so",
                     f"lib/{abi}/libmpv.so", f"lib/{abi}/libmediakitandroidhelper.so", f"lib/{abi}/libflutter.so"):
            if name not in names:
                raise ValueError(f"APK is missing {name}")
        for name in names:
            if name.startswith("lib/") and name.endswith(".so"):
                if name.split("/")[1] != abi:
                    raise ValueError("Unexpected ABI in the APK.")
                verify_elf(archive.read(name), abi)
        td = archive.read(f"lib/{abi}/libtdjson.so")
        for symbol in (b"td_create_client_id", b"td_send", b"td_receive", b"td_execute"):
            if symbol not in td:
                raise ValueError("TDLib JSON exports are missing.")


def verify_source(root):
    android = root / "android"
    wrapper = (android / "gradle/wrapper/gradle-wrapper.properties").read_text()
    version = re.search(r"distributionUrl=.*gradle-(\d+)\.(\d+)(?:\.(\d+))?-bin\.zip", wrapper)
    assert version, "A pinned Gradle binary distribution is required."
    # Flutter 3.47.1 rejects Gradle below 8.14 before applying the app plugin.
    assert tuple(int(v or 0) for v in version.groups()) >= (8, 14, 0), "Flutter 3.47.1 requires Gradle 8.14 or newer."
    assert re.search(r"(?m)^distributionSha256Sum=[a-f0-9]{64}$", wrapper), "Gradle distribution checksum is required."
    manifest = ET.parse(android / "app/src/main/AndroidManifest.xml").getroot()
    ns = "{http://schemas.android.com/apk/res/android}"
    permissions = {node.get(ns + "name") for node in manifest.findall("uses-permission")}
    assert "android.permission.REQUEST_INSTALL_PACKAGES" in permissions
    build = (android / "app/build.gradle.kts").read_text()
    assert 'applicationId = "com.auralis.siam"' in build
    assert 'namespace = "com.auralis.siam"' in build
    provider = manifest.find("application/provider")
    assert provider is not None and provider.get(ns + "exported") == "false"
    assert provider.get(ns + "authorities") == "${applicationId}.updates"
    paths = ET.parse(android / "app/src/main/res/xml/update_paths.xml").getroot()
    assert [(node.tag, node.get("path")) for node in paths] == [("cache-path", "auralis-updates/")]
    assert "android.permission.INTERNET" in permissions
    assert "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" in permissions
    assert not any(p in permissions for p in ("android.permission.MANAGE_EXTERNAL_STORAGE", "android.permission.READ_EXTERNAL_STORAGE"))
    assert manifest.find("application").get(ns + "allowBackup") == "false"
    assert (android / "gradle/wrapper/gradle-wrapper.jar").stat().st_size > 1000
    for name in ("gradlew", "gradlew.bat", "app/src/main/kotlin/com/auralis/siam/MainActivity.kt",
                 "app/src/main/kotlin/com/auralis/siam/VaultCipher.kt",
                 "app/src/main/kotlin/com/auralis/siam/AndroidUpdateInstaller.kt"):
        assert (android / name).is_file(), name
    assert b"\r\n" not in (android / "gradlew").read_bytes()
    for name in ("key.properties", "auralis-release.jks"):
        assert not (android / name).exists(), f"Private/generated Android file: {name}"


if __name__ == "__main__":
    if sys.argv[1:] == ["--source-only"]:
        verify_source(Path(__file__).resolve().parents[1])
        print("Android source checks passed.")
    else:
        verify_apk(Path(sys.argv[1]), sys.argv[2])
        print("APK native ABI, JSON exports and 16 KiB ELF alignment checks passed.")
