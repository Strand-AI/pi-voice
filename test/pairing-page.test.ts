import test from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";

test("native-pairing page emits only its typed setup helper", async () => {
  const sourceFiles = await readdir("public"), emittedFiles = await readdir(process.env.PI_VOICE_TEST_PUBLIC_DIR ?? "dist/public");
  assert.deepEqual(sourceFiles.filter((file) => file.endsWith(".js")), []);
  assert.deepEqual(emittedFiles.filter((file) => file.endsWith(".ts")), []);
  assert.ok(emittedFiles.includes("pairing.js"));
  assert.ok(!emittedFiles.includes("app.js"));
});

test("pairing page presents native setup data without consuming the code or opening voice", async () => {
  const [html, pairing] = await Promise.all([readFile("public/index.html", "utf8"), readFile("public/pairing.ts", "utf8")]);
  for (const id of ["origin", "pairingCode", "copy", "status"]) assert.match(html, new RegExp(`id="${id}"`));
  assert.match(html, /Pair a native client/);
  assert.match(pairing, /new URLSearchParams\(location\.hash\.slice\(1\)\)\.get\("pair"\)/);
  assert.match(pairing, /history\.replaceState/);
  assert.match(pairing, /navigator\.clipboard\.writeText/);
  assert.doesNotMatch(pairing, /fetch\(|WebSocket|getUserMedia|RTCPeerConnection|api\/live|browser-session/);
  assert.doesNotMatch(`${html}\n${pairing}`, /Start voice|Continuous|Push to Talk|oai-events|captions|localStorage|sessionStorage/);
});

test("provider sideband keeps application-owned delegation and reply authority", async () => {
  const live = await readFile("src/live.ts", "utf8");
  assert.doesNotMatch(live, /gpt-6-luna|send_to_pi|response\.event|function_call_output/);
  assert.match(live, /delegation: \{ type: "client" as const \}/);
  assert.match(live, /Delegation policy:/);
  assert.match(live, /Emit a client delegation before answering/);
  assert.match(live, /Remain completely silent for user speech/);
  assert.match(live, /Authorized Pi reply for speech/);
});
