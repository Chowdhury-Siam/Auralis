// Offline bridge tests. Synthetic tones are test input only, not app playback.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import {butterchurnAudio} from './visualizer-audio-fixture.mjs';
import inspectPreset from './visualizer-preset-quality.cjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = fs.readFileSync(`${root}assets/visualizer/bridge.js`, 'utf8');
let time = 0, nextFrame = 0, destroyed = false, renders = 0, lastWave;
let resizeCallback, windowResizeCallback, visibilityCallback, rendererSize, createdSize;
let presetReads=0, renderCost=0, trigCalls=0;
const {audio,levels}=butterchurnAudio();
let lastLevels, lastPreset, lastEquation, lastElapsed;
const registered = new Map();
const testPresets={A:{id:'A',baseVals:{zoom:1,wave_scale:1,warp:.1,rot:0},frame_eqs_str:''},
  B:{id:'B',baseVals:{zoom:1,wave_scale:1,warp:.1,rot:0},frame_eqs_str:''}};
testPresets['Aderrasi + Geiss - Airhandler (Kali Mix) - Canvas Mix']={
  id:'excluded',baseVals:{},frame_eqs_str:'',
};
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
  setTimeout, clearTimeout,
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
function tone(frequency, amplitude=100, offset=0) {
  return Buffer.from(Array.from({length:1024}, (_, i) =>
    Math.round(128+amplitude*Math.sin(2*Math.PI*frequency*(i+offset)/44100)))).toString('base64');
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
api.configure({mode:'visualizer',active:true,cycle:true,songMotion:false,cycleSeconds:15,fps:30});
assert.equal(presetReads,1);
assert.deepEqual(messages.find(message => message.type==='presets').presets, ['A','B'],
  'Excluded stock presets must stay out of both the picker and the rotation');
assert.equal(inspectPreset({frame_eqs_str:"a['rot'] = a['time'];"}), 'No authored beat response');
assert.equal(inspectPreset({baseVals:{wave_a:0,mv_a:0},frame_eqs_str:'a.zoom=a.bass;'}),
  'No visible drawing layer');
assert.equal(inspectPreset({frame_eqs_str:'a.zoom+=a.bass_att;'}), null);
assert.equal(inspectPreset({waves:[{baseVals:{enabled:1},point_eqs_str:'a.y=.5+a.value1;'}]}), null);

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
const desktopSharp=rendererSize[0];
api.configure({fps:144,cycle:false});
for (let i=0;i<180;i++) advance(1000/60);
assert.equal(rendererSize[0],desktopSharp,'A 60 Hz display keeps sharp visuals with a 144 FPS limit');
renderCost=15;
for (let i=0;i<100;i++) advance(1000/60);
assert(rendererSize[0]<desktopSharp,'Costly Windows presets must reduce animated pixel work');
renderCost=0;
for (let i=0;i<1200;i++) advance(1000/60);
assert.equal(rendererSize[0],desktopSharp,'Windows recovers the full drawing size when frames are fast again');
api.configure({mode:'visualizer',active:true,cycle:false,fps:30});
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
// Android as-played capture can have only a few quantization steps at low volume.
// Such attacks still need to cross the pack's authored beat thresholds.
api.configure({mode:'visualizer',active:true,cycle:false,songMotion:true,song:'quiet beats'});
for (let i=0;i<90;i++) { api.feed(tone(86,1),44100);advance(34); }
api.feed(tone(86,4),44100);advance(34);
assert(lastLevels.instant[0]>1.3,
  'A quiet real bass attack must cross the imported presets beat thresholds');
const quiet=tone(90,16), accent=tone(90,110);
const silence=Buffer.alloc(1024,128).toString('base64');
function capture(samples) {
  api.feed(samples,44100);
  advance(34);
}
function hold(samples,ms) {
  for (let elapsed=0;elapsed<ms;elapsed+=34) capture(samples);
}
function cycleSong(song,cycleSeconds=15,mobile=false) {
  api.configure({mode:'visualizer',active:true,cycle:true,songMotion:true,
    cycleSeconds,song,mobile});
  return loaded.length;
}
const beforeRepeatedBeats=cycleSong('steady rhythm');
for (let i=0;i<180;i++) {
  hold(quiet,170);
  capture(accent);
}
assert.equal(loaded.length,beforeRepeatedBeats,'Repeated beats animate one preset without cycling it');
hold(silence,2000);
advance(61000);
assert.equal(loaded.length,beforeRepeatedBeats,'Silence or missing samples cannot force a switch');

const milkStyle=elements.get('milk').style;
for (const [cycleSeconds,mobile,blend] of [[15,false,1.35],[60,true,1]]) {
  const before=cycleSong(`level shift ${cycleSeconds}`,cycleSeconds,mobile);
  const started=time;
  hold(quiet,9200);
  hold(accent,170);
  hold(quiet,1500);
  assert.equal(loaded.length,before,'A short accent is not a new section');
  for (let i=0;i<120 && loaded.length===before;i++) capture(accent);
  assert.equal(loaded.length,before+1,'A sustained level shift changes the scene');
  assert.equal(blends.at(-1),blend);
  assert(time-started<15000,'Song-driven switching is independent of the timer');
  const initialOpacity=Number(milkStyle.opacity);
  hold(accent,blend*500);
  const blendOpacity=Number(milkStyle.opacity);
  assert(blendOpacity<initialOpacity*.76,'Mid-blend opacity softens bright transitions');
  hold(accent,blend*700);
  assert(Number(milkStyle.opacity)>blendOpacity*1.25,'Opacity returns smoothly after the blend');
  hold(accent,15000);
  assert.equal(loaded.length,before+1,'The same new section cannot trigger another switch');
}

const beforeToneShift=cycleSong('tone shift at constant loudness');
const bassTone=tone(90,76), trebleTone=tone(5000,76);
hold(bassTone,10000);
hold(trebleTone,3200);
assert.equal(loaded.length,beforeToneShift+1,'Sustained tone shifts work at constant loudness');

const beforeRhythmShift=cycleSong('rhythm shift at a consistent average level');
for (let i=0;i<12;i++) {
  hold(quiet,680);
  hold(accent,136);
}
assert.equal(loaded.length,beforeRhythmShift);
for (let i=0;i<26 && loaded.length===beforeRhythmShift;i++) {
  hold(quiet,170);
  capture(accent);
}
assert.equal(loaded.length,beforeRhythmShift+1,'A sustained attack-rate change can change the scene');

api.configure({cycle:false});
const beforeDisabled=loaded.length;
hold(bassTone,10000);
hold(trebleTone,5000);
assert.equal(loaded.length,beforeDisabled,'Turning off preset cycling also disables section changes');
api.configure({cycle:true,songMotion:false,cycleSeconds:15});
const beforeTimer=loaded.length;
advance(16000);
assert.equal(loaded.length,beforeTimer);
advance(600);
assert.equal(loaded.length,beforeTimer+1,'The selected timer still works with song-driven motion off');
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
// Exercise quantized phone-level attacks at different user frame limits.
for (const fps of [20,23,29,30,60,90,100,120,144]) {
  for (const [frequency,band] of [[86,0],[1200,1],[6000,2]]) {
    api.configure({song:`quiet attack ${fps}/${frequency}`,fps,cycle:false,songMotion:true});
    const frameMs=1000/fps;
    for (let i=0;i<Math.ceil(3000/frameMs);i++) {
      api.feed(tone(frequency,1),44100);advance(frameMs);
    }
    api.feed(tone(frequency,4),44100);advance(frameMs);
    assert(lastLevels.instant[band]>1.3,
      `Quiet ${frequency} Hz attacks must trigger preset beats at ${fps} FPS`);
    assert(scale()>1.002,'Each measured frequency band must move the visualizer');
    assert(lastEquation.zoom>1,'Each band attack must reach the preset geometry');
    for (let i=0;i<Math.ceil(1500/frameMs);i++) {
      // Real captures have continuously advancing phase, even on held notes.
      api.feed(tone(frequency,4,Math.round(i*frameMs*44.1)),44100);
      advance(frameMs);
    }
    assert(scale()<1.002,'A phase-changing held note must not generate false beats');
    assert(Math.abs(lastEquation.rot)<.0001,'Extra rotation must follow attacks instead of steady volume');
  }
}
api.configure({song:'quiet verse after loud chorus',fps:30,cycle:false,songMotion:true});
hold(tone(86,90),4000);
hold(tone(86,1),3000);
capture(tone(86,4));
assert(lastLevels.instant[0]>1.3,'A preceding loud passage must not suppress the next quiet beat');
api.configure({fps:30});
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
// Imported presets load one at a time, and rotation resumes from a saved cursor.
function openRotation(position) {
  vm.runInNewContext(source,sandbox);
  const bridge=sandbox.window.auralisVisuals;
  bridge.addPresetNames(['Imported 0','Imported 1','Imported 2']);
  bridge.usePresetRotation(413,position);
  bridge.configure({mode:'visualizer',active:false,song:'new session'});
  return bridge;
}
function receivePreset(bridge) {
  const message=messages.at(-1);
  if (message.type==='requestPreset') {
    assert(message.index>=0 && message.index<3);
    bridge.deliverPreset(message.ticket,{
      id:`Imported ${message.index}`,baseVals:{},frame_eqs_str:'',
    });
  }
  const selected=messages.at(-1);
  assert.equal(selected.type,'preset');
  return selected;
}
const firstSession=openRotation(0);
const draws=[receivePreset(firstSession).name];
firstSession.configure({song:'new session:second playback'});
const saved=receivePreset(firstSession);
draws.push(saved.name);
assert.equal(saved.rotationPosition,2);
firstSession.destroy();

const secondSession=openRotation(saved.rotationPosition);
draws.push(receivePreset(secondSession).name);
for (let i=0;i<2;i++) {
  secondSession.step(0);
  draws.push(receivePreset(secondSession).name);
}
assert.equal(new Set(draws).size,5,'All distinct presets play before rotation wraps across sessions');
secondSession.step(0);
assert.notEqual(receivePreset(secondSession).name,draws.at(-1),'Rotation does not repeat at the boundary');

secondSession.configure({preset:'Imported 0'});
const staleRequest=messages.at(-1);
secondSession.configure({preset:'Imported 1'});
const currentRequest=messages.at(-1);
assert.notEqual(staleRequest.ticket,currentRequest.ticket);
secondSession.deliverPreset(staleRequest.ticket,{id:'stale',baseVals:{}});
assert.equal(messages.at(-1),currentRequest,'A stale asset cannot overwrite a newer choice');
assert.equal(receivePreset(secondSession).name,'Imported 1');

secondSession.configure({preset:'Imported 2'});
secondSession.deliverPreset(messages.at(-1).ticket,null);
assert.equal(messages.at(-1).name,'Imported 1','Missing preset data preserves the current preset');
secondSession.destroy();

const html=fs.readFileSync(`${root}assets/visualizer/index.html`,'utf8');
assert.match(html, /#spectrum canvas\s*\{[^}]*width:\s*100%[^}]*height:\s*100%/,
  'Spectrum canvases must fill the CSS panel at every pixel density');
console.log('Visualizer bridge checks passed: real Butterchurn audio/equation energy, quiet beat thresholds at every frame limit, held-note rejection, loud-to-quiet recovery, sustained loud/quiet contrast, independent bands, silence/stale release, unmodified samples, lazy presets, FFT tables, Android and Windows adaptation/recovery, refresh-aware pacing, DPI, section-driven cycling, softened blends, lazy preset loading, persistent rotation and cleanup.');
