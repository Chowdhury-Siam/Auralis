// Offline build tool. See third_party/visualizer/projectm/README.md for dependencies.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const inspectPreset = require('./visualizer-preset-quality.cjs');
const { execFileSync } = require('node:child_process');
const { Worker, isMainThread, parentPort } = require('node:worker_threads');
const { splitPreset, createBasePresetFuns, prepareShader, processUnOptimizedShader } =
  require('milkdrop-preset-utils');
const { convert_preset_wave_and_shape } = require('milkdrop-eel-parser');
const { convertHLSLShader } = require('hlslparser-js');

const root = path.resolve(__dirname, '..');
const pageSize = 32;
const conversionTimeoutMs = 12000;
const builtInTextures = new Set([
  'main', 'fw_main', 'fc_main', 'pw_main', 'pc_main', 'blur1', 'blur2', 'blur3',
  'noise_lq', 'noise_lq_lite', 'noise_mq', 'noise_hq', 'pw_noise_lq',
  'noisevol_lq', 'noisevol_hq', 'clouds2', 'empty',
]);

const extract = `
import hashlib, json, pathlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    for entry in archive.infolist():
        if entry.is_dir() or not entry.filename.lower().endswith('.milk'):
            continue
        raw = archive.read(entry)
        try:
            source = raw.decode('utf-8-sig')
        except UnicodeError:
            source = raw.decode('cp1252', errors='replace')
        print(json.dumps([pathlib.PurePosixPath(entry.filename).stem,
                          hashlib.sha256(raw).hexdigest(), source]))
`;

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

