# Offline visualizer provenance and source

Auralis bundles unmodified browser distributions from:

| Package | Version | Terms | Source revision |
|---|---|---|---|
| audioMotion-analyzer | 4.5.4 | AGPL-3.0-or-later | `bd226d1331316319583b9a56207b86c6f3c8fea5` |
| Butterchurn | 2.6.7 | MIT | `d90f271be02969d8f16a3ed6b6960c971da6eff9` |
| butterchurn-presets | 2.4.7 | MIT | `d19bf03f8930e391a98cc502342ab7658a33af3c` |

Each directory contains the complete exact-commit upstream source snapshot
(`upstream-source.tar.gz`), published npm archive (`npm-package.tgz`) and npm
metadata. `provenance.json` records download URLs, source/package SHA-256 and npm
SRI integrity. All npm archives were checked against that SRI at retrieval.
Source archives include readable source, copyright/license texts and upstream
build configuration, not just minified output. They are not Flutter assets and
are not shipped into the application.

## Extract, inspect or rebuild

Extract each `upstream-source.tar.gz` into its own development directory:

```sh
tar -xzf upstream-source.tar.gz
```

For audioMotion, use its `src/audioMotion-analyzer.js`,
`babel.config.json` and `package.json`. Its Unix-shell `npm run build` installs
the Babel UMD wrapper and applies the upstream default-export fix. Run
`npm install --ignore-scripts` followed by `npm run build` in the extracted
project. The upstream snapshot has no dependency lockfile; fresh Babel versions
can change generated formatting. The exact npm archive retains the delivered
source and generated distribution as published.

For Butterchurn and presets, the snapshots contain `src/` (or preset JSON),
`config/webpack.config.js`, `package.json` and `yarn.lock`. Use Yarn Classic,
`yarn install --frozen-lockfile --ignore-scripts`, then `yarn build`.
These historical Webpack versions can require an older compatible Node.js
toolchain or `NODE_OPTIONS=--openssl-legacy-provider` on newer Node.js.
Build tools are development-only and are never loaded by Auralis.
Rebuilding the upstream JavaScript toolchains was not verified in this delivery.

## Exact bundled files

The following package members are copied unchanged:

- `butterchurn`: `package/lib/butterchurn.min.js` -> `assets/visualizer/butterchurn.js`
- `butterchurn-presets`: `package/lib/butterchurnPresets.min.js` -> `assets/visualizer/presets.js`
- `audiomotion-analyzer`: `package/dist/index.js` -> `assets/visualizer/audiomotion.js`
- Each package's `LICENSE` -> the respective `assets/visualizer/LICENSE-*.txt`

Run `python tool/verify-visualizer-sources.py` to verify all retained hashes,
source members, asset byte equality and license texts without network access.
Run `node tool/verify-visualizer.mjs` for waveform/FFT/renderer bridge checks.

The runtime includes the original built-in preset pack and the converted
[ProjectM add-on catalogue](projectm/README.md). Other upstream Butterchurn
packs are retained in the source and package archives. Preserve upstream preset
authorship. Auralis's original offline HTML/bridge, Dart integration and native
output-analysis bridges are covered by Auralis's AGPL-3.0-or-later license.
The renderer performs no network requests and receives no media URLs or secrets.

When distributing app binaries, provide this source bundle together with the
complete matching Auralis source and notices. Existing native playback
corresponding-source/audit limitations remain documented in
`THIRD_PARTY_NOTICES.md`; these JavaScript snapshots do not resolve them.
