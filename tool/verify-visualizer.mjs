// Offline bridge tests. Synthetic tones are test input only, not app playback.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import {butterchurnAudio} from './visualizer-audio-fixture.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = fs.readFileSync(`${root}assets/visualizer/bridge.js`, 'utf8');
let time = 0, nextFrame = 0, destroyed = false, renders = 0, lastWave;
let resizeCallback, windowResizeCallback, visibilityCallback, rendererSize, createdSize;
let presetReads=0, renderCost=0, trigCalls=0;
const {audio,levels}=butterchurnAudio();
let lastLevels, lastPreset, lastEquation, lastElapsed;
const registered = new Map();
const testPresets={A:{id:'A',baseVals:{zoom:1,wave_scale:1,warp:.1},frame_eqs_str:''},
  B:{id:'B',baseVals:{zoom:1,wave_scale:1,warp:.1},frame_eqs_str:''}};
const math=Object.create(Math);
math.cos=value=>{trigCalls++;return Math.cos(value);};
math.sin=value=>{trigCalls++;return Math.sin(value);};
const callbacks = new Map(), messages = [], loaded = [], blends = [];
const elements = new Map(['status','milk','spectrum','surface'].map(id => [id, {
  style: {}, clientWidth: 800, clientHeight: 500,
  addEventListener() {}, getContext() { return null; },
}]));
class Analyzer {
  static current;
  constructor(_, options) {
    this.options = options;
    this._analyzer = [{}, {}];
    Analyzer.current = this;
  }
  registerGradient(name, options) { registered.set(name, options); }
  setOptions(options) { Object.assign(this.options, options); }
  setCanvasSize(width, height) { this.size = [width, height]; }
  start() { this.running = true; }
  stop() { this.running = false; }
  destroy() { destroyed = true; }
}
const engine = {
  audio, renderer:{audioLevels:levels},
  loadPreset(preset, blend) { loaded.push(preset.id);blends.push(blend);lastPreset=preset; },
  setRendererSize(width, height) {
    assert(width <= 4096); assert(height <= 4096);
    assert(width*height <= 8388608+4096);
    rendererSize = [width, height];
  },
  render(options) {
    renders++; lastWave = [...options.audioLevels.timeByteArray];time+=renderCost;
    const input=options.audioLevels;
    audio.updateAudio(input.timeByteArray,input.timeByteArrayL,input.timeByteArrayR);
    levels.updateAudioLevels(30,renders);
    lastLevels={instant:[...levels.val],smooth:[...levels.att]};
    lastElapsed=options.elapsedTime;
    assert(Number.isFinite(lastElapsed) && lastElapsed>=.001 && lastElapsed<=.1,
      'Every renderer frame needs a positive bounded elapsedTime');
    const vars={...lastPreset.baseVals,bass:levels.bass,bass_att:levels.bass_att,
      mid:levels.mid,mid_att:levels.mid_att,treb:levels.treb,treb_att:levels.treb_att};
    lastEquation=new Function('a',lastPreset.frame_eqs_str+'\nreturn a;')(vars);
  },
};
const sandbox = {
  Uint8Array, Float32Array, Float64Array, Math:math, Number, String, JSON, Error,
  performance: {now: () => time},
  requestAnimationFrame(fn) { callbacks.set(++nextFrame, fn); return nextFrame; },
  cancelAnimationFrame(id) { callbacks.delete(id); },
  atob: value => Buffer.from(value, 'base64').toString('binary'),
  document: {
    getElementById: id => elements.get(id),
    addEventListener(event, callback) {
      if (event==='visibilitychange') visibilityCallback=callback;
    }, hidden: false,
  },
  ResizeObserver: class {
    constructor(callback) { resizeCallback = callback; }
    observe() {} disconnect() {}
  },
  butterchurn: {default: {createVisualizer: (_, canvas, options) => {
    createdSize=[options.width,options.height];
    assert.deepEqual([canvas.width,canvas.height],createdSize);
    return engine;
  }}},
  butterchurnPresets: {getPresets: () => {presetReads++;return testPresets;}},
  AudioMotionAnalyzer: Analyzer,
};
sandbox.window = {
  devicePixelRatio: 1,
  AuralisVisuals: {postMessage: message => messages.push(JSON.parse(message))},
  AudioContext: class {
    sampleRate = 44100;
    suspend() { return Promise.resolve(); }
    close() { return Promise.resolve(); }
  },
  addEventListener(event, callback) {
    if (event==='resize') windowResizeCallback=callback;
  },
  removeEventListener() {},
};
vm.runInNewContext(source, sandbox);
const api = sandbox.window.auralisVisuals;
function advance(ms) {
  time += ms;
  const work = [...callbacks.values()];
  callbacks.clear();
  for (const fn of work) fn(time);
}
function tone(frequency, amplitude=100) {
  return Buffer.from(Array.from({length:1024}, (_, i) =>
    Math.round(128+amplitude*Math.sin(2*Math.PI*frequency*i/44100)))).toString('base64');
}
assert.equal(messages[0].type, 'ready');
assert.equal(presetReads,0,'Preset data must stay lazy until animated visuals are selected');
api.configure({mode:'spectrum',active:true});
assert.equal(presetReads,0,'Spectrum must not parse the preset pack');
assert.deepEqual(Analyzer.current.size, [800,500]);
assert.equal(Analyzer.current.options.loRes,false, 'Desktop Spectrum preserves display resolution');
assert.equal(registered.size,10);
assert.equal(callbacks.size,0,'Spectrum must use only the analyzer animation loop');
for (const fps of [23,29,90,100,120,144]) {
  api.configure({fps,spectrum:'led',palette:'sakura'});
  assert.equal(Analyzer.current.options.maxFPS,fps);
  assert(Analyzer.current.options.ledBars);
  assert.equal(Analyzer.current.options.gradient,'sakura');
}
for (const element of elements.values()) {
  element.clientWidth=1200;element.clientHeight=675;
}
resizeCallback();
assert.deepEqual(Analyzer.current.size,[1200,675], 'Spectrum follows expanded panel dimensions');
const bootstrapTrigCalls=trigCalls;
api.feed(tone(1000), 44100);
assert.equal(trigCalls,bootstrapTrigCalls,'FFT tables must be precomputed, not trig-heavy per sample');
const bins = new Float32Array(512);
Analyzer.current._analyzer[0].getFloatFrequencyData(bins);
const peak = bins.indexOf(Math.max(...bins));
assert(Math.abs(peak * 44100/1024 - 1000) < 50, 'FFT must follow captured tone');
assert(bins[peak]>-30,'Spectrum attack should follow real transients promptly');
const attack=bins[peak];
api.feed(Buffer.alloc(1024,128).toString('base64'),44100);
Analyzer.current._analyzer[0].getFloatFrequencyData(bins);
assert(bins[peak]<attack && bins[peak]>-100,'Release must decay rather than flicker to silence');
assert(Analyzer.current.running);
api.configure({mode:'spectrum',spectrum:'radial',palette:'classic',active:true});
assert(Analyzer.current.options.radial);
assert.equal(Analyzer.current.options.gradient,'classic');
api.configure({mode:'visualizer',active:true,cycle:true,cycleSeconds:15,fps:30});
assert.equal(presetReads,1);

