// Offline bridge tests. Synthetic tones are test input only, not app playback.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = fs.readFileSync(`${root}assets/visualizer/bridge.js`, 'utf8');
let time = 0, nextFrame = 0, destroyed = false, renders = 0, lastWave;
const callbacks = new Map(), messages = [], loaded = [];
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
  start() { this.running = true; }
  stop() { this.running = false; }
  destroy() { destroyed = true; }
}
const engine = {
  loadPreset(preset) { loaded.push(preset.id); },
  setRendererSize(width, height) { assert(width <= 960); assert(height <= 960); },
  render(options) { renders++; lastWave = [...options.audioLevels.timeByteArray]; },
};
const sandbox = {
  Uint8Array, Float32Array, Float64Array, Math, Number, String, JSON, Error,
  performance: {now: () => time},
  requestAnimationFrame(fn) { callbacks.set(++nextFrame, fn); return nextFrame; },
  cancelAnimationFrame(id) { callbacks.delete(id); },
  atob: value => Buffer.from(value, 'base64').toString('binary'),
  document: {
    getElementById: id => elements.get(id),
    addEventListener() {}, hidden: false,
  },
  ResizeObserver: class { observe() {} disconnect() {} },
  butterchurn: {default: {createVisualizer: () => engine}},
  butterchurnPresets: {getPresets: () => ({A:{id:'A'}, B:{id:'B'}})},
  AudioMotionAnalyzer: Analyzer,
};
sandbox.window = {
  AuralisVisuals: {postMessage: message => messages.push(JSON.parse(message))},
  AudioContext: class { sampleRate = 44100; close() { return Promise.resolve(); } },
  addEventListener() {},
};
vm.runInNewContext(source, sandbox);
const api = sandbox.window.auralisVisuals;
function advance(ms) {
  time += ms;
  const work = [...callbacks.values()];
  callbacks.clear();
  for (const fn of work) fn(time);
}
function tone(frequency) {
  return Buffer.from(Array.from({length:1024}, (_, i) =>
    Math.round(128+100*Math.sin(2*Math.PI*frequency*i/44100)))).toString('base64');
}
assert.equal(messages[0].type, 'ready');
api.configure({mode:'spectrum',active:true});
api.feed(tone(1000), 44100);
const bins = new Float32Array(512);
Analyzer.current._analyzer[0].getFloatFrequencyData(bins);
const peak = bins.indexOf(Math.max(...bins));
assert(Math.abs(peak * 44100/1024 - 1000) < 50, 'FFT must follow captured tone');
assert(Analyzer.current.running);
api.configure({mode:'spectrum',spectrum:'radial',palette:'classic',active:true});
assert(Analyzer.current.options.radial);
assert.equal(Analyzer.current.options.gradient,'classic');
api.configure({mode:'visualizer',active:true,cycle:true,cycleSeconds:15,fps:30});
api.feed(tone(440),44100);
advance(40);
assert(renders > 0);
assert(lastWave.some(sample => sample !== 128), 'Render consumes actual input samples');
advance(300);
assert(lastWave.every(sample => sample === 128), 'Stale audio must become silence');
advance(16000);
assert.equal(loaded.at(-1), 'B');
api.step(-1);
assert.equal(loaded.at(-1), 'A');
api.configure({active:false});
assert.equal(callbacks.size, 0);
const count = renders;
advance(1000);
assert.equal(renders,count);
api.configure({mode:'spectrum',active:true});
api.destroy();
assert(destroyed);
assert.equal(callbacks.size,0);
api.feed(tone(440),44100);
assert.equal(messages.filter(message => message.type === 'error').length,0);
console.log('Visualizer bridge checks passed: tone FFT, rendering input, silence, presets, pause and cleanup.');
