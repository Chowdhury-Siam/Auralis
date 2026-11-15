// Execute the exact retained MIT-licensed Butterchurn audio sources in tests.
// This is not a reimplementation or the application's runtime loading path.
import fs from 'node:fs';
import vm from 'node:vm';
import {gunzipSync} from 'node:zlib';

export function butterchurnAudio() {
  const archive=gunzipSync(fs.readFileSync(new URL(
    '../third_party/visualizer/butterchurn/upstream-source.tar.gz',import.meta.url)));
  const sources=new Map();
  for (let offset=0;offset+512<=archive.length;) {
    const header=archive.subarray(offset,offset+512);
    const name=header.subarray(0,100).toString().split('\0')[0];
    if (!name) break;
    const size=parseInt(header.subarray(124,136).toString().replace(/\0/g,'').trim(),8)||0;
    if (/\/src\/audio\/(fft|audioProcessor|audioLevels)\.js$/.test(name))
      sources.set(name.split('/').at(-1),archive.subarray(offset+512,offset+512+size).toString());
    offset+=512+Math.ceil(size/512)*512;
  }
  const code=['fft.js','audioProcessor.js','audioLevels.js'].map(name=>{
    if (!sources.has(name)) throw Error(`Pinned Butterchurn source missing: ${name}`);
    return sources.get(name).replace(/^import .*;\r?$/gm,'')
      .replace('export default class','class');
  }).join('\n');
  const math=Object.create(Math);
  math.clamp=(value,low,high)=>Math.min(high,Math.max(low,value));
  const classes=vm.runInNewContext(`${code}\n({AudioProcessor,AudioLevels})`,{Math:math});
  const audio=new classes.AudioProcessor(null);
  return {audio,levels:new classes.AudioLevels(audio)};
}
