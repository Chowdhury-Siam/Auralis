/* Auralis output-waveform bridge. No microphone, media URL, socket or network.
 * Butterchurn's documented audioLevels input consumes the native waveform.
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
  let options = {mode:'spectrum', spectrum:'line', palette:'prism',
    fps:30, cycle:true, cycleSeconds:30, preset:'', active:false};
  const waveform = new Uint8Array(1024).fill(128);
  const real = new Float64Array(1024), imag = new Float64Array(1024);
  const decibels = new Float32Array(512).fill(-100);
  const smooth = new Float32Array(512).fill(-100);
  const presets = butterchurnPresets.getPresets();
  const names = Object.keys(presets).filter(name =>
    name !== 'Flexi + Martin - astral projection');
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
      real[i] = ((waveform[i]-128)/128-mean) * (.5-.5*Math.cos(2*Math.PI*i/1023));
      imag[i] = 0;
    }
    for (let i=1,j=0;i<1024;i++) {
      let bit = 512;
      for (;j&bit;bit>>=1) j ^= bit;
      j ^= bit;
      if (i<j) { const x=real[i];real[i]=real[j];real[j]=x; }
    }
    for (let size=2;size<=1024;size*=2) {
      const half=size/2;
      for (let start=0;start<1024;start+=size) for (let j=0;j<half;j++) {
        const angle=-2*Math.PI*j/size, c=Math.cos(angle), s=Math.sin(angle);
        const k=start+j, l=k+half;
        const r=real[l]*c-imag[l]*s, v=real[l]*s+imag[l]*c;
        real[l]=real[k]-r;imag[l]=imag[k]-v;real[k]+=r;imag[k]+=v;
      }
    }
    for (let i=0;i<512;i++) {
      decibels[i]=Math.max(-100,20*Math.log10(Math.max(1e-8,Math.hypot(real[i],imag[i])/256)));
      smooth[i]=smooth[i]*.55+decibels[i]*.45;
    }
  }
  function ensureSpectrum() {
    if (analyzer) return;
    audioContext = new (window.AudioContext || window.webkitAudioContext)({sampleRate:44100});
    analyzer = new AudioMotionAnalyzer(spectrum, {
      audioCtx:audioContext, connectSpeakers:false, start:false, fftSize:1024,
      overlay:true, showBgColor:false, bgAlpha:0, maxFPS:options.fps,
      minFreq:30, maxFreq:16000, minDecibels:-85, maxDecibels:-10,
      showScaleX:true, showPeaks:true, smoothing:.5, loRes:true,
    });
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
  function ensureMilk() {
    if (visualizer) return;
    visualizer = butterchurn.default.createVisualizer(null, milk, {
      width:Math.max(1,milk.clientWidth), height:Math.max(1,milk.clientHeight),
      pixelRatio:1, textureRatio:1,
    });
    loadPreset(options.preset || names[0], 0);
  }
  function loadPreset(name, blend=1.2) {
    if (!names.length) throw Error('No visualizer presets are installed.');
    const found=names.indexOf(name);
    presetIndex=found<0?0:found;
    if (visualizer) visualizer.loadPreset(presets[names[presetIndex]],blend);
    lastCycle=performance.now();
    send({type:'preset',name:names[presetIndex]});
  }
  function resize() {
    if (visualizer) {
      // Bound GPU work on high-DPI phones and large desktop windows.
      const width=Math.max(1,milk.clientWidth), height=Math.max(1,milk.clientHeight);
      const scale=Math.min(1,960/Math.max(width,height));
      visualizer.setRendererSize(Math.round(width*scale),Math.round(height*scale));
    }
  }
  function stop() {
    cancelAnimationFrame(request);request=0;
    if (analyzer) analyzer.stop();
    waveform.fill(128);decibels.fill(-100);smooth.fill(-100);
  }
  function loop(time) {
    if (!options.active || destroyed) return;
    request=requestAnimationFrame(loop);
    if (time-lastFrame<1000/options.fps) return;
    lastFrame=time;
    try {
      if (time-lastAudio>250) { waveform.fill(128);fft(); }
      if (options.mode==='visualizer') {
        if (options.cycle && time-lastCycle>options.cycleSeconds*1000) {
          loadPreset(names[(presetIndex+1)%names.length]);
        }
        visualizer.render({audioLevels:{
          timeByteArray:waveform,timeByteArrayL:waveform,timeByteArrayR:waveform,
        }});
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
          if (options.preset && options.preset!==previous.preset) loadPreset(options.preset);
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
      lastAudio=performance.now();
      fft();
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
    },
  };
  const resizeObserver=new ResizeObserver(resize);
  resizeObserver.observe(document.getElementById('surface'));
  document.addEventListener('visibilitychange',()=>{
    if (document.hidden) stop(); // Flutter explicitly resumes only when foreground.
  });
  milk.addEventListener('webglcontextlost',event=>{
    event.preventDefault();fail(Error('The GPU context was lost. Please retry.'));
  });
  window.addEventListener('pagehide',()=>window.auralisVisuals.destroy());
  send({type:'ready',presets:names});
})();