assert.deepEqual(createdSize,[1200,675], 'Initial render targets must also use the full drawing size');
assert.deepEqual([elements.get('milk').width,elements.get('milk').height],[1200,675],
  'The visible animated canvas must not retain its default 300 by 150 buffer');
for (const ratio of [1,1.25,2,3]) {
  sandbox.window.devicePixelRatio=ratio;
  windowResizeCallback();
  assert.deepEqual(rendererSize ?? createdSize,[Math.round(1200*ratio),Math.round(675*ratio)],
    'Animated visuals must track the physical pixel density');
}
for (const element of elements.values()) {
  element.clientWidth=10000;element.clientHeight=5000;
}
sandbox.window.devicePixelRatio=4;
resizeCallback();
assert.deepEqual(rendererSize,[4096,2048], 'Huge surfaces still obey the safety budget');
for (const element of elements.values()) {
  element.clientWidth=1200;element.clientHeight=675;
}
sandbox.window.devicePixelRatio=1;
resizeCallback();
api.feed(tone(440),44100);
Analyzer.current._analyzer[0].getFloatFrequencyData(bins);
assert(bins.every(value=>value===-100),'Animated energy analysis must skip unused Spectrum decibel/smoothing work');
advance(40);
assert(renders > 0);
assert(lastWave.some(sample => sample !== 128), 'Render consumes actual input samples');
assert.equal(Math.max(...lastWave),228,'Captured samples must reach Butterchurn without artificial gain');
advance(300);
assert(lastWave.every(sample => sample === 128), 'Stale audio must become silence');
advance(19000);
assert.equal(loaded.at(-1), 'B');
api.step(-1);
assert.equal(loaded.at(-1), 'A');
api.configure({active:false});
assert.equal(callbacks.size, 0);
const count = renders;
advance(1000);
assert.equal(renders,count);
api.configure({mode:'visualizer',active:true,cycle:false,mobile:true,fps:30});
const sharpWidth=rendererSize[0];
assert(sharpWidth<=1120);
renderCost=30;
for (let i=0;i<90;i++) advance(34);
assert(rendererSize[0]<sharpWidth,'Slow phone frames should reduce only animated pixel work');
assert(rendererSize[0]>=sharpWidth*.5-1,'Adaptive quality has a lower bound');
renderCost=0;
for (let i=0;i<500;i++) advance(34);
assert.equal(rendererSize[0],sharpWidth,'Phone quality should recover when there is headroom');
for (const element of elements.values()) {
  element.clientWidth=2000;element.clientHeight=1500;
}
sandbox.window.devicePixelRatio=2;
resizeCallback();
assert(rendererSize[0]<=1120 && rendererSize[1]<=1120);
assert(rendererSize[0]*rendererSize[1]<=640000+2048,'Phones need a separate GPU pixel budget');
api.configure({mode:'spectrum',active:true});
assert.equal(Analyzer.current.options.loRes,true,'Phone Spectrum uses a lower drawing resolution');
for (const element of elements.values()) {
  element.clientWidth=1200;element.clientHeight=675;
}
sandbox.window.devicePixelRatio=1;
api.configure({mode:'visualizer',active:true,mobile:false,fps:30});
const paced=renders;
for (let i=0;i<60;i++) advance(16.5);
assert(renders-paced>=28 && renders-paced<=31,'30 FPS pacing must not drift down to 20 FPS');
api.configure({mode:'visualizer',active:true,cycle:false});
for (let i=0;i<25;i++) {
  api.feed(tone(90,20),44100);advance(50);
}
assert.equal(Math.max(...lastWave),148,'Steady input must not create a repeating artificial beat');
api.feed(tone(90,100),44100);advance(34);
assert(lastLevels.instant[0]>.5,'A real bass/energy onset should reach the preset equations');
assert.equal(Math.max(...lastWave),228,'Energy response must not clip or inflate the waveform');
api.feed(tone(90,127),44100);advance(34);
assert(Math.max(...lastWave)<=255 && Math.min(...lastWave)>=1,
  'Transient emphasis must respect available sample headroom');
