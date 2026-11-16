/* Auralis output-waveform bridge. No microphone, media URL, socket or network.
 * Butterchurn's documented audioLevels input consumes the native waveform.
 * A pinned equation-level adapter preserves absolute loudness and band dynamics
 * instead of relying only on Butterchurn's long-average normalization.
 * audioMotion 4.5.4 consumes our Hann-windowed FFT through its pinned analyser
 * readers, not a second audio player or an oscillator masquerading as music.
 */
(() => {
  'use strict';
  const status = document.getElementById('status');
  const milk = document.getElementById('milk');
  const spectrum = document.getElementById('spectrum');
  let visualizer, analyzer, audioContext, request = 0, lastFrame = 0;
  let lastAudio = -Infinity, lastCycle = 0, destroyed = false;
  let qualityScale=1, qualityAt=0, qualityFrames=0, slowFrames=0, lastDraw=0;
  let lastRaf=0, refreshInterval=1000/60, cadenceTotal=0, cadenceSamples=0;
  let song='', take=0, songInitialized=false;
  let activePreset='', activeSource, pendingPreset, presetTicket=0;
  let rotationSeed=0, rotationPosition=0, orderRound=-1, order=[];
  const unavailablePresets=new Set(), projectmIndexes=new Map();
  let lastTransform='', lastOpacity='', audioRevision=0, silent=true;
  let lastBeat=-Infinity, energyAverage=0, bassAverage=0, highAverage=0;
  let sectionAudioMs=0, sectionShiftMs=0;
  const sectionSample=new Float32Array(5);
  const sectionRecent=new Float32Array(5), sectionReference=new Float32Array(5);
  const sectionMinAudioMs=9000, sectionHoldMs=1600;
  let blendElapsed=0, blendDuration=0;
  let energyRms=0, lastEnergyRender=0;
  let outputEnergy=0, outputPulse=0;
  const bandRms=new Float32Array(3), bandAverage=new Float32Array(3);
  const bandRelease=new Float32Array(3);
  const previousMagnitude=new Float32Array(512), flux=new Float32Array(3);
  const bandMagnitude=new Float32Array(3), impulses=new Float32Array(3);
  const impulseAt=new Float64Array(3).fill(-Infinity);
  let options = {mode:'spectrum', spectrum:'line', palette:'prism',
    fps:30, cycle:true, cycleSeconds:30, preset:'', active:false, mobile:false,
    songMotion:true,song:''};
  const frameLimits=[20,23,29,30,60,90,100,120,144];
  const spectrumStyles={
    line:{mode:10,reflexRatio:.15}, bars:{mode:2}, radial:{mode:2,radial:true},
    fine:{mode:1}, wide:{mode:5,barSpace:.22},
    led:{mode:4,ledBars:true}, outline:{mode:3,outlineBars:true,lineWidth:2},
    glow:{mode:4,alphaBars:true}, mirror:{mode:3,mirror:1},
    wave:{mode:10,fillAlpha:0,showPeaks:false,lineWidth:2.5},
    ridge:{mode:10,peakLine:true,fillAlpha:.08},
    halo:{mode:10,radial:true,fillAlpha:.25,lineWidth:2},
    inward:{mode:3,radial:true,radialInvert:true},
  };
  const palettes={
    aurora:['#7c54f6','#53f9ac','#09c5cb'],
    sunset:['#554bd2','#f15d91','#ffbd64'],
    ember:['#a3343e','#ff6c37','#ffe283'],
    glacier:['#386ce4','#54d8ee','#ebfcff'],
    orchid:['#6132bf','#b971f7','#f7b3ee'],
    mint:['#147a66','#47dcb1','#d0ffe7'],
    neon:['#d0ff00','#00ffb7','#4b79ff'],
    sakura:['#d84a85','#ffa3c9','#fff0f6'],
    marine:['#374ac6','#008b96','#44ffd6'],
    sand:['#b46b43','#eda961','#fff1b1'],
  };
  const waveform = new Uint8Array(1024).fill(128);
  const real = new Float64Array(1024), imag = new Float64Array(1024);
  const smooth = new Float32Array(512).fill(-100);
  const hann=new Float64Array(1024), cosine=new Float64Array(512), sine=new Float64Array(512);
  const reversed=new Uint16Array(1024);
  for (let i=0;i<1024;i++) {
    hann[i]=.5-.5*Math.cos(2*Math.PI*i/1023);
    let value=i,index=0;
    for (let bit=0;bit<10;bit++) { index=(index<<1)|(value&1);value>>=1; }
    reversed[i]=index;
  }
  for (let i=0;i<512;i++) {
    cosine[i]=Math.cos(-2*Math.PI*i/1024);
    sine[i]=Math.sin(-2*Math.PI*i/1024);
  }
  let presets, builtInNames=[], names=[];
  function library(name) {
    const script=document.getElementById('library-'+name);
    if (!script || !script.textContent) throw Error('Missing offline renderer: '+name);
    // Only bundled, CSP-contained application assets enter this path.
    (0,eval)(script.textContent);
    script.textContent='';
  }
  function ensurePresets() {
    if (presets) return;
    if (typeof butterchurnPresets==='undefined') library('presets');
    presets=butterchurnPresets.getPresets();
    builtInNames=Object.keys(presets).filter(name => name!=='Flexi + Martin - astral projection');
    names=[...builtInNames,...projectmIndexes.keys()];
    send({type:'presets',presets:builtInNames});
  }
  function send(message) {
    const value = JSON.stringify(message);
    if (window.AuralisVisuals) window.AuralisVisuals.postMessage(value);
    else if (window.chrome && window.chrome.webview) window.chrome.webview.postMessage(value);
  }
  function fail(error) {
    options.active = false;
    stop();
    status.style.display = 'grid';
    status.textContent = 'This visualizer is unavailable. Return to Lyrics or try another mode.';
    send({type:'error', message:String(error && error.message || error).slice(0,300)});
  }
  function fft() {
    let mean = 0;
    for (let i=0;i<1024;i++) mean += (waveform[i]-128)/128;
    mean /= 1024;
    for (let i=0;i<1024;i++) {
      real[reversed[i]] = ((waveform[i]-128)/128-mean) * hann[i];
      imag[i] = 0;
    }
    for (let size=2;size<=1024;size*=2) {
      const half=size/2;
      for (let start=0;start<1024;start+=size) for (let j=0;j<half;j++) {
        const twiddle=j*1024/size, c=cosine[twiddle], s=sine[twiddle];
        const k=start+j, l=k+half;
        const r=real[l]*c-imag[l]*s, v=real[l]*s+imag[l]*c;
        real[l]=real[k]-r;imag[l]=imag[k]-v;real[k]+=r;imag[k]+=v;
      }
    }
    if (options.mode==='spectrum') {
      for (let i=0;i<512;i++) {
        const power=real[i]*real[i]+imag[i]*imag[i];
        const db=Math.max(-100,10*Math.log10(Math.max(1e-16,power/65536)));
        smooth[i]+=(db>smooth[i]?.85:.3)*(db-smooth[i]);
      }
      return;
    }
    bandRms.fill(0);
    flux.fill(0);bandMagnitude.fill(0);
    for (let i=0;i<512;i++) {
      const power=real[i]*real[i]+imag[i]*imag[i], hz=i*44100/1024;
      const magnitude=Math.sqrt(power)/256;
      if (hz>=20 && hz<11025) {
        const band=hz<320?0:hz<2800?1:2;
        // One-sided Hann-window energy, corrected for its squared window sum.
        bandRms[band]+=power/196416;
        flux[band]+=Math.max(0,magnitude-previousMagnitude[i]);
        bandMagnitude[band]+=magnitude;
      }
      previousMagnitude[i]=magnitude;
    }
    for (let i=0;i<3;i++) {
      bandRms[i]=Math.sqrt(bandRms[i]);
      flux[i]/=bandMagnitude[i]+.02;
    }
  }
  function react(time) {
    let mean=0,energy=0;
    for (let i=0;i<1024;i++) mean+=(waveform[i]-128)/128;
    mean/=1024;
    for (let i=0;i<1024;i++) {
      const sample=(waveform[i]-128)/128-mean;
      energy+=sample*sample;
    }
    energyRms=energy=Math.sqrt(energy/1024);
    const bass=bandRms[0], high=Math.hypot(bandRms[1],bandRms[2]);
    const elapsed=Number.isFinite(lastAudio)?Math.max(0,time-lastAudio):33;
    let strongOnset=false;
    for (let i=0;i<3;i++) {
      impulses[i]*=Math.exp(-Math.min(elapsed,250)/110);
      // Positive spectral change catches drum attacks even under compressed
      // music with nearly constant overall RMS. No oscillator/BPM clock.
      const rise=bandRms[i]/(bandAverage[i]+.006)-1;
      const novelty=Math.max((flux[i]-.18)*1.6,(rise-.18)*.65);
      if (energy>.008 && bandRms[i]>.004 && novelty>0 &&
          time-impulseAt[i]>100) {
        impulses[i]=Math.max(impulses[i],Math.min(1,novelty));
        impulseAt[i]=time;
        if (novelty>.2) strongOnset=true;
      }
    }
    const attack=Math.max(energy/(energyAverage+.008),bass/(bassAverage+.004),
      high/(highAverage+.008));
    const onset=(strongOnset || (energy>.012 && attack>1.35)) && time-lastBeat>=120;
    if (onset) lastBeat=time;
    if (options.songMotion && options.cycle) updateSection(elapsed,onset);
    const weight=1-Math.exp(-Math.min(elapsed,100)/300);
    const established=energyAverage>0;
    energyAverage=established?energyAverage+weight*(energy-energyAverage):energy;
    bassAverage=established?bassAverage+weight*(bass-bassAverage):bass;
    highAverage=established?highAverage+weight*(high-highAverage):high;
    const slow=1-Math.exp(-Math.min(elapsed,100)/2000);
    for (let i=0;i<3;i++) {
      bandAverage[i]=bandAverage[i]>0
        ?bandAverage[i]+slow*(bandRms[i]-bandAverage[i]):bandRms[i];
    }
  }
  function updateSection(elapsed,onset) {
    if (elapsed>250 || energyRms<.012) {
      sectionShiftMs=0;
      return;
    }
    const dt=Math.min(elapsed,100);
    if (dt<=0) return;
    const power=bandRms[0]**2+bandRms[1]**2+bandRms[2]**2+.000001;
    // Loudness in dB, relative bass/mid/treble power, and attacks per second.
    sectionSample[0]=20*Math.log10(energyRms);
    for (let i=0;i<3;i++) sectionSample[i+1]=bandRms[i]**2/power;
    sectionSample[4]=onset && sectionAudioMs>0?1000/dt:0;
    if (sectionAudioMs===0) {
      sectionRecent.set(sectionSample);
      sectionReference.set(sectionSample);
    } else {
      const recentWeight=1-Math.exp(-dt/1000);
      for (let i=0;i<5;i++) {
        sectionRecent[i]+=recentWeight*(sectionSample[i]-sectionRecent[i]);
      }
    }
    sectionAudioMs+=dt;
    const levelDelta=Math.abs(sectionRecent[0]-sectionReference[0]);
    let toneDelta=0;
    for (let i=1;i<4;i++) toneDelta+=Math.abs(sectionRecent[i]-sectionReference[i]);
    const rhythmDelta=Math.abs(sectionRecent[4]-sectionReference[4]);
    const changed=levelDelta>=4.5 || toneDelta>=.38 ||
      rhythmDelta>=Math.max(1.65,.38*sectionReference[4]);
    if (sectionAudioMs>=3200 && changed) {
      // Keep the previous section as a reference until the new one persists.
      sectionShiftMs+=dt;
    } else {
      sectionShiftMs=0;
      const referenceWeight=1-Math.exp(-dt/(sectionAudioMs<3200?750:8000));
      for (let i=0;i<5;i++) {
        sectionReference[i]+=referenceWeight*(sectionRecent[i]-sectionReference[i]);
      }
    }
  }
  function installEnergyResponse() {
    // Pinned 2.6.7 adapter: its stock long-average ratios flatten sustained
    // loud/quiet sections and eventually return 1 in silence. Keep its complete
    // waveform/spectrum pipeline, but give preset equations measured dynamics.
    const levels=visualizer.renderer?.audioLevels;
    if (!levels || typeof levels.updateAudioLevels!=='function' ||
        levels.val?.length!==3 || levels.att?.length!==3)
      throw Error('Unsupported offline energy adapter');
    // The 2.6.7 renderer otherwise recomputes three FFTs on every draw,
    // including high-refresh frames reusing the same native capture.
    const audio=visualizer.audio;
    if (typeof audio?.updateAudio==='function') {
      const updateAudio=audio.updateAudio.bind(audio);
      let lastRevision=-1;
      audio.updateAudio=(...samples)=>{
        if (lastRevision===audioRevision) return;
        lastRevision=audioRevision;
        updateAudio(...samples);
      };
    }
    const nativeUpdate=levels.updateAudioLevels.bind(levels);
    levels.updateAudioLevels=(fps,frame)=>{
      nativeUpdate(fps,frame);
      const now=performance.now(), age=now-lastAudio;
      const elapsed=lastEnergyRender?Math.min(100,Math.max(0,now-lastEnergyRender)):1000/options.fps;
      lastEnergyRender=now;
      const fresh=age<=100?1:age<250?Math.exp(-(age-100)/70):0;
      // MilkDrop equations expect normal programme levels near one. The old
      // linear 4*RMS mapping left the supplied music around 0.2, making many
      // beat equations effectively idle. A bounded perceptual curve preserves
      // dynamics without auto-normalizing quiet passages to loud ones.
      const loudness=energyRms>=.006?Math.min(1.8,3*Math.sqrt(energyRms))*fresh:0;
      for (let i=0;i<3;i++) {
        // Reject quantization noise and absent bands, rather than making a
        // bass-only tone look like simultaneous bass, mid and treble energy.
        const presence=bandRms[i]>.003
          ?Math.min(1,bandRms[i]/Math.max(.008,energyRms*.15)):0;
        const contrast=Math.min(2,bandRms[i]/(bandAverage[i]+.008));
        const pulse=impulses[i]*Math.exp(-Math.max(0,age)/110);
        const value=Math.min(4,loudness*presence*(contrast+pulse*1.25));
        const weight=1-Math.exp(-elapsed/(value>bandRelease[i]?45:140));
        bandRelease[i]+=weight*(value-bandRelease[i]);
        levels.val[i]=value;
        levels.att[i]=bandRelease[i];
      }
      updateSongMotion(elapsed,fresh,age);
    };
  }
  function updateSongMotion(elapsed,fresh,age) {
    if (!options.songMotion) {
      milk.style.opacity='1';milk.style.transform='none';
      return;
    }
    // One compositor transform/opacity, no extra canvas, shader pass or FFT.
    // Preset feedback can keep moving on its own; this response remains tied
    // to the actual audio regardless of which preset is selected.
    const target=energyRms>=.006?Math.min(1,3*Math.sqrt(energyRms))*fresh:0;
    const weight=1-Math.exp(-elapsed/(target>outputEnergy?30:160));
    outputEnergy+=weight*(target-outputEnergy);
    const kick=impulses[0]*Math.exp(-Math.max(0,age)/110)*fresh;
    const pulseWeight=1-Math.exp(-elapsed/(kick>outputPulse?18:110));
    outputPulse+=pulseWeight*(kick-outputPulse);
    // Dim the middle of the native crossfade without a readback or extra pass.
    const progress=blendDuration>0?blendElapsed/blendDuration:1;
    blendElapsed=Math.min(blendDuration,blendElapsed+elapsed);
    const shade=1-1.28*progress*(1-progress);
    const opacity=Math.min(1,outputEnergy*(.84+.16*outputPulse))*shade;
    // At most 3.5% outward movement, never shrink/reveal unpainted edges.
    const nextOpacity=opacity.toFixed(3);
    const nextTransform=`scale(${(1+.035*outputPulse).toFixed(4)})`;
    if (nextOpacity!==lastOpacity) milk.style.opacity=lastOpacity=nextOpacity;
    if (nextTransform!==lastTransform) milk.style.transform=lastTransform=nextTransform;
  }
  function ensureSpectrum() {
    if (analyzer) return;
    if (typeof AudioMotionAnalyzer==='undefined') library('audiomotion');
    audioContext = new (window.AudioContext || window.webkitAudioContext)({sampleRate:44100});
    analyzer = new AudioMotionAnalyzer(spectrum, {
      audioCtx:audioContext, connectSpeakers:false, start:false, fftSize:1024,
      overlay:true, showBgColor:false, bgAlpha:0, maxFPS:options.fps,
      minFreq:30, maxFreq:16000, minDecibels:-85, maxDecibels:-10,
      showScaleX:true, showPeaks:true, smoothing:.5, loRes:options.mobile,
    });
    // Samples come from native output capture, not a Web Audio graph.
    audioContext.suspend().catch(()=>{});
    // Pinned library adapter. The graph remains disconnected from speakers.
    for (const [name, colors] of Object.entries(palettes)) {
      analyzer.registerGradient(name, {dir:'h',colorStops:[...colors]});
    }
    for (const node of analyzer._analyzer) {
      node.getFloatFrequencyData = target => {
        const age=performance.now()-lastAudio;
        const fade=age<=180?1:Math.max(0,1-(age-180)/180);
        for (let i=0;i<target.length;i++) target[i]=-100+(smooth[i]+100)*fade;
      };
    }
  }
  function hash(text) {
    let value=2166136261;
    for (let i=0;i<text.length;i++) value=Math.imul(value^text.charCodeAt(i),16777619);
    return value>>>0;
  }
  function shuffle(round) {
    const shuffled=names.slice();
    let seed=hash(`${rotationSeed || options.variation || 1}:${round}`);
    for (let i=shuffled.length-1;i>0;i--) {
      seed=(Math.imul(seed,1664525)+1013904223)>>>0;
      const j=seed%(i+1);
      [shuffled[i],shuffled[j]]=[shuffled[j],shuffled[i]];
    }
    return shuffled;
  }
  function rotationOrder(round) {
    order=shuffle(names.length===2?0:round);
    // A deterministic swap across round boundaries survives a WebView restart.
    // The last entry is unaffected by the swap in packs with at least 3 entries.
    if (round>0 && order.length>2) {
      const previous=shuffle(round-1);
      if (order[0]===previous[previous.length-1])
        [order[0],order[1]]=[order[1],order[0]];
    }
    orderRound=round;
  }
  function nextPreset(blend,retry=0) {
    const count=names.length;
    for (let i=0;i<count;i++) {
      const round=Math.floor(rotationPosition/count);
      if (orderRound!==round) rotationOrder(round);
      const name=order[rotationPosition++%count];
      if (unavailablePresets.has(name) || (count>1 && name===activePreset)) continue;
      selectPreset(name,blend,true,retry);
      return;
    }
  }
  function cancelPresetRequest() {
    if (pendingPreset) clearTimeout(pendingPreset.timeout);
    pendingPreset=null;
  }
  function selectPreset(name,blend,automatic=false,retry=0) {
    cancelPresetRequest();
    if (name===activePreset && activeSource) {
      loadPreset(name,activeSource,blend,automatic);
    } else if (builtInNames.includes(name)) {
      loadPreset(name,presets[name],blend,automatic);
    } else if (projectmIndexes.has(name)) {
      const ticket=++presetTicket;
      const timeout=setTimeout(() => window.auralisVisuals.deliverPreset(ticket,null),5000);
      pendingPreset={ticket,name,blend,automatic,retry,timeout};
      send({type:'requestPreset',ticket,index:projectmIndexes.get(name)});
    }
  }
  function startSong() {
    song=options.song;
    songInitialized=true;
    cancelPresetRequest();
    if (names.includes(options.preset)) {
      selectPreset(options.preset,0);
    } else if (song) {
      nextPreset(0);
    } else {
      selectPreset(builtInNames[0],0);
    }
  }
  function milkSize() {
    const ratio=Number.isFinite(window.devicePixelRatio) && window.devicePixelRatio>0
      ? window.devicePixelRatio : 1;
    const width=Math.max(1,milk.clientWidth)*ratio;
    const height=Math.max(1,milk.clientHeight)*ratio;
    // Phones start with a smaller budget. Both platforms adapt animated pixels
    // under frame pressure, independently of the Spectrum and its labels.
    const edge=options.mobile?1120:4096, pixels=options.mobile?640000:8388608;
    const scale=Math.min(1,edge/Math.max(width,height),Math.sqrt(pixels/(width*height)))*qualityScale;
    return [Math.max(1,Math.round(width*scale)),Math.max(1,Math.round(height*scale))];
  }
  function ensureMilk() {
    if (visualizer) return;
    if (typeof butterchurn==='undefined') library('butterchurn');
    ensurePresets();
    const [width,height]=milkSize();
    milk.width=width;milk.height=height;
    visualizer = butterchurn.default.createVisualizer(null, milk, {
      width,height,
      pixelRatio:1, textureRatio:options.mobile?.8:1,
    });
    installEnergyResponse();
    startSong();
  }
  function loadPreset(name,source,blend,automatic=false) {
    if (!source) throw Error('No visualizer presets are installed.');
    const variation=hash(`${song}:${options.variation}:${take++}:${name}`)/0x100000000;
    if (visualizer) {
      // Keep every original equation/shader/layer. A copied per-frame equation
      // adds a bounded feedback kick and waveform response even in presets
      // whose authored motion mostly ignores audio. Never edit vendor assets.
      const preset={
        ...source,baseVals:{...source.baseVals},
        shapes:(source.shapes||[]).map(item=>({...item,baseVals:{...item.baseVals}})),
        waves:(source.waves||[]).map(item=>({...item,baseVals:{...item.baseVals}})),
      };
      if (options.songMotion && typeof source.frame_eqs_str==='string') {
        preset.frame_eqs_str=`
          const __auralisKick=Math.min(1,Math.max(0,a.bass-a.bass_att));
          const __auralisEnergy=Math.min(1.5,Math.max(0,(a.bass_att+a.mid_att+a.treb_att)/3));
          ${source.frame_eqs_str}
          if(Number.isFinite(a.zoom)) a.zoom*=1+${.009+variation*.021}*__auralisKick;
          if(Number.isFinite(a.wave_scale)) a.wave_scale*=.9+${.14+variation*.16}*__auralisEnergy+.35*__auralisKick;
          if(Number.isFinite(a.warp)) a.warp+=${.02+variation*.07}*__auralisKick;
          if(Number.isFinite(a.rot)) a.rot+=${(variation-.5)*.045}*__auralisEnergy;
        `;
      }
      visualizer.loadPreset(preset,blend);
      if (projectmIndexes.has(name) && (preset.warp || preset.comp)) {
        const renderer=visualizer.renderer;
        for (const shader of [renderer.warpShader,renderer.compShader]) {
          if (!renderer.gl.getProgramParameter(shader.shaderProgram,renderer.gl.LINK_STATUS))
            throw Error('The preset shader could not be linked');
        }
      }
    }
    activePreset=name;
    activeSource=source;
    lastCycle=performance.now();
    blendElapsed=0;
    blendDuration=blend*1000;
    sectionAudioMs=sectionShiftMs=0;
    send(automatic?{type:'preset',name,rotationPosition}:{type:'preset',name});
  }
  function resize() {
    if (analyzer && options.mode==='spectrum') {
      // CSS size is independent of the low-resolution drawing buffer. Refresh
      // immediately when switching modes or expanding, not only on debounce.
      analyzer.setCanvasSize(Math.max(1,spectrum.clientWidth),Math.max(1,spectrum.clientHeight));
    }
    if (visualizer && options.mode==='visualizer') {
      const [renderWidth,renderHeight]=milkSize();
      // Butterchurn sizes its render targets, not the supplied canvas element.
      // Keep the visible drawing buffer in the same aspect as the CSS panel.
      if (milk.width===renderWidth && milk.height===renderHeight) return;
      milk.width=renderWidth;
      milk.height=renderHeight;
      visualizer.setRendererSize(renderWidth,renderHeight);
    }
  }
  function resizeDisplay() {
    // Display changes can move this view to a different refresh rate. Quality
    // changes call resize() directly so they retain the measured cadence.
    refreshInterval=1000/60;
    lastRaf=0;cadenceTotal=0;cadenceSamples=0;
    resize();
  }
  function clearWaveform() {
    if (silent) return;
    waveform.fill(128);
    silent=true;
    audioRevision++;
  }
  function stop() {
    cancelAnimationFrame(request);request=0;
    if (analyzer) analyzer.stop();
    clearWaveform();smooth.fill(-100);lastAudio=-Infinity;
    energyRms=0;lastEnergyRender=0;bandRms.fill(0);bandAverage.fill(0);bandRelease.fill(0);
    previousMagnitude.fill(0);flux.fill(0);impulses.fill(0);impulseAt.fill(-Infinity);
    outputEnergy=0;outputPulse=0;
    sectionAudioMs=sectionShiftMs=0;
    // Keep the last displayed frame when paused; histories reset so it cannot
    // produce a stale beat on resume.
    if (!options.songMotion) {
      milk.style.opacity=lastOpacity='1';milk.style.transform=lastTransform='none';
    }
    lastBeat=-Infinity;energyAverage=0;bassAverage=0;highAverage=0;
    qualityAt=performance.now();qualityFrames=0;slowFrames=0;lastDraw=0;
    lastRaf=0;cadenceTotal=0;cadenceSamples=0;
  }
  function adapt(time,cost,elapsed) {
    // A high frame limit on a slower display cannot outrun its refresh rate.
    const budget=Math.max(1000/options.fps,refreshInterval);
    qualityFrames++;
    if (cost>budget*.75 || (elapsed>0 && elapsed>budget*1.7)) slowFrames++;
    if (time-qualityAt<2500 || qualityFrames<20) return;
    let next=qualityScale;
    if (slowFrames/qualityFrames>.25) next=Math.max(.5,qualityScale*.85);
    else if (slowFrames/qualityFrames<.05) next=Math.min(1,qualityScale+.05);
    qualityAt=time;qualityFrames=0;slowFrames=0;
    if (Math.abs(next-qualityScale)>.001) { qualityScale=next;resize(); }
  }
  function loop(time) {
    if (!options.active || destroyed) return;
    request=requestAnimationFrame(loop);
    const cadence=time-lastRaf;
    if (lastRaf && cadence>=4) {
      cadenceTotal+=cadence;
      if (++cadenceSamples===8) {
        refreshInterval=Math.min(refreshInterval,cadenceTotal/cadenceSamples);
        cadenceTotal=0;cadenceSamples=0;
      }
    }
    lastRaf=time;
    const interval=1000/options.fps, elapsed=time-lastFrame;
    if (elapsed+.5<interval) return;
    // Preserve the pacing phase instead of dropping to ~20 FPS when a 30 FPS
    // frame arrives a fraction of a millisecond before its nominal deadline.
    lastFrame+=Math.max(1,Math.floor((elapsed+.5)/interval))*interval;
    try {
      if (!activePreset) return;
      if (time-lastAudio>250) clearWaveform();
      const onBeat=time-lastBeat<120;
      if (options.cycle && !pendingPreset) {
        if (options.songMotion) {
          if (sectionAudioMs>=sectionMinAudioMs && sectionShiftMs>=sectionHoldMs &&
              time-lastAudio<=120 && energyRms>=.012) {
            nextPreset(options.mobile?1:1.35);
          }
        } else {
          const due=options.cycleSeconds*1000;
          if (time-lastCycle>due && (onBeat || time-lastCycle>due+1500)) {
            nextPreset(onBeat?(options.mobile?.2:.35):options.mobile?.42:1.2);
          }
        }
      }
      const started=performance.now();
      const elapsedTime=Math.min(.1,Math.max(.001,
        (lastDraw?time-lastDraw:interval)/1000));
      // Explicit positive frame time also avoids Butterchurn's zero-delta
      // FPS singularity when a first frame shares its creation timestamp.
      visualizer.render({elapsedTime,audioLevels:{
        timeByteArray:waveform,timeByteArrayL:waveform,timeByteArrayR:waveform,
      }});
      adapt(time,performance.now()-started,lastDraw?time-lastDraw:0);
      lastDraw=time;
    } catch (error) {
      if (projectmIndexes.has(activePreset)) {
        unavailablePresets.add(activePreset);
        cancelPresetRequest();
        try { selectPreset(builtInNames[0],0); }
        catch (_) { fail(error); }
      } else fail(error);
    }
  }
  window.auralisVisuals = {
    addPresetNames(chunk) {
      for (const name of chunk) projectmIndexes.set(name,projectmIndexes.size);
      names=[...builtInNames,...projectmIndexes.keys()];
      orderRound=-1;
    },
    clearPresetNames() {
      projectmIndexes.clear();
      names=builtInNames.slice();
      orderRound=-1;
    },
    usePresetRotation(seed,position) {
      rotationSeed=seed;
      rotationPosition=position;
      orderRound=-1;
    },
    deliverPreset(ticket,source) {
      if (destroyed || pendingPreset?.ticket!==ticket) return;
      const {name,blend,automatic,retry}=pendingPreset;
      cancelPresetRequest();
      try {
        if (!source || typeof source!=='object') throw Error('Preset data unavailable');
        loadPreset(name,source,blend,automatic);
      } catch (_) {
        unavailablePresets.add(name);
        // Recover the previous renderer state if a shader failed during load.
        try {
          if (activeSource) loadPreset(activePreset,activeSource,0);
        } catch (error) {
          fail(error);
          return;
        }
        if (automatic && retry<3) nextPreset(blend,retry+1);
        else if (!activeSource) selectPreset(builtInNames[0],0);
      }
    },
    configure(next) {
      try {
        const previous=options;
        options={...options,...next};
        if (!['spectrum','visualizer'].includes(options.mode)) throw Error('Invalid mode');
        options.fps=frameLimits.includes(options.fps)?options.fps:30;
        options.cycleSeconds=[15,30,60].includes(options.cycleSeconds)?options.cycleSeconds:30;
        const modeChanged=options.mode!==previous.mode;
        const activityChanged=options.active!==previous.active;
        const songChanged=options.song!==previous.song;
        if (options.cycle!==previous.cycle) {
          sectionAudioMs=sectionShiftMs=0;
          lastCycle=performance.now();
        }
        if (songChanged && !Object.prototype.hasOwnProperty.call(next,'preset')) options.preset='';
        if (modeChanged || activityChanged || songChanged) stop();
        if (!options.songMotion && previous.songMotion)
          updateSongMotion(0,0,0);
        milk.style.display=options.mode==='visualizer'?'block':'none';
        spectrum.style.display=options.mode==='spectrum'?'block':'none';
        if (options.mode==='visualizer') {
          ensureMilk();
          if (!songInitialized || song!==options.song) {
            startSong();
          } else if (next.preset && next.preset!==activePreset) {
            selectPreset(next.preset,0);
          } else if (options.songMotion!==previous.songMotion && activeSource && !pendingPreset) {
            selectPreset(activePreset,0);
          }
        } else {
          cancelPresetRequest();
          songInitialized=false;
          ensureSpectrum();
          analyzer.setOptions({
            mode:2,radial:false,radialInvert:false,mirror:0,ledBars:false,barSpace:.1,
            outlineBars:false,alphaBars:false,peakLine:false,showPeaks:true,
            reflexRatio:0,fillAlpha:.2,lineWidth:1.5,roundBars:true,
            ...spectrumStyles[options.spectrum],gradient:options.palette,maxFPS:options.fps,
            loRes:options.mobile,
          });
        }
        resize();
        status.style.display='none';
        if (options.active) {
          if (options.fps!==previous.fps) lastFrame=performance.now()-1000/options.fps;
          if (modeChanged || activityChanged || songChanged) {
            lastCycle=performance.now();
            lastFrame=lastCycle-1000/options.fps;
          }
          if (options.mode==='spectrum') analyzer.start();
          else if (!request) request=requestAnimationFrame(loop);
        }
      } catch (error) { fail(error); }
    },
    feed(encoded,rate) {
      if (!options.active || destroyed || !Number.isFinite(rate) || rate<8000 || rate>192000) return;
      const bytes=atob(encoded);
      if (bytes.length<128 || bytes.length>4096) return;
      // Native capture is mono 8-bit unsigned. Resample to the engines' 44.1 kHz.
      for (let i=0;i<1024;i++) {
        const source=bytes.length-1-(1023-i)*rate/44100;
        waveform[i]=source<0?128:bytes.charCodeAt(Math.min(bytes.length-1,Math.round(source)));
      }
      const time=performance.now();
      audioRevision++;
      silent=false;
      fft();
      if (options.mode==='visualizer') react(time);
      lastAudio=time;
    },
    step(direction) {
      try {
        ensureMilk();
        if (direction===0) nextPreset(options.mobile?.42:1.2);
        else {
          const current=names.indexOf(pendingPreset?.name || activePreset);
          const next=(current+direction+names.length)%names.length;
          selectPreset(names[next],options.mobile?.42:1.2);
        }
      } catch (error) { fail(error); }
    },
    destroy() {
      destroyed=true;options.active=false;stop();
      cancelPresetRequest();
      if (analyzer) analyzer.destroy();
      if (audioContext) audioContext.close().catch(()=>{});
      const gl=milk.getContext('webgl2') || milk.getContext('webgl');
      if (gl) gl.getExtension('WEBGL_lose_context')?.loseContext();
      visualizer=null;analyzer=null;resizeObserver.disconnect();
      window.removeEventListener('resize',resizeDisplay);
    },
  };
  const resizeObserver=new ResizeObserver(resizeDisplay);
  resizeObserver.observe(document.getElementById('surface'));
  window.addEventListener('resize',resizeDisplay);
  document.addEventListener('visibilitychange',()=>{
    // Desktop occlusion/focus loss is not a user-requested stop. Flutter/native
    // window lifecycle still stops desktop capture/rendering on minimization.
    if (document.hidden && options.mobile) stop();
  });
  milk.addEventListener('webglcontextlost',event=>{
    event.preventDefault();fail(Error('The GPU context was lost. Please retry.'));
  });
  window.addEventListener('pagehide',()=>window.auralisVisuals.destroy());
  send({type:'ready',presets:names});
})();
