// Opens render.html in headless Chrome over the DevTools protocol, waits for the offline
// renders, and writes each cue as raw float32 to <outdir>/<name>.f32.
// Usage: node cdp-render.mjs <render.html> <outdir>
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const [page, outdir] = process.argv.slice(2);
mkdirSync(outdir, { recursive: true });
const port = 9333;
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
  "--headless=new", "--disable-gpu", "--no-first-run", `--remote-debugging-port=${port}`,
  `--user-data-dir=${outdir}/../chrome-profile-cdp`, "about:blank",
], { stdio: "ignore" });

try {
  let targets;
  for (let i = 0; i < 50; i++) {
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); break; } catch { await sleep(200); }
  }
  const tab = targets.find((t) => t.type === "page");
  const ws = new WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r, { once: true }));
  let id = 0;
  const pending = new Map();
  ws.addEventListener("message", (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  });
  const send = (method, params = {}) => new Promise((resolve) => {
    const mid = ++id; pending.set(mid, resolve); ws.send(JSON.stringify({ id: mid, method, params }));
  });
  const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, returnByValue: true })).result?.result?.value;

  await send("Page.enable");
  await send("Page.navigate", { url: "file://" + page });
  let status = "";
  for (let i = 0; i < 100; i++) {
    await sleep(200);
    status = await evaluate(`document.getElementById("out") ? document.getElementById("out").textContent.slice(0, 3) : ""`);
    if (status === "OK{" || status?.startsWith("ERR")) break;
  }
  if (status !== "OK{") {
    console.log("status", status, await evaluate(`document.getElementById("st").textContent`),
      await evaluate(`document.getElementById("out").textContent.slice(0, 400)`));
    process.exitCode = 1;
  } else {
    const names = await evaluate(`Object.keys(JSON.parse(document.getElementById("out").textContent.slice(2)))`);
    for (const name of names) {
      const b64 = await evaluate(`JSON.parse(document.getElementById("out").textContent.slice(2))[${JSON.stringify(name)}]`);
      writeFileSync(`${outdir}/${name}.f32`, Buffer.from(b64, "base64"));
      console.log("wrote", name);
    }
  }
  ws.close();
} finally {
  chrome.kill();
}