async function convertShader(shader) {
  if (!shader.trim()) return '';
  const name = 'main_shader_sentinel';
  const input = prepareShader(shader).replace('float4 shader_body (', `float4 ${name} (`);
  const output = processUnOptimizedShader(await convertHLSLShader(input,name,'fs'));
  if (!/\bshader_body\s*\{/.test(output) || /code generation failed/i.test(output))
    throw Error('Shader translation failed');
  for (const match of output.matchAll(/\bsampler_([a-zA-Z0-9_]+)/g)) {
    if (!builtInTextures.has(match[1])) throw Error('Unavailable texture');
  }
  return output.trim();
}

function checkEquations(preset) {
  for (const part of [preset, ...preset.shapes, ...preset.waves]) {
    for (const [field, code] of Object.entries(part)) {
      if (!field.endsWith('_eqs_str') || !code) continue;
      // Parse without running any preset-provided equations in the converter.
      part[field] = code.trimEnd() + '\n';
      new Function('a', part[field] + 'return a;');
    }
  }
}

async function convert(source) {
  if (!/^\s*\[preset00\]/mi.test(source)) throw Error('Missing preset header');
  const parts = splitPreset(source.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n'));
  if (!Object.keys(parts.baseVals).length &&
      !(parts.presetInit || parts.perFrame || parts.perVertex || parts.warp || parts.comp).trim())
    throw Error('Empty preset');
  const equations = convert_preset_wave_and_shape(
    parts.presetVersion, parts.presetInit, parts.perFrame, parts.perVertex, parts.shapes, parts.waves,
  );
  const preset = createBasePresetFuns(equations, parts.shapes, parts.waves);
  preset.baseVals = parts.baseVals;
  delete preset.baseVals.rating;
  checkEquations(preset);
  preset.warp = await convertShader(parts.warp);
  preset.comp = await convertShader(parts.comp);
  return preset;
}

function convertOnWorker(worker,source) {
  return new Promise(resolve => {
    function onExit() {
      finish({error:'Converter stopped',restart:true});
    }
    function finish(result) {
      clearTimeout(timer);
      worker.off('message',finish);
      worker.off('exit',onExit);
      resolve(result);
    }
    const timer=setTimeout(() => finish({error:'Conversion timed out',restart:true}),conversionTimeoutMs);
    worker.once('message',finish);
    worker.once('exit',onExit);
    worker.postMessage(source);
  });
}

async function main() {
  const [archive, destination, reportPath] = process.argv.slice(2);
  if (!archive || !destination || !reportPath)
    throw Error('Usage: node tool/convert-projectm-presets.cjs SOURCE.zip OUTPUT_DIRECTORY REPORT.json');
  const sourceHash = sha256(fs.readFileSync(archive));
  const rendererExclusions = new Map();
  if (fs.existsSync(reportPath)) {
    const prior = JSON.parse(fs.readFileSync(reportPath,'utf8'));
    if (prior.sourceHash === sourceHash) {
      for (const [name,reason] of prior.skipped) {
        if (['Butterchurn equation runtime failed','Renderer shader did not compile or link',
            'Invalid geometry across audio profiles'].includes(reason))
          rendererExclusions.set(name,reason);
      }
    }
  }
  const input = execFileSync('python3', ['-c', extract, archive], { maxBuffer: 128 * 1024 * 1024 });
  const entries = input.toString('utf8').trimEnd().split('\n').map(JSON.parse);
  const byContent = new Set(), byRenderedContent = new Set(), records = [], skipped = [];
  const builtIns = require(path.join(root, 'assets/visualizer/presets.js')).getPresets();
  const names = new Set(Object.keys(builtIns));
  const counts = {};
  const results = Array(entries.length), jobs = [];
  for (const [index,[name,key,source]] of entries.entries()) {
    if (byContent.has(key)) results[index]={error:'Identical source'};
    else if (names.has(name.trim())) results[index]={error:'Already bundled'};
    else if (rendererExclusions.has(name.trim().normalize('NFC')))
      results[index]={error:rendererExclusions.get(name.trim().normalize('NFC'))};
    else jobs.push([index,source]);
    byContent.add(key);
  }
  console.log(`Converting ${jobs.length} distinct MilkDrop presets`);
  let next=0, finished=0;
  await Promise.all(Array.from({length:6},async () => {
    let worker=new Worker(__filename);
    try {
      while (next<jobs.length) {
        const [index,source]=jobs[next++];
        const result=await convertOnWorker(worker,source);
        results[index]=result;
        if (result.restart) {
          await worker.terminate();
          worker=new Worker(__filename);
        }
        if (++finished%500===0) console.log(`Checked ${finished} presets`);
      }
    } finally {
      await worker.terminate();
    }
  }));
  for (const [index,[name,key]] of entries.entries()) {
    const {preset,error}=results[index];
    let reason=error || inspectPreset(preset);
    if (!reason) {
      const canonical = JSON.stringify(preset, (_,value) =>
        value && typeof value==='object' && !Array.isArray(value)
          ? Object.fromEntries(Object.keys(value).sort().map(key => [key,value[key]]))
          : value);
      const signature = sha256(canonical);
      let label = name.trim().normalize('NFC');
      if (byRenderedContent.has(signature)) reason = 'Identical converted preset';
      else if (!label || label.length > 280 || /[\u0000-\u001f]/.test(label)) reason = 'Invalid name';
      else {
        if (names.has(label)) label = `${label} (ProjectM ${key.slice(0,8)})`;
        names.add(label);
        byRenderedContent.add(signature);
        records.push({ name: label, preset });
      }
    }
    if (reason) {
      counts[reason] = (counts[reason] ?? 0)+1;
      skipped.push([name,reason]);
    }
  }
  const total=entries.length;
  records.sort((a,b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  fs.mkdirSync(destination, { recursive: true });
  for (const entry of fs.readdirSync(destination)) {
    if (/^page-\d+\.json$/.test(entry)) fs.rmSync(path.join(destination,entry));
  }
  for (let offset = 0; offset < records.length; offset += pageSize) {
    const data = records.slice(offset, offset + pageSize).map(entry => entry.preset);
    fs.writeFileSync(path.join(destination, `page-${offset/pageSize}.json`), JSON.stringify(data));
  }
  const manifest = { version: sha256(JSON.stringify(records)).slice(0,16), pageSize,
    names: records.map(entry => entry.name) };
  fs.writeFileSync(path.join(destination,'catalog.json'), JSON.stringify(manifest));
  fs.writeFileSync(reportPath, JSON.stringify({ sourceHash, total, imported: records.length,
    counts, skipped }, null, 2)+'\n');
  console.log(JSON.stringify({ total, imported: records.length, counts }));
}
if (isMainThread) {
  main().catch(error => { console.error(error); process.exitCode = 1; });
} else {
  parentPort.on('message',async source => {
    try {
      const preset=await convert(source);
      parentPort.postMessage({preset});
    } catch (error) {
      const detail=error instanceof SyntaxError ? 'Invalid equation syntax'
        : String(error.message ?? error).split('\n')[0].slice(0,160);
      parentPort.postMessage({error:detail});
    }
  });
}
