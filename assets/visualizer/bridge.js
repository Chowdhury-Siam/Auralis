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
  let lastAudio = -Infinity, lastCycle = 0, presetIndex = 0, destroyed = false;
  let qualityScale=1, qualityAt=0, qualityFrames=0, slowFrames=0, lastDraw=0;
  let lastBeat=-Infinity, energyAverage=0, bassAverage=0, highAverage=0;
  let energyRms=0, lastEnergyRender=0;
  let outputEnergy=0, outputPulse=0;
  const bandRms=new Float32Array(3), bandAverage=new Float32Array(3);
  const bandRelease=new Float32Array(3);
  const previousMagnitude=new Float32Array(512), flux=new Float32Array(3);
  const bandMagnitude=new Float32Array(3), impulses=new Float32Array(3);
  const impulseAt=new Float64Array(3).fill(-Infinity);
  let options = {mode:'spectrum', spectrum:'line', palette:'prism',
    fps:30, cycle:true, cycleSeconds:30, preset:'', active:false, mobile:false,
    songMotion:true};
  const waveform = new Uint8Array(1024).fill(128);
  const real = new Float64Array(1024), imag = new Float64Array(1024);
  const decibels = new Float32Array(512).fill(-100);
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
  let presets, names=[];
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
    names=Object.keys(presets).filter(name => name!=='Flexi + Martin - astral projection');
    send({type:'presets',presets:names});
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
      if (options.mode==='spectrum') {
        decibels[i]=Math.max(-100,10*Math.log10(Math.max(1e-16,power/65536)));
        // Fast attack follows drum hits; slower release keeps the graph readable.
        const weight=decibels[i]>smooth[i]?.85:.3;
        smooth[i]+=weight*(decibels[i]-smooth[i]);
      }
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
        if (novelty>.2) lastBeat=time;
      }
    }
    const attack=Math.max(energy/(energyAverage+.008),bass/(bassAverage+.004),
      high/(highAverage+.008));
    if (energy>.012 && attack>1.35 && time-lastBeat>120) {
      lastBeat=time;
    }
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
  function installEnergyResponse() {
    // Pinned 2.6.7 adapter: its stock long-average ratios flatten sustained
    // loud/quiet sections and eventually return 1 in silence. Keep its complete
    // waveform/spectrum pipeline, but give preset equations measured dynamics.
    const levels=visualizer.renderer?.audioLevels;
    if (!levels || typeof levels.updateAudioLevels!=='function' ||
        levels.val?.length!==3 || levels.att?.length!==3)
      throw Error('Unsupported offline energy adapter');
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
    const opacity=Math.min(1,outputEnergy*(.84+.16*outputPulse));
    // At most 3.5% outward movement, never shrink/reveal unpainted edges.
    milk.style.opacity=opacity.toFixed(4);
    milk.style.transform=`scale(${(1+.035*outputPulse).toFixed(5)})`;
  }
  function ensureSpectrum() {
    if (analyzer) return;
    if (typeof AudioMotionAnalyzer==='undefined') library('audiomotion');
    audioContext = new (window.AudioContext || window.webkitAudioContext)({sampleRate:44100});
    analyzer = new AudioMotionAnalyzer(spectrum, {
      audioCtx:audioContext, connectSpeakers:false, start:false, fftSize:1024,
      overlay:true, showBgColor:false, bgAlpha:0, maxFPS:options.fps,
      minFreq:30, maxFreq:16000, minDecibels:-85, maxDecibels:-10,
      showScaleX:true, showPeaks:true, smoothing:.5, loRes:false,
    });
    // Samples come from native output capture, not a Web Audio graph.
    audioContext.suspend().catch(()=>{});
    // Pinned library adapter. The graph remains disconnected from speakers.
    for (const node of analyzer._analyzer) {
      node.getFloatFrequencyData = target => {
        for (let i=0;i<target.length;i++) {
          const source = i * audioContext.sampleRate / 44100;
          target[i] = smooth[Math.min(511,Math.round(source))];
        }
      };
    }
  }
  function milkSize() {
    const ratio=Number.isFinite(window.devicePixelRatio) && window.devicePixelRatio>0
      ? window.devicePixelRatio : 1;
    const width=Math.max(1,milk.clientWidth)*ratio;
    const height=Math.max(1,milk.clientHeight)*ratio;
    // Keep normal phone panels sharp, but do not allocate desktop-sized warp
    // textures on phones. Adapt only animated pixels, never spectrum labels.
    const edge=options.mobile?2048:4096, pixels=options.mobile?2097152:8388608;
    const scale=Math.min(1,edge/Math.max(width,height),Math.sqrt(pixels/(width*height)))*
      (options.mobile?qualityScale:1);
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
      pixelRatio:1, textureRatio:1,
    });
    installEnergyResponse();
    loadPreset(options.preset || names[0], 0);
  }
  function loadPreset(name, blend=1.2) {
    if (!names.length) throw Error('No visualizer presets are installed.');
    const found=names.indexOf(name);
    presetIndex=found<0?0:found;
    if (visualizer) {
      const source=presets[names[presetIndex]];
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
          if(Number.isFinite(a.zoom)) a.zoom*=1+.018*__auralisKick;
          if(Number.isFinite(a.wave_scale)) a.wave_scale*=.9+.2*__auralisEnergy+.35*__auralisKick;
          if(Number.isFinite(a.warp)) a.warp+=.04*__auralisKick;
        `;
      }
      visualizer.loadPreset(preset,blend);
    }
    lastCycle=performance.now();
    send({type:'preset',name:names[presetIndex]});
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
      if (milk.width!==renderWidth) milk.width=renderWidth;
      if (milk.height!==renderHeight) milk.height=renderHeight;
      visualizer.setRendererSize(renderWidth,renderHeight);
    }
  }
  function stop() {
    cancelAnimationFrame(request);request=0;
    if (analyzer) analyzer.stop();
    waveform.fill(128);decibels.fill(-100);smooth.fill(-100);
    energyRms=0;lastEnergyRender=0;bandRms.fill(0);bandAverage.fill(0);bandRelease.fill(0);
    previousMagnitude.fill(0);flux.fill(0);impulses.fill(0);impulseAt.fill(-Infinity);
    outputEnergy=0;outputPulse=0;
    // Keep the last displayed frame when paused; histories reset so it cannot
    // produce a stale beat on resume.
    if (!options.songMotion) {
      milk.style.opacity='1';milk.style.transform='none';
    }
    lastBeat=-Infinity;energyAverage=0;bassAverage=0;highAverage=0;
    qualityAt=performance.now();qualityFrames=0;slowFrames=0;lastDraw=0;
  }
  function adapt(time,cost,elapsed) {
    if (!options.mobile) return;
    const budget=1000/options.fps;
    qualityFrames++;
    if (cost>budget*.75 || (elapsed>0 && elapsed>budget*1.7)) slowFrames++;
    if (time-qualityAt<2500 || qualityFrames<20) return;
    let next=qualityScale;
    if (slowFrames/qualityFrames>.25) next=Math.max(.75,qualityScale*.9);
    else if (slowFrames/qualityFrames<.05) next=Math.min(1,qualityScale+.05);
    qualityAt=time;qualityFrames=0;slowFrames=0;
    if (Math.abs(next-qualityScale)>.001) { qualityScale=next;resize(); }
  }
  function loop(time) {
    if (!options.active || destroyed) return;
    request=requestAnimationFrame(loop);
    const interval=1000/options.fps, elapsed=time-lastFrame;
    if (elapsed+.5<interval) return;
    // Preserve the pacing phase instead of dropping to ~20 FPS when a 30 FPS
    // frame arrives a fraction of a millisecond before its nominal deadline.
    lastFrame+=Math.max(1,Math.floor((elapsed+.5)/interval))*interval;
    try {
      if (time-lastAudio>250) {
        waveform.fill(128);
        if (options.mode==='spectrum') {
          for (let i=0;i<512;i++) smooth[i]+=.3*(-100-smooth[i]);
        }
      }
      if (options.mode==='visualizer') {
        const due=options.cycleSeconds*1000;
        if (options.cycle && time-lastCycle>due &&
            (time-lastBeat<120 || time-lastCycle>due+1500)) {
          loadPreset(names[(presetIndex+1)%names.length],time-lastBeat<120?.35:1.2);
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
      }
    } catch (error) { fail(error); }
  }
  window.auralisVisuals = {
    configure(next) {
      try {
        const previous=options;
        options={...options,...next};
        if (!['spectrum','visualizer'].includes(options.mode)) throw Error('Invalid mode');
        options.fps=[20,30,60].includes(options.fps)?options.fps:30;
        options.cycleSeconds=[15,30,60].includes(options.cycleSeconds)?options.cycleSeconds:30;
        stop();
        milk.style.display=options.mode==='visualizer'?'block':'none';
        spectrum.style.display=options.mode==='spectrum'?'block':'none';
        if (options.mode==='visualizer') {
          ensureMilk();
          if ((options.preset && options.preset!==previous.preset) ||
              options.songMotion!==previous.songMotion)
            loadPreset(options.preset || names[presetIndex]);
        } else {
          ensureSpectrum();
          analyzer.setOptions({
            mode:options.spectrum==='line'?10:2,
            radial:options.spectrum==='radial',
            gradient:options.palette, maxFPS:options.fps,
            reflexRatio:options.spectrum==='line'?.15:0,
            fillAlpha:.2,lineWidth:1.5,roundBars:true,
          });
        }
        resize();
        status.style.display='none';
        if (options.active) {
          lastCycle=performance.now();lastFrame=0;
          if (options.mode==='spectrum') analyzer.start();
          request=requestAnimationFrame(loop);
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
      fft();
      react(time);
      lastAudio=time;
    },
    step(direction) {
      try {
        ensureMilk();
        const next=direction===0?Math.floor(Math.random()*names.length):
          (presetIndex+direction+names.length)%names.length;
        loadPreset(names[next]);
      } catch (error) { fail(error); }
    },
    destroy() {
      destroyed=true;options.active=false;stop();
      if (analyzer) analyzer.destroy();
      if (audioContext) audioContext.close().catch(()=>{});
      const gl=milk.getContext('webgl2') || milk.getContext('webgl');
      if (gl) gl.getExtension('WEBGL_lose_context')?.loseContext();
      visualizer=null;analyzer=null;resizeObserver.disconnect();
      window.removeEventListener('resize',resize);
    },
  };
  const resizeObserver=new ResizeObserver(resize);
  resizeObserver.observe(document.getElementById('surface'));
  window.addEventListener('resize',resize);
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
