#!/usr/bin/env python3
"""Verify bundled visualizer distributions and retained sources, offline."""
import base64
import hashlib
import json
from pathlib import Path
import tarfile

root = Path(__file__).resolve().parents[1]
sources = root / "third_party/visualizer"
assets = root / "assets/visualizer"
members = {
    "audiomotion-analyzer": ("dist/index.js", "audiomotion", "src/audioMotion-analyzer.js"),
    "butterchurn": ("lib/butterchurn.min.js", "butterchurn", "src/visualizer.js"),
    "butterchurn-presets": ("lib/butterchurnPresets.min.js", "presets", "config/webpack.config.js"),
}
for record in json.loads((sources / "provenance.json").read_text()):
    directory = sources / record["name"]
    source, package = directory / "upstream-source.tar.gz", directory / "npm-package.tgz"
    assert hashlib.sha256(source.read_bytes()).hexdigest() == record["sourceSha256"]
    package_bytes = package.read_bytes()
    assert hashlib.sha256(package_bytes).hexdigest() == record["packageSha256"]
    algorithm, expected = record["npmIntegrity"].split("-", 1)
    assert base64.b64encode(hashlib.new(algorithm, package_bytes).digest()).decode() == expected
    member, asset, readable = members[record["name"]]
    with tarfile.open(package, "r:gz") as archive:
        assert archive.extractfile("package/" + member).read() == (assets / (asset + ".js")).read_bytes()
        assert archive.extractfile("package/LICENSE").read() == (assets / ("LICENSE-" + asset + ".txt")).read_bytes()
    with tarfile.open(source, "r:gz") as archive:
        names = archive.getnames()
        assert any(name.endswith("/" + readable) for name in names), readable
        assert any(name.endswith("/package.json") for name in names)
        assert any(name.endswith("/LICENSE") for name in names)
    print(record["name"], record["version"], "source, package, assets and license verified")
