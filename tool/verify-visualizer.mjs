// Offline bridge tests. Synthetic tones are test input only, not app playback.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = fs.readFileSync(`${root}assets/visualizer/bridge.js`, 'utf8');
let time = 0, nextFrame = 0, destroyed = false, renders = 0, lastWave;
let resizeCallback, windowResizeCallback, visibilityCallback, rendererSize, createdSize;
let presetReads=0, renderCost=0, trigCalls=0;
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
  setOptions(options) { Object.assign(this.options, options); }
  setCanvasSize(width, height) { this.size = [width, height]; }
  start() { this.running = true; }
  stop() { this.running = false; }
  destroy() { destroyed = true; }
}
const engine = {
  loadPreset(preset, blend) { loaded.push(preset.id);blends.push(blend); },
  setRendererSize(width, height) {
    assert(width <= 4096); assert(height <= 4096);
    assert(width*height <= 8388608+4096);
    rendererSize = [width, height];
  },
  render(options) {
    renders++; lastWave = [...options.audioLevels.timeByteArray];time+=renderCost;
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
  butterchurnPresets: {getPresets: () => {presetReads++;return {A:{id:'A'}, B:{id:'B'}};}},
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
assert.equal(Analyzer.current.options.loRes,false, 'Spectrum must not use a half-resolution buffer');
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
assert.deepEqual(rendererSize,[1200,675], 'Animated visuals use panel pixels instead of a 960-pixel cap');
assert.deepEqual(createdSize,[1200,675], 'Initial render targets must also use the full drawing size');
assert.deepEqual([elements.get('milk').width,elements.get('milk').height],[1200,675],
  'The visible animated canvas must not retain its default 300 by 150 buffer');
for (const ratio of [1,1.25,2,3]) {
  sandbox.window.devicePixelRatio=ratio;
  windowResizeCallback();
  assert.deepEqual(rendererSize,[Math.round(1200*ratio),Math.round(675*ratio)],
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
assert(bins.every(value=>value===-100),'Animated visuals must not compute an unused spectrum FFT');
advance(40);
assert(renders > 0);
assert(lastWave.some(sample => sample !== 128), 'Render consumes actual input samples');
assert(Math.max(...lastWave)>228,'Real onsets should have headroom-limited transient emphasis');
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
renderCost=30;
for (let i=0;i<90;i++) advance(34);
assert(rendererSize[0]<sharpWidth,'Slow phone frames should reduce only animated pixel work');
assert(rendererSize[0]>=sharpWidth*.75-1,'Adaptive quality must not collapse to half resolution');
renderCost=0;
for (let i=0;i<500;i++) advance(34);
assert.equal(rendererSize[0],sharpWidth,'Phone quality should recover when there is headroom');
for (const element of elements.values()) {
  element.clientWidth=2000;element.clientHeight=1500;
}
sandbox.window.devicePixelRatio=2;
resizeCallback();
assert(rendererSize[0]<=2048 && rendererSize[1]<=2048);
assert(rendererSize[0]*rendererSize[1]<=2097152+4096,'Phones need a separate GPU pixel budget');
api.configure({mode:'spectrum',active:true});
assert.equal(Analyzer.current.options.loRes,false,'Spectrum text must stay full-resolution on phones');
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
assert(Math.max(...lastWave)>228,'A real bass/energy onset should increase visual sensitivity');
api.feed(tone(90,127),44100);advance(34);
assert(Math.max(...lastWave)<=255 && Math.min(...lastWave)>=1,
  'Transient emphasis must respect available sample headroom');
api.feed(Buffer.alloc(1024,128).toString('base64'),44100);advance(34);
assert(lastWave.every(sample=>sample===128),'Live silence must stay silent, not generate pulses');
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
api.destroy();
assert(destroyed);
assert.equal(callbacks.size,0);
api.feed(tone(440),44100);
assert.equal(messages.filter(message => message.type === 'error').length,0);
const html=fs.readFileSync(`${root}assets/visualizer/index.html`,'utf8');
assert.match(html, /#spectrum canvas\s*\{[^}]*width:\s*100%[^}]*height:\s*100%/,
  'Spectrum canvases must fill the CSS panel at every pixel density');
console.log('Visualizer bridge checks passed: lazy presets, cached FFT tables, audio attack/release and transients, phone adaptation/recovery, frame pacing, native-DPI sizing, silence, presets and cleanup.');