api.feed(Buffer.alloc(1024,128).toString('base64'),44100);advance(34);
assert(lastWave.every(sample=>sample===128),'Live silence must stay silent, not generate pulses');
api.configure({mode:'visualizer',active:false});
api.configure({mode:'visualizer',active:true,cycle:true,cycleSeconds:15});
const beforeBeatCycle=loaded.length;
advance(15020);
assert.equal(loaded.length,beforeBeatCycle,'Due cycles should briefly wait for an actual onset');
api.feed(tone(90),44100);advance(34);
assert.equal(loaded.length,beforeBeatCycle+1,'An actual onset should release the pending cycle');
assert.equal(blends.at(-1),.35);
api.configure({mode:'visualizer',active:true,cycle:true,cycleSeconds:15});
const beforeFallback=loaded.length;
advance(16000);
assert.equal(loaded.length,beforeFallback);
advance(600);
assert.equal(loaded.length,beforeFallback+1,'Cycling must still work in silence after the bounded wait');
assert.equal(blends.at(-1),1.2);
sandbox.document.hidden=true;
visibilityCallback();
assert.equal(callbacks.size,1,'Desktop occlusion must not cancel the render loop');
api.configure({mode:'visualizer',active:false});
assert.equal(callbacks.size,0,'Explicit desktop minimize/lifecycle stop must cancel rendering');
api.configure({mode:'visualizer',active:true,mobile:true});
visibilityCallback();
assert.equal(callbacks.size,0,'Android background visibility must still stop rendering');
sandbox.document.hidden=false;
api.configure({mode:'spectrum',active:true});
assert.deepEqual(Analyzer.current.size,[1200,675], 'Switching back restores spectrum dimensions');
// These exercise the real pinned engine's audio path, not a sample-only mock.
api.configure({mode:'visualizer',active:true,cycle:false,mobile:false});
levels.longAvg.fill(0);levels.avg.fill(0); // The native long-silence steady state.
for (let i=0;i<120;i++) {
  api.feed(Buffer.alloc(1024,128).toString('base64'),44100);advance(34);
}
assert(lastLevels.instant.every(value=>value===0),
  'Actual Butterchurn preset energy must be zero in silence, not its native neutral value of one');
assert(lastLevels.smooth.every(value=>value<.001),'Silence must also release attenuated energy');
function settleEnergy(amplitude) {
  for (let i=0;i<240;i++) { api.feed(tone(90,amplitude),44100);advance(34); }
  return lastLevels.instant[0];
}
const quietBass=settleEnergy(12), loudBass=settleEnergy(90);
assert(loudBass>quietBass*2,
  'Sustained loud and quiet music must not normalize to the same preset energy');
assert(lastLevels.instant.every(Number.isFinite));
assert(lastLevels.instant.every(value=>value>=0 && value<=4));
console.log(`Real Butterchurn bass energy: quiet=${quietBass.toFixed(3)}, loud=${loudBass.toFixed(3)} (${(loudBass/quietBass).toFixed(1)}x).`);
assert(lastLevels.instant[0]>lastLevels.instant[1]*10 &&
  lastLevels.instant[0]>lastLevels.instant[2]*10,
  'A bass tone must not falsely drive the mid and treble bands');
