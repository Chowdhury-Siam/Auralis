'use strict';

const audioProperty = /\ba\s*(?:\.\s*(?:bass|mid|treb)(?:_att)?\b|\[\s*['"](?:bass|mid|treb)(?:_att)?['"]\s*\])/i;
const waveProperty = /\ba\s*(?:\.\s*value[12]\b|\[\s*['"]value[12]['"]\s*\])/i;
const shaderAudio = /\b(?:bass|mid|treb)(?:_att)?\b/i;

function withoutComments(value) {
  return (typeof value === 'string' ? value : '')
    .replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

// Initializers alone cannot follow a beat once an animation has started.
function inspectPreset(preset) {
  const frame = withoutComments(preset.frame_eqs_str);
  const pixel = withoutComments(preset.pixel_eqs_str);
  const warp = withoutComments(preset.warp).trim();
  const comp = withoutComments(preset.comp).trim();
  const shapes = (preset.shapes ?? []).filter(shape => shape.baseVals?.enabled > 0);
  const waves = (preset.waves ?? []).filter(wave => wave.baseVals?.enabled > 0);
  const base = preset.baseVals ?? {};
  if (!warp && !comp && !shapes.length && !waves.length) {
    const changes = withoutComments(preset.init_eqs_str) + ';' + frame;
    // These fallback values come from the bundled Butterchurn renderer.
    const draws = (field, fallback) => {
      if ((base[field] ?? fallback) > 0) return true;
      const write = new RegExp("\\ba\\s*(?:\\."+field+"\\b|\\[\\s*['\"]"+field+"['\"]\\s*\\])\\s*(?:[+*/-]?=)(?!=)", 'g');
      return Array.from(changes.matchAll(write)).some(match => {
        const expression = changes.slice(match.index + match[0].length).split(';', 1)[0].trim();
        return !/^[-+]?0(?:\.0+)?$/.test(expression);
      });
    };
    const waveform = draws('wave_a', .8);
    const borders = (draws('ob_size', .01) && draws('ob_a', 0)) ||
      (draws('ib_size', .01) && draws('ib_a', 0));
    const vectors = draws('mv_a', 1) && draws('mv_x', 12) && draws('mv_y', 9);
    if (!waveform && !borders && !vectors) return 'No visible drawing layer';
  }
  const volumeModulation = base.modwavealphabyvolume > 0 && (base.wave_a ?? .8) >= .05 &&
    (base.modwavealphaend ?? 1) > (base.modwavealphastart ?? 0);
  if (volumeModulation || audioProperty.test(frame) || audioProperty.test(pixel) ||
      shaderAudio.test(warp) || shaderAudio.test(comp) ||
      shapes.some(shape => audioProperty.test(withoutComments(shape.frame_eqs_str))) ||
      waves.some(wave => audioProperty.test(withoutComments(wave.frame_eqs_str)) ||
        audioProperty.test(withoutComments(wave.point_eqs_str)) ||
        waveProperty.test(withoutComments(wave.point_eqs_str)))) return null;
  return 'No authored beat response';
}

module.exports = inspectPreset;
