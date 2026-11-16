# ProjectM Add on Presets 2.0

The catalogue in `assets/visualizer/projectm` comes from the supplied
**ProjectM Add on Presets 2.0 compiled by Monsieurtalbot MEGA .zip**. Preset
names retain their author credits. See [the original readme](original-readme.txt)
for the compilation notes. The supplied archive's SHA-256 is
`49e4b65334de758858c99cc21a9a791d7cb3c49ab62e5ec93030028ab1e1def7`.

The converter removes identical sources, render-equivalent presets, names
already bundled with Butterchurn, and presets that cannot be converted for
this renderer. The import report lists the omitted entries and reasons. The
app reads the name catalogue on first use and loads only the page containing
the requested preset. All renderer assets are available offline.

To regenerate the assets from the original ZIP, use the pinned MIT-licensed
conversion packages as build tools. The app does not include those tools in
its runtime. Keep the existing import report when rebuilding this archive so
its renderer exclusions are reused.

```sh
npm install --prefix /tmp/auralis-projectm --ignore-scripts \
  milkdrop-preset-utils@0.2.1 milkdrop-eel-parser@0.0.4 hlslparser-js@0.1.1
NODE_PATH=/tmp/auralis-projectm/node_modules node tool/convert-projectm-presets.cjs \
  /path/to/original.zip assets/visualizer/projectm \
  third_party/visualizer/projectm/import-report.json
```