const onsetLevels=[...lastLevels.instant];
for (let i=0;i<100;i++) { api.feed(tone(6000,90),44100);advance(34); }
assert(lastLevels.instant[2]>lastLevels.instant[0]*10,
  'Treble changes must reach the treble equations independently of bass');
assert(lastLevels.instant[2]>onsetLevels[2]*10);
const loudTreble=lastLevels.instant[2];
advance(130);
assert(lastLevels.instant[2]<loudTreble,'Missing samples should release energy before the stale cutoff');
advance(150);
assert(lastLevels.instant.every(value=>value===0),'Stale input must not leave preset energy frozen');
const milkStyle=elements.get('milk').style;
function scale() { return Number(milkStyle.transform.match(/scale\(([^)]+)\)/)?.[1]||1); }
api.configure({mode:'visualizer',active:true,songMotion:true,cycle:false});
for (let i=0;i<90;i++) { api.feed(tone(90,18),44100);advance(34); }
const quietOpacity=Number(milkStyle.opacity);
assert(scale()<1.001,'Steady bass must not generate periodic fake kicks');
api.feed(tone(90,90),44100);advance(34);
assert(scale()>1.005,'A real bass onset must visibly move even a non-reactive preset');
assert(lastEquation.zoom>1,'Bass attacks must reach preset feedback geometry as well as the compositor');
assert(lastEquation.warp>.1,'Preset warp must receive the bounded real-audio kick');
assert.equal(testPresets.A.frame_eqs_str,'','Original preset equations must not be mutated');
assert(scale()<=1.035,'Master movement must stay restrained and avoid exposed edges');
assert(Number(milkStyle.opacity)>quietOpacity,'Louder passages must be visibly distinct');
for (let i=0;i<90;i++) { api.feed(tone(90,90),44100);advance(34); }
assert(scale()<1.001,'Held notes must release to a steady view, not keep pumping');
const heldOpacity=Number(milkStyle.opacity);
for (let i=0;i<30;i++) { api.feed(Buffer.alloc(1024,128).toString('base64'),44100);advance(34); }
assert(Number(milkStyle.opacity)<.01,'Silence must fade preset-authored autonomous motion');
assert(Number(milkStyle.opacity)<heldOpacity*.05);
api.configure({songMotion:false,active:true});
assert.equal(milkStyle.opacity,'1');
assert.equal(milkStyle.transform,'none','Original preset appearance remains available');
api.feed(tone(90,90),44100);advance(34);
assert.equal(milkStyle.opacity,'1');
assert.equal(milkStyle.transform,'none');
assert.equal(lastPreset.frame_eqs_str,'','Disabling song motion restores untouched preset equations');
assert.equal(lastEquation.zoom,1);
api.configure({songMotion:true,active:true});
// Equal-power band changes exercise spectral novelty when RMS barely changes.
for (let i=0;i<60;i++) { api.feed(tone(86,70),44100);advance(34); }
const beforeBandShift=lastLevels.instant[0];
api.feed(tone(258,70),44100);advance(34);
assert(scale()>1.003,'A constant-loudness bass spectral attack must drive visible response');
assert(lastLevels.instant[0]>beforeBandShift,'Spectral attacks must also accent preset equations');
for (let i=0;i<30;i++) advance(34);
assert(Number(milkStyle.opacity)<.01,'Missing sample release also reaches the master compositor');
api.configure({mode:'visualizer',active:true,cycle:false,song:'Japanese song'});
const firstEquation=lastPreset.frame_eqs_str;
const nextSet=new Set();
for (let i=0;i<4;i++) {
  api.step(0);
  nextSet.add(loaded.at(-1));
}
assert.equal(nextSet.size,2,'Automatic selection uses every preset before recycling');
api.configure({song:'Another song'});
assert.notEqual(lastPreset.frame_eqs_str,firstEquation,'Different songs receive different motion');
api.destroy();
assert(destroyed);
assert.equal(callbacks.size,0);
api.feed(tone(440),44100);
assert.equal(messages.filter(message => message.type === 'error').length,0);
const html=fs.readFileSync(`${root}assets/visualizer/index.html`,'utf8');
assert.match(html, /#spectrum canvas\s*\{[^}]*width:\s*100%[^}]*height:\s*100%/,
  'Spectrum canvases must fill the CSS panel at every pixel density');
console.log('Visualizer bridge checks passed: real Butterchurn audio/equation energy, sustained loud/quiet contrast, independent bands, silence/stale release, unmodified samples, lazy presets, FFT tables, phone adaptation/recovery, pacing, DPI, cycling and cleanup.');
