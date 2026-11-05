// Bundles sensory-ui's synthesis TS into one inline script for an offline render page.
// Usage: node bundle.mjs <sounds-dir> <out.html>
import { readFileSync, writeFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { join } from "node:path";

const [dir, out] = process.argv.slice(2);
const files = ["core/effects.ts", "core/instruments.ts", "core/tunes.ts", "core/factory.ts", "core/pack-generator.ts"];
let code = "";
for (const f of files) {
  let src = stripTypeScriptTypes(readFileSync(join(dir, f), "utf8"), { mode: "strip" });
  src = src.replace(/^\s*import[\s\S]*?;[ \t]*$/gm, "");
  src = src.replace(/^export \* from .*$/gm, "");
  src = src.replace(/^export \{[^}]*\}.*$/gm, "");
  src = src.replace(/^export (default )?/gm, "");
  code += `\n// ---- ${f}\n` + src;
}

const page = `<!doctype html><html><body><pre id="out">pending</pre><pre id="st">S0</pre><script>
const st = (m) => { document.getElementById("st").textContent += " " + m; };
window.addEventListener("error", (e) => st("WINERR " + e.message));
// Seeded random so the reverb impulse response is the same on every render.
(function () { let s = 0x5EED1234 >>> 0; Math.random = function () {
  s = (s + 0x6D2B79F5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; })();
${code}
const softEffects = [{ type: "reverb", options: { duration: 0.8, decay: 2.5, mix: 0.2 } }];
const tightEffects = [{ type: "reverb", options: { duration: 0.4, decay: 3, mix: 0.12 } }];
const soft = generateCustomSoundPack({ ...SOFT_INSTRUMENT, effects: softEffects }, {},
  { "notification.error": { frequency: 200, endFrequency: 80, filterFreq: 600, filterQ: 1, duration: 0.25,
    meta: { endFilterFreq: 200, tonalGain: 0.5 } } });
const tight = generateCustomSoundPack({ ...SOFT_INSTRUMENT, effects: tightEffects });
const plan = [
  ["send", tight, "navigation.forward"], ["reply_done", soft, "notification.info"],
  ["task_done", soft, "notification.success"], ["error", soft, "notification.error"],
  ["attention", soft, "notification.warning"], ["rec_start", tight, "overlay.open"],
  ["rec_stop", tight, "overlay.close"], ["toggle", tight, "interaction.toggle"],
  ["trash", tight, "overlay.collapse"], ["copy", tight, "navigation.tab"],
];
st("S1");
const SR = 44100;
function toBase64(f32) {
  const bytes = new Uint8Array(f32.buffer);
  let bin = ""; for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}
(async () => {
  const result = {};
  try {
    for (const [name, pack, role] of plan) {
      st("R" + name);
      const ctx = new OfflineAudioContext(1, Math.floor(SR * 2.5), SR);
      pack[role](ctx, { volume: 1 });
      st("P" + name);
      const buf = await ctx.startRendering();
      st("D" + name);
      result[name] = toBase64(new Float32Array(buf.getChannelData(0)));
    }
    document.getElementById("out").textContent = "OK" + JSON.stringify(result);
  } catch (e) {
    document.getElementById("out").textContent = "ERR " + (e && e.stack || e);
  }
})();
</script></body></html>`;
writeFileSync(out, page);
console.log("bundled", code.length, "chars");
