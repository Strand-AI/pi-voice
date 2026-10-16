import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { request } from "node:http";
import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { CompanionGateway, greetingForAgent } from "../src/gateway.js";
import { MAX_RELAY_TEXT_CHARS, type RelayClient, type RelayDelivery, type RelaySession } from "../src/relay.ts";

const TEST_TOKEN = "t".repeat(43);

class FakeSideband extends EventEmitter {
  sent: any[] = []; closed = false; startedReading = 0; handlersReadyAtStart = false; emitStartupOnStart = false;
  send(data: string): void { this.sent.push(JSON.parse(data)); }
  close(): void { this.closed = true; }
  startReading(): void {
    this.startedReading++; this.handlersReadyAtStart = this.listenerCount("message") > 0 && this.listenerCount("close") > 0 && this.listenerCount("error") > 0;
    if (this.emitStartupOnStart) this.emit("message", JSON.stringify({ type: "session.started", session: { instructions: "not retained" } }));
  }
}

class GatewayRelayClient extends EventEmitter implements RelayClient {
  sessionId: string | null = "voice-human-id";
  endpointEpoch: string | null = "voice-human-epoch";
  connected = true;
  sessions: RelaySession[] = [];
  sends: Array<{ target: { id: string; endpointEpoch: string }; options: Record<string, unknown> }> = [];
  async listSessions(): Promise<RelaySession[]> { return this.sessions; }
  async sendExact(target: { id: string; endpointEpoch: string }, options: { text: string; messageId: string; replyTo?: string; expectsReply?: boolean }): Promise<RelayDelivery> {
    this.sends.push({ target, options });
    return { id: options.messageId, delivered: true, delivery: "socket_delivered", retryable: false, outcomeKnown: true };
  }
}

class LifecycleRelayClient extends EventEmitter implements RelayClient {
  sessionId: string | null = null; endpointEpoch: string | null = null; connected = true; sessions: RelaySession[] = []; timeline: string[] = []; failActivation = false;
  async listSessions(): Promise<RelaySession[]> { this.timeline.push("list"); return this.sessions; }
  async activateHuman(generation: string): Promise<{ id: string; endpointEpoch: string }> { this.timeline.push("activate"); if (this.failActivation) throw new Error("activation_failed"); this.sessionId = `human-${generation}`; this.endpointEpoch = `epoch-${generation}`; return { id: this.sessionId, endpointEpoch: this.endpointEpoch }; }
  async deactivateHuman(): Promise<void> { this.timeline.push("deactivate"); this.sessionId = null; this.endpointEpoch = null; }
  async sendExact(_target: { id: string; endpointEpoch: string }, options: { messageId: string }): Promise<RelayDelivery> { return { id: options.messageId, delivered: true, delivery: "socket_delivered", retryable: false, outcomeKnown: true }; }
}

const builtPublicDir = () => resolve(process.env.PI_VOICE_TEST_PUBLIC_DIR ?? "dist/public");
async function setup(extra = {}) {
  const dir = await mkdtemp(join(tmpdir(), "companion-test-"));
  const gateway = new CompanionGateway({ port: 0, publicDir: builtPublicDir(), token: TEST_TOKEN, deviceStoreFile: join(dir, "devices.json"), ...extra });
  await gateway.start();
  return { gateway, dir, base: `http://localhost:${gateway.port}` };
}
function api(base: string, path: string, init: RequestInit = {}) {
  return fetch(base + path, { ...init, headers: { authorization: `Bearer ${TEST_TOKEN}`, origin: base, "content-type": "application/json", ...init.headers } });
}
function responseCookies(response: Response): { header: string; device: string; session: string } {
  const values = response.headers.getSetCookie(), pairs = values.map((value) => value.split(";", 1)[0]!);
  return { header: pairs.join("; "), device: pairs.find((value) => /pi_voice_device=/.test(value)) ?? "", session: pairs.find((value) => /pi_voice_session=/.test(value)) ?? "" };
}
async function pairBrowser(base: string, name = "Test browser"): Promise<{ body: any; cookies: ReturnType<typeof responseCookies> }> {
  const issued = await api(base, "/api/browser-pairing", { method: "POST" }), pairingToken = ((await issued.json()) as any).pairingToken;
  const response = await fetch(`${base}/api/browser-session/pair`, { method: "POST", headers: { origin: base, "content-type": "application/json" }, body: JSON.stringify({ pairingToken, deviceName: name }) });
  return { body: await response.clone().json(), cookies: responseCookies(response) };
}
async function waitFor<T>(fn: () => T | undefined, timeout = 2000): Promise<T> {
  const start = Date.now(); while (Date.now() - start < timeout) { const value = fn(); if (value !== undefined) return value; await new Promise((r) => setTimeout(r, 10)); } throw new Error("timed out");
}
async function openBrowserWs(gateway: CompanionGateway, base: string, cookie: string): Promise<{ ws: WebSocket; connectionId: string; events: any[] }> {
  const ws = new WebSocket(`ws://localhost:${gateway.port}/ws`, { origin: base, headers: { cookie } }), events: any[] = [];
  ws.on("message", (data) => events.push(JSON.parse(data.toString())));
  await new Promise<void>((resolve, reject) => { ws.once("open", resolve); ws.once("error", reject); });
  const event = await waitFor(() => events.find((value) => value.type === "voice_connection"));
  assert.match(event.connectionId, /^[A-Za-z0-9_-]{22}$/);
  return { ws, connectionId: event.connectionId, events };
}

test("authenticated browser transport has no root-bearer WebSocket or obsolete bridge/artifact routes", async (t) => {
  const { gateway, base } = await setup(); t.after(() => gateway.stop());
  assert.equal((await fetch(`${base}/api/relay`, { headers: { origin: base } })).status, 401);
  assert.equal((await api(base, "/api/send", { method: "POST", body: "{}" })).status, 404);
  assert.equal((await api(base, "/api/artifacts/removed")).status, 404);
  const wsStatus = await new Promise<number>((resolve) => { const ws = new WebSocket(`ws://localhost:${gateway.port}`, [`companion-auth.${TEST_TOKEN}`], { origin: base }); ws.on("unexpected-response", (_req, res) => resolve(res.statusCode!)); ws.on("error", () => undefined); });
  assert.equal(wsStatus, 403);
});

test("device-linked short session is bounded, origin-safe, renewable, and WebSocket-capable", async (t) => {
  let now = 10_000;
  const { gateway, base } = await setup({ now: () => now, browserSessionTtlMs: 1_000, maxBrowserSessions: 1 }); t.after(() => gateway.stop());
  assert.equal((await fetch(`${base}/api/browser-session`, { method: "POST", headers: { origin: base } })).status, 401);
  assert.equal((await fetch(`${base}/api/browser-session`, { method: "POST", headers: { origin: "http://evil.invalid", authorization: `Bearer ${TEST_TOKEN}` } })).status, 403);
  assert.equal((await fetch(`${base}/api/browser-session`, { method: "POST", headers: { origin: base, authorization: `Bearer ${TEST_TOKEN}` } })).status, 404, "there is no root-to-browser session bootstrap");
  const paired = await pairBrowser(base), cookie = paired.cookies.header;
  assert.equal((await fetch(`${base}/api/relay`, { headers: { origin: base, cookie } })).status, 503, "cookie reaches configured auth boundary");
  const ws = new WebSocket(`ws://localhost:${gateway.port}/ws`, { origin: base, headers: { cookie } });
  await new Promise<void>((resolve, reject) => { ws.once("open", resolve); ws.once("error", reject); }); ws.close();
  const replacement = await fetch(`${base}/api/browser-session/renew`, { method: "POST", headers: { origin: base, cookie: paired.cookies.device, "content-type": "application/json" }, body: "{}" }), replacementCookie = responseCookies(replacement).session;
  assert.equal((await fetch(`${base}/api/relay`, { headers: { origin: base, cookie } })).status, 401, "bounded map evicts oldest session");
  now += 1_001;
  assert.equal((await fetch(`${base}/api/relay`, { headers: { origin: base, cookie: replacementCookie } })).status, 401, "expired session is rejected");
});

test("one-use browser pairing is bearer-issued, origin-bound, bounded, and expiring", async (t) => {
  let now = 20_000; const { gateway, base } = await setup({ now: () => now, browserPairingTtlMs: 1_000, maxBrowserPairings: 2 }); t.after(() => gateway.stop());
  const issue = async () => { const response = await fetch(`${base}/api/browser-pairing`, { method: "POST", headers: { origin: base, authorization: `Bearer ${TEST_TOKEN}` } }); assert.equal(response.status, 201); assert.equal(response.headers.get("cache-control"), "no-store"); return await response.json() as { pairingToken: string; expiresAt: number }; };
  assert.equal((await fetch(`${base}/api/browser-pairing`, { method: "POST", headers: { origin: base, cookie: "pi_voice_session=fake" } })).status, 401, "only the operator bearer can issue a pairing");
  const first = await issue(), second = await issue(), third = await issue(); assert.match(second.pairingToken, /^[A-Za-z0-9_-]{32}$/); assert.equal(second.expiresAt, now + 1_000);
  const redeem = (pairingToken: string, origin = base) => fetch(`${base}/api/browser-session/pair`, { method: "POST", headers: { origin, "content-type": "application/json" }, body: JSON.stringify({ pairingToken }) });
  assert.equal((await redeem(first.pairingToken)).status, 401, "bounded issuer evicts the oldest unused pairing");
  assert.equal((await redeem(second.pairingToken, "http://evil.invalid")).status, 403, "origin rejection happens before token consumption");
  const paired = await redeem(second.pairingToken); assert.equal(paired.status, 201);
  const setCookies = paired.headers.getSetCookie(), cookie = setCookies.map((value) => value.split(";", 1)[0]).join("; ");
  assert.equal(setCookies.length, 2); assert.match(setCookies[0]!, /^pi_voice_device=[A-Za-z0-9_-]{43}/); assert.match(setCookies[1]!, /^pi_voice_session=/);
  const pairBody = await paired.json() as any; assert.equal(pairBody.device.origin, base); assert.equal(pairBody.device.status, "active"); assert.equal(pairBody.policy.idleTtlMs, 90 * 24 * 60 * 60_000); assert.ok(pairBody.sessionExpiresAt - now <= 60 * 60_000); assert.doesNotMatch(JSON.stringify(pairBody), /credential/i);
  assert.equal((await redeem(second.pairingToken)).status, 401, "pairing is consumed exactly once");
  assert.equal((await fetch(`${base}/api/relay`, { headers: { origin: base, cookie } })).status, 503, "paired session authorizes refresh APIs");
  const current = await fetch(`${base}/api/browser-device`, { headers: { origin: base, cookie } }); assert.equal(current.status, 200); assert.equal(((await current.json()) as any).device.id, pairBody.device.id);
  now += 1_001; assert.equal((await redeem(third.pairingToken)).status, 401, "unused pairing expires");
});

test("durable device credential renews a short session after gateway restart and remains exact-origin pinned", async () => {
  const stateDir = await mkdtemp(join(tmpdir(), "pi-voice-device-restart-")), deviceStoreFile = join(stateDir, "devices.json");
  const first = await setup({ deviceStoreFile });
  const issued = await api(first.base, "/api/browser-pairing", { method: "POST" }), pairingToken = ((await issued.json()) as any).pairingToken as string;
  const paired = await fetch(`${first.base}/api/browser-session/pair`, { method: "POST", headers: { origin: first.base, "content-type": "application/json" }, body: JSON.stringify({ pairingToken, deviceName: "Restart phone" }) });
  const cookies = responseCookies(paired); assert.ok(cookies.device); await first.gateway.stop();

  const second = await setup({ port: first.gateway.port, deviceStoreFile });
  try {
    const renewed = await fetch(`${second.base}/api/browser-session/renew`, { method: "POST", headers: { origin: second.base, cookie: cookies.device, "content-type": "application/json" }, body: "{}" });
    assert.equal(renewed.status, 201); const renewedCookies = responseCookies(renewed); assert.ok(renewedCookies.session); assert.equal(renewedCookies.device, "", "renewal never exposes or rotates the durable credential");
    assert.equal((await fetch(`${second.base}/api/relay`, { headers: { origin: second.base, cookie: renewedCookies.session } })).status, 503);
    const wrongBase = `http://127.0.0.1:${second.gateway.port}`;
    const wrong = await fetch(`${wrongBase}/api/browser-session/renew`, { method: "POST", headers: { origin: wrongBase, cookie: cookies.device, "content-type": "application/json" }, body: "{}" });
    assert.equal(wrong.status, 401); assert.deepEqual(await wrong.json(), { error: "wrong_origin" }); assert.equal(wrong.headers.getSetCookie().length, 0, "wrong origin does not erase a valid exact-origin credential");
  } finally { await second.gateway.stop(); }
});

test("individual device revocation immediately ends only its sessions, WebSocket, and owned voice", async (t) => {
  const relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const sideband = new FakeSideband(), fakeFetch = async () => new Response(JSON.stringify({ session: { id: "live-device" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const pair = async (name: string) => {
    const issued = await api(base, "/api/browser-pairing", { method: "POST" }), pairingToken = ((await issued.json()) as any).pairingToken;
    const response = await fetch(`${base}/api/browser-session/pair`, { method: "POST", headers: { origin: base, "content-type": "application/json" }, body: JSON.stringify({ pairingToken, deviceName: name }) });
    return { body: await response.clone().json() as any, cookies: responseCookies(response) };
  };
  const first = await pair("First phone"), second = await pair("Second phone");
  assert.equal((await fetch(`${base}/api/browser-devices`, { headers: { origin: base, cookie: second.cookies.header } })).status, 401, "device sessions cannot administer devices");
  const listed = await api(base, "/api/browser-devices"); assert.equal(listed.status, 200); assert.doesNotMatch(JSON.stringify(await listed.json()), /credential|hash/i);
  const firstConnection = await openBrowserWs(gateway, base, first.cookies.header), secondConnection = await openBrowserWs(gateway, base, second.cookies.header);
  const firstWs = firstConnection.ws, secondWs = secondConnection.ws;
  const live = await fetch(`${base}/api/live/session`, { method: "POST", headers: { origin: base, cookie: first.cookies.header, "content-type": "application/json" }, body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison", connectionId: firstConnection.connectionId }) }); assert.equal(live.status, 200);
  const firstClosed = new Promise<{ code: number; reason: string }>((resolve) => firstWs.once("close", (code, reason) => resolve({ code, reason: reason.toString() })));
  const revoked = await api(base, "/api/browser-devices/revoke", { method: "POST", body: JSON.stringify({ deviceId: first.body.device.id }) }); assert.equal(revoked.status, 200); assert.equal(((await revoked.json()) as any).device.status, "revoked");
  assert.deepEqual(await firstClosed, { code: 4003, reason: "device_revoked" }); assert.equal(secondWs.readyState, WebSocket.OPEN); assert.equal(sideband.sent.at(-1)?.type, "session.close");
  assert.equal((await fetch(`${base}/api/relay`, { headers: { origin: base, cookie: first.cookies.header } })).status, 401);
  assert.equal((await fetch(`${base}/api/relay`, { headers: { origin: base, cookie: second.cookies.header } })).status, 200);
  assert.equal((await api(base, "/api/browser-devices/revoke", { method: "POST", body: JSON.stringify({ deviceId: first.body.device.id }) })).status, 200, "known revocation is idempotent");
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} })); secondWs.close();
});

test("Live is bound to the exact starting WebSocket and stale sockets cannot close a newer generation", async (t) => {
  const relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const sideband = new FakeSideband(); let providerCalls = 0;
  const fakeFetch = async () => { providerCalls++; return new Response(JSON.stringify({ session: { id: `live-${providerCalls}` }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 }); };
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const paired = await pairBrowser(base, "Bound browser"), oldConnection = await openBrowserWs(gateway, base, paired.cookies.header), ownerConnection = await openBrowserWs(gateway, base, paired.cookies.header);
  t.after(() => { oldConnection.ws.close(); ownerConnection.ws.close(); });
  const start = (connectionId?: string) => fetch(`${base}/api/live/session`, { method: "POST", headers: { origin: base, cookie: paired.cookies.header, "content-type": "application/json" }, body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "liaison", ...(connectionId ? { connectionId } : {}) }) });
  assert.equal((await start()).status, 409); assert.equal((await start("x".repeat(22))).status, 409); assert.equal(providerCalls, 0, "a missing or foreign connection never reaches the provider");
  const started = await start(ownerConnection.connectionId); assert.equal(started.status, 200); assert.equal(providerCalls, 1);
  oldConnection.ws.close(); await new Promise((resolve) => setTimeout(resolve, 30)); assert.equal(sideband.sent.some((event) => event.type === "session.close"), false, "an old same-device socket cannot close the new generation");
  ownerConnection.ws.close(); await waitFor(() => sideband.sent.find((event) => event.type === "session.close"));
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("disconnect during Live startup fences publication and closes the newly created provider session", async (t) => {
  const relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  let markFetchStarted!: () => void, resolveFetch!: (response: Response) => void;
  const fetchStarted = new Promise<void>((resolve) => { markFetchStarted = resolve; }), provider = new Promise<Response>((resolve) => { resolveFetch = resolve; });
  const sideband = new FakeSideband(), fakeFetch = async () => { markFetchStarted(); return await provider; };
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const paired = await pairBrowser(base, "Startup race browser"), connection = await openBrowserWs(gateway, base, paired.cookies.header);
  const starting = fetch(`${base}/api/live/session`, { method: "POST", headers: { origin: base, cookie: paired.cookies.header, "content-type": "application/json" }, body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "liaison", connectionId: connection.connectionId }) });
  await fetchStarted; connection.ws.close(); await new Promise<void>((resolve) => connection.ws.once("close", () => resolve()));
  resolveFetch(new Response(JSON.stringify({ session: { id: "lost-start-live" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 }));
  const response = await starting; assert.equal(response.status, 409); assert.deepEqual(await response.json(), { error: "voice_connection_lost", cleanup: "sideband_close_sent" });
  assert.deepEqual(sideband.sent.at(-1), { type: "session.close" }); assert.equal(sideband.closed, true);
});

test("missed WebSocket pong closes only its bound Live generation within the configured lease", async (t) => {
  const relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const sideband = new FakeSideband(), fakeFetch = async () => new Response(JSON.stringify({ session: { id: "heartbeat-live" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband, wsHeartbeatPingMs: 10, wsHeartbeatPongDeadlineMs: 20 }); t.after(() => gateway.stop());
  const paired = await pairBrowser(base, "Heartbeat browser"), connection = await openBrowserWs(gateway, base, paired.cookies.header);
  const started = await fetch(`${base}/api/live/session`, { method: "POST", headers: { origin: base, cookie: paired.cookies.header, "content-type": "application/json" }, body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "liaison", connectionId: connection.connectionId }) }); assert.equal(started.status, 200);
  (connection.ws as any)._socket.pause();
  await waitFor(() => sideband.sent.find((event) => event.type === "session.close"), 500);
  (connection.ws as any)._socket.resume(); connection.ws.terminate(); sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("revocation during asynchronous Live startup closes the provider session and human generation before publication", async (t) => {
  const relay = new LifecycleRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  let markFetchStarted!: () => void, resolveFetch!: (response: Response) => void;
  const fetchStarted = new Promise<void>((resolve) => { markFetchStarted = resolve; }), provider = new Promise<Response>((resolve) => { resolveFetch = resolve; });
  const sideband = new FakeSideband(), fakeFetch = async () => { markFetchStarted(); return await provider; };
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const issued = await api(base, "/api/browser-pairing", { method: "POST" }), pairingToken = ((await issued.json()) as any).pairingToken;
  const paired = await fetch(`${base}/api/browser-session/pair`, { method: "POST", headers: { origin: base, "content-type": "application/json" }, body: JSON.stringify({ pairingToken, deviceName: "Racing phone" }) }), pairBody = await paired.clone().json() as any, cookies = responseCookies(paired);
  const connection = await openBrowserWs(gateway, base, cookies.header); t.after(() => connection.ws.close());
  const starting = fetch(`${base}/api/live/session`, { method: "POST", headers: { origin: base, cookie: cookies.header, "content-type": "application/json" }, body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "direct", connectionId: connection.connectionId }) });
  await fetchStarted;
  assert.equal((await api(base, "/api/browser-devices/revoke", { method: "POST", body: JSON.stringify({ deviceId: pairBody.device.id }) })).status, 200);
  resolveFetch(new Response(JSON.stringify({ session: { id: "revoked-live" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 }));
  const response = await starting; assert.equal(response.status, 401); assert.deepEqual(await response.json(), { error: "revoked_device", cleanup: "sideband_close_sent" });
  assert.deepEqual(sideband.sent.at(-1), { type: "session.close" }); assert.equal(sideband.closed, true); assert.equal(relay.sessionId, null); assert.equal(relay.timeline.at(-1), "deactivate");
  const diagnostics = await api(base, "/api/live/diagnostics"); assert.deepEqual(await diagnostics.json(), { current: null, lastClosed: null });
});

test("native Relay snapshot, incoming push, and exact send use the selected endpoint generation", async (t) => {
  const relay = new GatewayRelayClient();
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const { gateway, base } = await setup({ relayClient: relay }); t.after(() => gateway.stop());
  const snapshot = await api(base, "/api/relay");
  assert.equal(snapshot.status, 200);
  assert.deepEqual((await snapshot.json() as any).sessions.map((item: any) => [item.id, item.endpointEpoch]), [["worker", "worker-epoch"]]);

  const paired = await pairBrowser(base), ws = new WebSocket(`ws://localhost:${gateway.port}`, { origin: base, headers: { cookie: paired.cookies.header } });
  const events: any[] = []; ws.on("message", (data) => events.push(JSON.parse(data.toString()))); t.after(() => ws.close());
  await waitFor(() => events.find((event) => event.type === "relay_snapshot"));
  relay.emit("message", relay.sessions[0], { id: "incoming-1", timestamp: 1, content: { text: "native hello", attachments: [{ type: "context", name: "note", content: "exact attachment" }] } });
  const incoming = await waitFor(() => events.find((event) => event.type === "relay_message" && event.entry.message.id === "incoming-1"));
  assert.equal(incoming.entry.message.content.attachments[0].content, "exact attachment");

  const stale = await api(base, "/api/relay/send", { method: "POST", body: JSON.stringify({ targetId: "worker", targetEpoch: "old", text: "no", messageId: "action-stale" }) });
  assert.equal(stale.status, 409);
  const sent = await api(base, "/api/relay/send", { method: "POST", body: JSON.stringify({ targetId: "worker", targetEpoch: "worker-epoch", text: "native reply", messageId: "action-1", reply: { messageId: "incoming-1", senderId: "worker", senderEpoch: "worker-epoch" } }) });
  assert.equal(sent.status, 201);
  assert.deepEqual(relay.sends, [{ target: { id: "worker", endpointEpoch: "worker-epoch" }, options: { text: "native reply", replyTo: "incoming-1", messageId: "action-1" } }]);
  const spoofedVoice = await api(base, "/api/relay/send", { method: "POST", body: JSON.stringify({ targetId: "worker", targetEpoch: "worker-epoch", text: "x".repeat(MAX_RELAY_TEXT_CHARS + 1), messageId: "spoofed-voice", source: "voice" }) });
  assert.equal(spoofedVoice.status, 400); assert.equal((await spoofedVoice.json() as any).error, "message_text_out_of_bounds");
  assert.equal(relay.sends.length, 1, "public Relay body spoofed the trusted internal voice source");
});

test("gateway serves the compiled native-pairing helper and never TypeScript source", async (t) => {
  const { gateway, base } = await setup(); t.after(() => gateway.stop());
  const response = await fetch(base + "/pairing.js");
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /text\/javascript/);
  const javascript = await response.text();
  assert.match(javascript, /Pairing code/);
  assert.doesNotMatch(javascript, /import type|: HTMLButtonElement|\.ts["']/);
  assert.equal((await fetch(base + "/pairing.ts")).status, 404);
  assert.equal((await fetch(base + "/app.js")).status, 404);
});

test("rejects unauthenticated, rebinding, and cross-origin HTTP and WebSocket requests", async (t) => {
  const { gateway, base } = await setup(); t.after(() => gateway.stop());
  assert.equal((await fetch(base + "/api/sessions", { headers: { origin: base } })).status, 401);
  assert.equal((await fetch(base + "/api/sessions", { headers: { authorization: `Bearer ${TEST_TOKEN}`, origin: "http://evil.invalid" } })).status, 403);
  const status = await new Promise<number>((resolve) => { const req = request({ hostname: "127.0.0.1", port: gateway.port, path: "/api/sessions", headers: { host: "evil.invalid", authorization: `Bearer ${TEST_TOKEN}` } }, (res) => resolve(res.statusCode!)); req.end(); });
  assert.equal(status, 403);
  const wsStatus = await new Promise<number>((resolve) => { const ws = new WebSocket(`ws://localhost:${gateway.port}`, ["companion-auth.wrong"], { origin: base }); ws.on("unexpected-response", (_req, res) => resolve(res.statusCode!)); ws.on("error", () => undefined); });
  assert.equal(wsStatus, 403);
});

test("configured private HTTPS origin is an exact Host/Origin pair, never a forwarded-header reflection", async (t) => {
  const origin = "https://voice.example.test";
  const { gateway } = await setup({ publicOrigin: origin }); t.after(() => gateway.stop());
  const status = (host: string, requestOrigin: string) => new Promise<number>((resolve) => { const req = request({ hostname: "127.0.0.1", port: gateway.port, path: "/api/relay", headers: { host, origin: requestOrigin, authorization: `Bearer ${TEST_TOKEN}`, "x-forwarded-host": "evil.invalid" } }, (res) => { res.resume(); resolve(res.statusCode!); }); req.end(); });
  assert.equal(await status("voice.example.test", origin), 401, "the root bearer is local-owner-only even on an allowed private origin");
  assert.equal(await status("voice.example.test", "https://evil.invalid"), 403);
  assert.equal(await status("evil.invalid", origin), 403);
  const local = `http://localhost:${gateway.port}`, issued = await fetch(`${local}/api/browser-pairing`, { method: "POST", headers: { origin: local, authorization: `Bearer ${TEST_TOKEN}` } });
  const pairingToken = ((await issued.json()) as any).pairingToken as string;
  const secureCookies = await new Promise<string[]>((resolve) => {
    const body = JSON.stringify({ pairingToken, deviceName: "Private phone" });
    const req = request({ hostname: "127.0.0.1", port: gateway.port, method: "POST", path: "/api/browser-session/pair", headers: { host: "voice.example.test", origin, "content-type": "application/json", "content-length": Buffer.byteLength(body) } }, (res) => { res.resume(); res.on("end", () => resolve(res.headers["set-cookie"] ?? [])); }); req.end(body);
  });
  assert.match(secureCookies[0]!, /^__Host-pi_voice_device=[A-Za-z0-9_-]{43}; Path=\/; HttpOnly; SameSite=Strict; Max-Age=(?:31536000|3153599\d); Secure$/);
  assert.match(secureCookies[1]!, /^__Host-pi_voice_session=[A-Za-z0-9_-]{43}; Path=\/; HttpOnly; SameSite=Strict; Secure$/);
});

test("durable device credentials refuse non-loopback plaintext origins", async (t) => {
  const { gateway, base } = await setup({ publicOrigin: "http://voice.example.test" }); t.after(() => gateway.stop());
  const issued = await api(base, "/api/browser-pairing", { method: "POST" }), pairingToken = ((await issued.json()) as any).pairingToken;
  const result = await new Promise<{ status: number; cookies: string[] }>((resolve) => {
    const body = JSON.stringify({ pairingToken, deviceName: "Unsafe phone" });
    const req = request({ hostname: "127.0.0.1", port: gateway.port, method: "POST", path: "/api/browser-session/pair", headers: { host: "voice.example.test", origin: "http://voice.example.test", "content-type": "application/json", "content-length": Buffer.byteLength(body) } }, (res) => { res.resume(); res.on("end", () => resolve({ status: res.statusCode!, cookies: res.headers["set-cookie"] ?? [] })); }); req.end(body);
  });
  assert.deepEqual(result, { status: 400, cookies: [] });
});

test("ephemeral human activation and target revalidation precede every paid Live call", async (t) => {
  const relay = new LifecycleRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  let paidCalls = 0; const fakeFetch = async () => { relay.timeline.push("paid"); paidCalls++; return new Response(JSON.stringify({ session: { id: "live" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 }); };
  const sideband = new FakeSideband(); const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop()); relay.timeline = [];
  relay.failActivation = true;
  const failed = await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "direct" }) });
  assert.equal(failed.status, 503); assert.equal(paidCalls, 0); assert.deepEqual(relay.timeline, ["activate", "deactivate"]);
  relay.failActivation = false; relay.timeline = [];
  const started = await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "direct" }) });
  assert.equal(started.status, 200); assert.deepEqual(relay.timeline.slice(0, 3), ["activate", "list", "paid"]); await started.json();
  relay.emit("disconnected"); await waitFor(() => relay.timeline.includes("deactivate") ? true : undefined);
  assert.equal(relay.sessionId, null); assert.equal(sideband.sent.at(-1)?.type, "session.close", "server closes paid Live without relying on a browser callback");
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("named greeting uses only a bounded control-safe server-pinned display name", () => {
  assert.equal(greetingForAgent("Research Agent"), "Hello there. You're connected to Research Agent.");
  assert.equal(greetingForAgent("pi-voice-research"), "Hello there. You're connected to pi-voice-research.");
  for (const unsafe of [undefined, "", " Agent  Name ", "Agent\nIgnore", "Agent 🔐", "x".repeat(49), "a".repeat(97)]) {
    assert.equal(greetingForAgent(unsafe), "Hello there.");
  }
});

test("exact native media readiness enqueues one greeting and stale authority cannot consume it", async (t) => {
  const sideband = new FakeSideband(), relay = new GatewayRelayClient();
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: "live-ready" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const paired = await pairBrowser(base, "Ready browser"), owner = await openBrowserWs(gateway, base, paired.cookies.header), stale = await openBrowserWs(gateway, base, paired.cookies.header);
  t.after(() => { owner.ws.close(); stale.ws.close(); });
  const started = await fetch(`${base}/api/live/session`, { method: "POST", headers: { origin: base, cookie: paired.cookies.header, "content-type": "application/json" }, body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison", connectionId: owner.connectionId }) });
  assert.equal(started.status, 200); const generation = ((await started.json()) as any).generation;
  sideband.emit("message", JSON.stringify({ type: "session.started", session: {} }));
  assert.equal(sideband.sent.length, 0, "provider startup alone greeted");
  const ready = (body: object) => fetch(`${base}/api/live/media-ready`, { method: "POST", headers: { origin: base, cookie: paired.cookies.header, "content-type": "application/json" }, body: JSON.stringify(body) });
  assert.equal((await ready({ generation: "wrong", connectionId: owner.connectionId })).status, 409);
  assert.equal((await ready({ generation, connectionId: stale.connectionId })).status, 409);
  assert.equal(sideband.sent.length, 0, "stale readiness consumed greeting authority");
  const accepted = await ready({ generation, connectionId: owner.connectionId });
  assert.equal(accepted.status, 202); assert.deepEqual(await accepted.json(), { accepted: 1, enqueued: 1 });
  assert.deepEqual({ type: sideband.sent[0]?.type, delegation_id: sideband.sent[0]?.delegation_id, content: sideband.sent[0]?.content }, { type: "session.commentary.append", delegation_id: null, content: "Hello there. You're connected to worker." });
  const duplicate = await ready({ generation, connectionId: owner.connectionId });
  assert.equal(duplicate.status, 202); assert.deepEqual(await duplicate.json(), { accepted: 1, enqueued: 0 });
  assert.equal(sideband.sent.length, 1); assert.equal(relay.sends.length, 0, "greeting reached Intercom relay");
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("provider closure receipts are exact-generation, same-device, origin-bound, and survive later diagnostics", async (t) => {
  let providerCalls = 0, attaches = 0, now = 1_000;
  const firstSideband = new FakeSideband(), secondSideband = new FakeSideband(), relay = new GatewayRelayClient();
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => { providerCalls++; return new Response(JSON.stringify({ session: { id: `receipt-${providerCalls}` }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 }); };
  const { gateway, base } = await setup({ now: () => now, closureReceiptTtlMs: 200, openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => (++attaches === 1 ? firstSideband : secondSideband) }); t.after(() => gateway.stop());
  const first = await pairBrowser(base, "Receipt owner"), other = await pairBrowser(base, "Other device");
  const firstConnection = await openBrowserWs(gateway, base, first.cookies.header), otherConnection = await openBrowserWs(gateway, base, other.cookies.header); t.after(() => { firstConnection.ws.close(); otherConnection.ws.close(); });
  const start = async (cookie: string, connectionId: string) => {
    const response = await fetch(`${base}/api/live/session`, { method: "POST", headers: { origin: base, cookie, "content-type": "application/json" }, body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison", connectionId }) });
    assert.equal(response.status, 200); return (await response.json() as any).generation as string;
  };
  const receipt = (cookie: string, generation: string) => fetch(`${base}/api/live/closure-receipt`, { method: "POST", headers: { origin: base, cookie, "content-type": "application/json" }, body: JSON.stringify({ generation }) });
  const firstGeneration = await start(first.cookies.header, firstConnection.connectionId);
  let response = await receipt(first.cookies.header, firstGeneration); assert.equal(response.status, 200); assert.deepEqual(await response.json(), { closed: 0, providerClosed: 0 });
  firstSideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} })); await new Promise((resolve) => setTimeout(resolve, 5));
  response = await receipt(other.cookies.header, firstGeneration); assert.equal(response.status, 404, "another durable device read the receipt");
  assert.equal((await api(base, "/api/live/closure-receipt", { method: "POST", body: JSON.stringify({ generation: firstGeneration }) })).status, 404, "root owner read a device receipt");
  const secondGeneration = await start(other.cookies.header, otherConnection.connectionId); secondSideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} })); await new Promise((resolve) => setTimeout(resolve, 5));
  response = await receipt(first.cookies.header, firstGeneration); assert.equal(response.status, 200); assert.deepEqual(await response.json(), { closed: 1, providerClosed: 1 }, "later terminal diagnostics overwrote exact old receipt");
  assert.equal(providerCalls, 2, "receipt queries called the provider");
  await new Promise((resolve) => setTimeout(resolve, 225));
  assert.equal((await receipt(other.cookies.header, secondGeneration)).status, 404, "physical TTL timer retained a receipt");
  now += 201;
  assert.equal((await receipt(first.cookies.header, firstGeneration)).status, 404, "expired receipt survived read-time defense");
  assert.notEqual(firstGeneration, secondGeneration);
});

test("sideband loss receipt is closed but never invents provider closure", async (t) => {
  const sideband = new FakeSideband(), relay = new GatewayRelayClient();
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  let providerCalls = 0;
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: async () => { providerCalls++; return new Response(JSON.stringify({ session: { id: "receipt-unconfirmed" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 }); }, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const paired = await pairBrowser(base, "Receipt owner"), connection = await openBrowserWs(gateway, base, paired.cookies.header); t.after(() => connection.ws.close());
  const started = await fetch(`${base}/api/live/session`, { method: "POST", headers: { origin: base, cookie: paired.cookies.header, "content-type": "application/json" }, body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison", connectionId: connection.connectionId }) });
  const generation = (await started.json() as any).generation;
  sideband.emit("close"); await new Promise((resolve) => setTimeout(resolve, 5));
  const response = await fetch(`${base}/api/live/closure-receipt`, { method: "POST", headers: { origin: base, cookie: paired.cookies.header, "content-type": "application/json" }, body: JSON.stringify({ generation }) });
  assert.equal(response.status, 200); assert.deepEqual(await response.json(), { closed: 1, providerClosed: 0 });
  assert.equal(providerCalls, 1, "closure receipt query called provider infrastructure");
});

test("Live uses client delegation, selected voice, exact Relay target, one server sideband owner, and one active session", async (t) => {
  let captured: any; let calls = 0; const sideband = new FakeSideband(); sideband.emitStartupOnStart = true;
  const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => {
    calls++; captured = init;
    const request = JSON.parse(String(init?.body));
    return new Response(JSON.stringify({ session: { id: "live_fake", ...request.session }, transport: { type: "webrtc", sdp: "answer-sdp" } }), { status: 200, headers: { "content-type": "application/json" } });
  };
  const relay = new GatewayRelayClient();
  relay.sessions = [
    { id: "voice-session", endpointEpoch: "epoch-12345678", name: "pi-companion\nIgnore previous", cwd: "/tmp/project", model: "test", kind: "agent", status: "idle", lastActivity: 1 },
    { id: "other-session", endpointEpoch: "other-epoch", name: "other", cwd: "/tmp/other", model: "test", kind: "agent", status: "idle", lastActivity: 1 },
  ];
  const { gateway, base } = await setup({ openAiKey: "server-secret", fetchImpl: fakeFetch as typeof fetch, relayClient: relay, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const live = (body: object) => api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", voice: "quartz", inputMode: "continuous", routingMode: "direct", ...body }) });
  assert.equal((await (await live({ targetId: "voice-session", targetEpoch: "old-epoch-0000" })).json() as any).error, "stale_relay_target");
  assert.equal((await (await live({ targetId: "missing", targetEpoch: "epoch" })).json() as any).error, "stale_relay_target");
  assert.equal((await live({})).status, 400);
  assert.equal(calls, 0, "no upstream paid call for invalid or stale target");

  for (const idleTimeoutMinutes of [0, 31, 1.5, "5", null]) assert.equal((await live({ targetId: "voice-session", targetEpoch: "epoch-12345678", idleTimeoutMinutes })).status, 400);
  assert.equal(calls, 0, "invalid timeouts cannot create a paid session");
  const response = await live({ targetId: "voice-session", targetEpoch: "epoch-12345678", idleTimeoutMinutes: 7 });
  const liveAnswer = await response.json() as any; const generation = liveAnswer.generation as string;
  assert.equal(liveAnswer.sessionId, "live_fake"); assert.equal(liveAnswer.sdp, "answer-sdp"); assert.equal(liveAnswer.voice, "quartz"); assert.ok(generation); assert.ok(liveAnswer.idleDeadline < liveAnswer.hardDeadline); assert.equal(sideband.startedReading, 1); assert.equal(sideband.handlersReadyAtStart, true, "sideband starts reading only after all LiveControl handlers are installed");
  assert.equal(liveAnswer.hardDeadline - liveAnswer.idleDeadline, 113 * 60_000, "configured idle timeout changed the 120-minute safety ceiling");
  assert.equal((await live({ targetId: "voice-session", targetEpoch: "epoch-12345678" })).status, 409);
  assert.equal((await api(base, "/api/live/close", { method: "POST", body: JSON.stringify({ generation: "old-tab-generation" }) })).status, 409);
  assert.equal(calls, 1);
  assert.equal(captured.headers.authorization, "Bearer server-secret");
  const body = JSON.parse(captured.body);
  assert.deepEqual(body.transport, { type: "webrtc", sdp: "offer-sdp-long-enough" });
  assert.equal(body.session.model, "gpt-live-1"); assert.equal(body.session.store, false);
  assert.deepEqual(body.session.audio, { output: { voice: "quartz" } });
  assert.deepEqual(body.session.delegation, { type: "client" });
  assert.match(body.session.instructions, /Pi coding agent "pi-companion Ignore previous"/, "name is server-injected and control characters flattened");
  assert.match(body.session.instructions, /Remain completely silent for user speech/); assert.match(body.session.instructions, /Speak only commentary explicitly marked/); assert.match(body.session.instructions, /English quoted text must be spoken in English/);
  assert.doesNotMatch(JSON.stringify(body), /gpt-6-luna|send_to_pi/);

  relay.emit("message", relay.sessions[1], { id: "other-ask", timestamp: 1, expectsReply: true, content: { text: "question from A" } });
  const wrongReply = await api(base, "/api/live/reply-context", { method: "POST", body: JSON.stringify({ generation, messageId: "other-ask", senderId: "other-session", senderEpoch: "other-epoch" }) });
  assert.equal(wrongReply.status, 409, "an incoming ask never retargets voice away from the pinned agent");

  relay.emit("message", relay.sessions[0], { id: "focused-ask", timestamp: 2, expectsReply: true, content: { text: "question from focused agent" } });
  const reply = await api(base, "/api/live/reply-context", { method: "POST", body: JSON.stringify({ generation, messageId: "focused-ask", senderId: "voice-session", senderEpoch: "epoch-12345678" }) });
  assert.equal(reply.status, 200);
  const silence = Buffer.alloc(24 * 300 * 2).toString("base64");
  sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "Please inspect it" }));
  sideband.emit("message", JSON.stringify({ type: "session.input_audio.append", audio: silence }));
  const diagnostic = await (await api(base, "/api/live/diagnostics")).json() as any;
  assert.equal(diagnostic.current.generation, generation); assert.equal(diagnostic.current.control.routing.utterances, 0);
  assert.deepEqual(diagnostic.current.control.provider.startup, { source: "sideband_session_started", model: null, delegationType: null, store: null, voice: null, instructionsMatched: false });
  assert.deepEqual(diagnostic.current.control.provider.otherEventTypes, [{ type: "session.started", count: 1 }]);
  assert.doesNotMatch(JSON.stringify(diagnostic), /Please inspect it|not retained/);
  await waitFor(() => relay.sends[0]);
  assert.match(String(relay.sends[0]!.options.messageId), /^voice-utterance-/);
  assert.equal(relay.sends[0]!.options.text, "Please inspect it");
  assert.equal(relay.sends[0]!.options.replyTo, "focused-ask"); assert.equal(relay.sends[0]!.target.id, "voice-session");
  const afterSend = await (await api(base, "/api/live/diagnostics")).json() as any;
  assert.deepEqual(afterSend.current.sends, { attempts: 1, delivered: 1, knownFailed: 0, unknown: 0 }); assert.equal(afterSend.current.control.routing.utterances, 1);
  sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "Then continue" })); await waitFor(() => relay.sends[1], 2_000);
  assert.equal(relay.sends[1]!.options.text, "Then continue"); assert.equal(relay.sends[1]!.options.replyTo, undefined);

  const focus = await api(base, "/api/live/focus", { method: "POST", body: JSON.stringify({ generation, targetId: "other-session", targetEpoch: "other-epoch" }) });
  assert.equal(focus.status, 409); assert.equal((await focus.json() as any).error, "voice_focus_change_requires_restart"); assert.equal(calls, 1);

  const close = await api(base, "/api/live/close", { method: "POST", body: JSON.stringify({ generation }) }); assert.equal(close.status, 202);
  assert.equal(sideband.sent.at(-1)?.type, "session.close");
});

test("liaison sends one exact immutable request, acknowledges known delivery once, and speaks only its matched native reply", async (t) => {
  let captured: any; const sideband = new FakeSideband(), relay = new GatewayRelayClient();
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => { captured = JSON.parse(String(init?.body)); return new Response(JSON.stringify({ session: { id: "live-liaison" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 }); };
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const response = await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison" }) });
  const { generation } = await response.json() as any; assert.deepEqual(captured.session.delegation, { type: "client" }); assert.match(captured.session.instructions, /conversational voice liaison/); assert.match(captured.session.instructions, /Delegation policy:/); assert.match(captured.session.instructions, /Backend tools:/); assert.match(captured.session.instructions, /Emit a client delegation before answering/); assert.match(captured.session.instructions, /Do not delegate to the backend when:/);
  sideband.emit("message", JSON.stringify({ type: "session.output_transcript.delta", event_id: "spoken-options", start_ms: 1, end_ms: 2, delta: "I offered the former and latter options." }));
  sideband.emit("message", JSON.stringify({ type: "session.delegation.created", event_id: "delegation-event", offset_ms: 5, delegation: { id: "delegation-1", target: "client", type: "delegation" } }));
  sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", event_id: "literal-request", start_ms: 3, end_ms: 4, delta: "Check the exact selected agent" }));
  await waitFor(() => relay.sends[0], 2_000);
  const sent = relay.sends[0]!; assert.equal(sent.target.id, "worker"); assert.equal(sent.target.endpointEpoch, "worker-epoch"); assert.equal(sent.options.text, "Live: I offered the former and latter options.\nUser: Check the exact selected agent"); assert.equal(sent.options.expectsReply, true); assert.match(String(sent.options.messageId), /^voice-liaison-/);
  assert.equal(sent.options.attachments, undefined); assert.equal(Object.hasOwn(sent.options, "attachments"), false);
  assert.equal(sideband.sent.length, 1); assert.equal(sideband.sent[0]?.type, "session.commentary.append"); assert.equal(sideband.sent[0]?.delegation_id, "delegation-1"); assert.equal(sideband.sent[0]?.content, "Sent.");
  const status = sideband.sent[0]!; sideband.emit("message", JSON.stringify({ type: "session.commentary.appended", client_event_id: status.event_id }));
  sideband.emit("message", JSON.stringify({ type: "session.delegation.created", delegation: { id: "delegation-1", target: "client", type: "delegation" } })); await new Promise((resolve) => setTimeout(resolve, 25)); assert.equal(relay.sends.length, 1);
  relay.emit("message", relay.sessions[0], { id: "matched", timestamp: 3, replyTo: sent.options.messageId, content: { text: "Verified result" } }); await waitFor(() => sideband.sent[1]);
  assert.equal(sideband.sent[1]!.type, "session.commentary.append"); assert.equal(sideband.sent[1]!.delegation_id, "delegation-1"); assert.equal(sideband.sent[1]!.content, "Verified result"); assert.equal(relay.sends.length, 1);
  const diagnostic = await (await api(base, "/api/live/diagnostics")).json() as any; assert.deepEqual(diagnostic.current.sends, { attempts: 1, delivered: 1, knownFailed: 0, unknown: 0 }); assert.equal(diagnostic.current.control.routing.liaisonRequests, 1);
  assert.equal(diagnostic.current.control.routing.utterances, 1, "one stable user group was not observed");
  assert.equal(relay.sends.length, 1, "display-only caption stability created a second routed task");
  assert.ok(relay.sends.every((item) => String(item.options.messageId).startsWith("voice-liaison-")), "liaison caption metadata entered the direct utterance router");
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} })); assert.ok(generation);
});

test("resolved sideband startup config retains only whitelist and instruction equality", async (t) => {
  const sideband = new FakeSideband(); const relay = new GatewayRelayClient();
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "general", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  let requested: any;
  const fakeFetch = async (_url: unknown, init?: RequestInit) => {
    requested = JSON.parse(String(init?.body)).session;
    return new Response(JSON.stringify({ session: { id: "live_fake" }, transport: { type: "webrtc", sdp: "answer-sdp" } }), { status: 200 });
  };
  const { gateway, base } = await setup({ openAiKey: "server-secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "liaison" }) });
  assert.match(requested.instructions, /selected Pi coding agent "general"/);
  assert.match(requested.instructions, /Emit a client delegation before answering/);
  assert.match(requested.instructions, /Do not delegate to the backend when:/);
  assert.doesNotMatch(requested.instructions, /Backchannel policy:|metadata, not task text/);
  assert.deepEqual(requested.delegation, { type: "client" });
  assert.equal(requested.model, "gpt-live-1"); assert.equal(requested.store, false);
  const readDiagnostic = async () => await (await api(base, "/api/live/diagnostics")).json() as any;
  assert.equal((await readDiagnostic()).current.control.provider.startup.instructionsMatched, null);
  sideband.emit("message", JSON.stringify({ type: "session.started", session: { ...requested, api_key: "PRIVATE-KEY", transport: { sdp: "PRIVATE-SDP" }, audio_payload: "PRIVATE-AUDIO" } }));
  const diagnostic = await readDiagnostic();
  assert.deepEqual(diagnostic.current.control.provider.startup, { source: "sideband_session_started", model: "gpt-live-1", delegationType: "client", store: false, voice: "marin", instructionsMatched: true });
  assert.doesNotMatch(JSON.stringify(diagnostic), /PRIVATE|concise conversational|Emit a client delegation|instructions\":/);
  sideband.emit("message", JSON.stringify({ type: "session.started", session: { instructions: "different" } }));
  assert.deepEqual((await readDiagnostic()).current.control.provider.startup, diagnostic.current.control.provider.startup, "duplicate starts cannot rewrite the initial resolved configuration");
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
  sideband.emit("message", JSON.stringify({ type: "session.started", session: { instructions: "late" } }));
  assert.deepEqual((await readDiagnostic()).current.control.provider.startup, diagnostic.current.control.provider.startup, "closed generations cannot accept late startup configuration");
});

test("primary provider reports require exact active authority and freeze only bounded type counts at End", async (t) => {
  const sideband = new FakeSideband(), relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: "live-primary-events" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const paired = await pairBrowser(base), connection = await openBrowserWs(gateway, base, paired.cookies.header); t.after(() => connection.ws.close());
  const started = await fetch(`${base}/api/live/session`, { method: "POST", headers: { origin: base, cookie: paired.cookies.header, "content-type": "application/json" }, body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "liaison", connectionId: connection.connectionId }) });
  const { generation } = await started.json() as any;
  const report = (body: object) => fetch(`${base}/api/live/diagnostics/provider-event-types`, { method: "POST", headers: { origin: base, cookie: paired.cookies.header, "content-type": "application/json" }, body: JSON.stringify({ generation, connectionId: connection.connectionId, sequence: 1, observations: [{ type: "session.started", count: 1 }, { type: "session.delegation.created", count: 1 }], overflow: 0, ...body }) });
  assert.equal((await report({ connectionId: "x".repeat(22) })).status, 409);
  assert.equal((await report({ observations: [{ type: "session.started", count: 1, text: "PRIVATE", audio: "BASE64", payload: { secret: true } }] })).status, 200);
  assert.equal((await report({ sequence: 1 })).status, 409, "the cumulative revision cannot replay");
  const diagnostic = await (await api(base, "/api/live/diagnostics")).json() as any;
  assert.deepEqual(diagnostic.current.control.provider.primary, { source: "client_reported", eventTypes: [{ type: "session.started", count: 1 }], overflow: 0 });
  assert.doesNotMatch(JSON.stringify(diagnostic), /PRIVATE|BASE64|secret/);
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
  assert.equal((await report({ sequence: 2 })).status, 409);
  const closed = await (await api(base, "/api/live/diagnostics")).json() as any;
  assert.equal(closed.current.snapshotPhase, "closed");
  assert.equal(closed.current.closure.providerClosed, true);
  assert.deepEqual(closed.current.control.provider.primary, { source: "client_reported", eventTypes: [{ type: "session.started", count: 1 }], overflow: 0 });
  assert.deepEqual(closed.lastClosed, closed.current);
  assert.doesNotMatch(JSON.stringify(closed), /PRIVATE|BASE64|secret/);
});

test("recent Live text is owner-only and one bounded terminal copy survives End", async (t) => {
  const sideband = new FakeSideband(), relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: "live-recent-text" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const paired = await pairBrowser(base, "Other authorized device");
  const started = await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "liaison" }) }); const generation = ((await started.json()) as any).generation;
  sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "actual user words" })); sideband.emit("message", JSON.stringify({ type: "session.output_transcript.delta", delta: "actual assistant words" }));
  const owner = await api(base, "/api/live/diagnostics/recent-text"); assert.equal(owner.status, 200); const ownerBody = await owner.json() as any; assert.equal(ownerBody.current.generation, generation); assert.deepEqual(ownerBody.current.events.map(({ role, kind, text }: any) => ({ role, kind, text })), [{ role: "user", kind: "transcript", text: "actual user words" }, { role: "assistant", kind: "transcript", text: "actual assistant words" }]); assert.ok(ownerBody.current.events.every((event: any) => Number.isFinite(event.timestampMs)));
  const device = await fetch(`${base}/api/live/diagnostics/recent-text`, { headers: { origin: base, cookie: paired.cookies.header } }); assert.equal(device.status, 401);
  sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "🧪".repeat(2_000) }));
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
  const after = await api(base, "/api/live/diagnostics/recent-text"), afterBody = await after.json() as any;
  assert.equal(afterBody.current.generation, generation); assert.equal(afterBody.current.snapshotPhase, "closed"); assert.deepEqual(afterBody.lastClosed, afterBody.current);
  assert.ok(afterBody.current.events.length <= 32);
  assert.ok(afterBody.current.events.reduce((bytes: number, event: any) => bytes + Buffer.byteLength(event.text), 0) <= 2_048);
  const ordinary = await fetch(`${base}/api/live/diagnostics`, { headers: { origin: base, cookie: paired.cookies.header } });
  assert.equal(ordinary.status, 200); assert.doesNotMatch(JSON.stringify(await ordinary.json()), /actual user words|actual assistant words|🧪/);
  const deviceAfter = await fetch(`${base}/api/live/diagnostics/recent-text`, { headers: { origin: base, cookie: paired.cookies.header } }); assert.equal(deviceAfter.status, 401);
});

test("one terminal snapshot coexists with a new active session, expires, and is replaced only by the next close", async (t) => {
  let now = 1_000, providerCalls = 0, attaches = 0;
  const firstSideband = new FakeSideband(), secondSideband = new FakeSideband();
  const relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: `live-${++providerCalls}` }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ now: () => now, openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => (++attaches === 1 ? firstSideband : secondSideband) }); t.after(() => gateway.stop());
  const start = async () => await (await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "liaison" }) })).json() as any;

  const first = await start();
  firstSideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "first terminal text" }));
  firstSideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
  const firstClosed = await (await api(base, "/api/live/diagnostics")).json() as any;
  assert.equal(firstClosed.current.generation, first.generation); assert.deepEqual(firstClosed.current, firstClosed.lastClosed);

  const second = await start();
  const overlapping = await (await api(base, "/api/live/diagnostics")).json() as any;
  assert.equal(overlapping.current.generation, second.generation); assert.equal(overlapping.current.active, true);
  assert.equal(overlapping.lastClosed.generation, first.generation, "Start overwrote the only closed comparison snapshot");
  const ownerOverlap = await (await api(base, "/api/live/diagnostics/recent-text")).json() as any;
  assert.equal(ownerOverlap.current.generation, second.generation); assert.equal(ownerOverlap.lastClosed.generation, first.generation);
  assert.equal(ownerOverlap.lastClosed.events[0].text, "first terminal text");

  secondSideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "replacement terminal text" }));
  secondSideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
  const replaced = await (await api(base, "/api/live/diagnostics/recent-text")).json() as any;
  assert.equal(replaced.lastClosed.generation, second.generation);
  assert.doesNotMatch(JSON.stringify(replaced), /first terminal text/);
  const fixedExpiry = replaced.lastClosed.expiresAt;
  now += 29 * 60_000;
  assert.equal((await (await api(base, "/api/live/diagnostics/recent-text")).json() as any).lastClosed.expiresAt, fixedExpiry, "reading refreshed terminal retention");
  now += 60_000;
  assert.deepEqual(await (await api(base, "/api/live/diagnostics")).json(), { current: null, lastClosed: null });
  assert.deepEqual(await (await api(base, "/api/live/diagnostics/recent-text")).json(), { current: null, lastClosed: null });
});

test("terminal diagnostic text is physically released when the TTL timer fires without a read", async (t) => {
  const now = 1_000, sideband = new FakeSideband(), relay = new GatewayRelayClient();
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: "live-timer" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ now: () => now, terminalDiagnosticTtlMs: 20, openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison" }) });
  sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "timer-only expiry" })); sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.deepEqual(await (await api(base, "/api/live/diagnostics/recent-text")).json(), { current: null, lastClosed: null }, "fixed clock required a read to release expired text");
});

test("terminal diagnostics are memory-only and empty after gateway restart", async () => {
  const dir = await mkdtemp(join(tmpdir(), "companion-terminal-restart-"));
  const relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const sideband = new FakeSideband(), options = { port: 0, publicDir: builtPublicDir(), token: TEST_TOKEN, deviceStoreFile: join(dir, "devices.json"), openAiKey: "secret", relayClient: relay, fetchImpl: async () => new Response(JSON.stringify({ session: { id: "live-restart" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 }), sidebandFactory: async () => sideband };
  const first = new CompanionGateway(options); await first.start(); const firstBase = `http://localhost:${first.port}`;
  await api(firstBase, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison" }) });
  sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "must not reach restart" })); sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
  assert.ok((await (await api(firstBase, "/api/live/diagnostics/recent-text")).json() as any).lastClosed); await first.stop();
  const replacement = new CompanionGateway({ ...options, port: 0 }); await replacement.start();
  try { assert.deepEqual(await (await api(`http://localhost:${replacement.port}`, "/api/live/diagnostics/recent-text")).json(), { current: null, lastClosed: null }); }
  finally { await replacement.stop(); }
});

test("liaison never says Sent or retries after an unknown delivery outcome", async (t) => {
  const sideband = new FakeSideband(), relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  let deliveryAttempts = 0; relay.sendExact = async () => { deliveryAttempts++; throw new Error("relay_delivery_unknown"); };
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: "live-liaison-unknown" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison" }) });
  sideband.emit("message", JSON.stringify({ type: "session.delegation.created", delegation: { id: "delegation-unknown", target: "client", type: "delegation" } }));
  sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "Run the unknown-outcome task" }));
  await waitFor(() => sideband.sent[0]); await new Promise((resolve) => setTimeout(resolve, 25));
  assert.equal(deliveryAttempts, 1); assert.equal(sideband.sent.length, 1); assert.equal(sideband.sent[0]?.type, "session.commentary.append"); assert.doesNotMatch(sideband.sent[0]?.content ?? "", /Sent\./); assert.match(sideband.sent[0]?.content ?? "", /outcome is unknown/i);
  sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", event_id: "after-unknown", start_ms: 10, end_ms: 20, delta: "Do not replay the prior task" }));
  sideband.emit("message", JSON.stringify({ type: "session.delegation.created", delegation: { id: "delegation-after-unknown", target: "client", type: "delegation" } }));
  await new Promise((resolve) => setTimeout(resolve, 1_200)); assert.equal(deliveryAttempts, 1, "unknown task outcome allowed a context retry or later task replay");
  const diagnostic = await (await api(base, "/api/live/diagnostics")).json() as any; assert.deepEqual(diagnostic.current.sends, { attempts: 1, delivered: 0, knownFailed: 0, unknown: 1 });
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("known durable queue acceptance commits one atomic transcript cursor for the next handoff", async (t) => {
  const sideband = new FakeSideband(), relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const sends: any[] = []; relay.sendExact = async (_target, options) => { sends.push(options); return { id: options.messageId, delivered: true, delivery: "queued", retryable: false, outcomeKnown: true }; };
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: "live-liaison-queued" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison" }) });
  const turn = (suffix: string, text: string, start: number) => {
    sideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", event_id: `input-${suffix}`, start_ms: start, end_ms: start + 1, delta: text }));
    sideband.emit("message", JSON.stringify({ type: "session.delegation.created", event_id: `event-${suffix}`, offset_ms: start + 2, delegation: { id: `delegation-${suffix}`, target: "client", type: "delegation" } }));
  };
  turn("one", "first task", 1); await waitFor(() => sends[0], 2_000);
  turn("two", "second task", 10); await waitFor(() => sends[1], 2_000);
  assert.equal(sends[0].text, "User: first task"); assert.equal(sends[0].attachments, undefined); assert.equal(Object.hasOwn(sends[0], "attachments"), false);
  assert.equal(sends[1].text, "User: second task"); assert.equal(sends[1].attachments, undefined); assert.equal(Object.hasOwn(sends[1], "attachments"), false);
  assert.equal(sends.length, 2, "queued atomic delivery was retried");
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("liaison speaks an ordinary pinned-agent message as unscoped context", async (t) => {
  const sideband = new FakeSideband(), relay = new GatewayRelayClient(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: "live-liaison-unsolicited" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "liaison" }) });
  relay.emit("message", relay.sessions[0], { id: "ordinary", timestamp: 2, replyTo: "foreign-or-absent", content: { text: "Ordinary focused update" } }); await waitFor(() => sideband.sent[0]);
  assert.equal(sideband.sent[0]!.type, "session.commentary.append"); assert.equal(sideband.sent[0]!.delegation_id, null); assert.match(sideband.sent[0]!.content, /Ordinary focused update/);
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("foreground focus lease is exact, private, atomic metadata and clears immediately", async (t) => {
  const leaseDir = await mkdtemp(join(tmpdir(), "voice-focus-test-")), leaseFile = join(leaseDir, "private", "voice-focus.json");
  const relay = new GatewayRelayClient(), sideband = new FakeSideband(); relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: "live-lease" }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband, focusLeaseFile: leaseFile }); t.after(() => gateway.stop());
  const started = await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "ptt", routingMode: "direct" }) });
  const { generation } = await started.json() as any;
  assert.equal((await api(base, "/api/live/ptt", { method: "POST", body: JSON.stringify({ generation, held: true, commandSequence: 1 }) })).status, 200);
  assert.equal((await api(base, "/api/live/ptt", { method: "POST", body: JSON.stringify({ generation, held: false, cancel: true, commandSequence: 2 }) })).status, 200);
  const lease = await api(base, "/api/focus-lease", { method: "POST", body: JSON.stringify({ active: true, generation, targetId: "worker", targetEpoch: "worker-epoch" }) }); assert.equal(lease.status, 200);
  const stored = JSON.parse(await readFile(leaseFile, "utf8")); assert.deepEqual(Object.keys(stored), ["schemaVersion", "generation", "agentId", "endpointEpoch", "updatedAt", "expiresAt"]);
  assert.equal(stored.schemaVersion, 1); assert.equal(stored.generation, generation); assert.equal(stored.agentId, "worker"); assert.equal(stored.endpointEpoch, "worker-epoch"); assert.equal(stored.expiresAt - stored.updatedAt, 15_000);
  assert.equal((await stat(join(leaseDir, "private"))).mode & 0o777, 0o700); assert.equal((await stat(leaseFile)).mode & 0o777, 0o600);
  assert.equal((await api(base, "/api/focus-lease", { method: "POST", body: JSON.stringify({ active: false, generation }) })).status, 200); await assert.rejects(() => stat(leaseFile));
  sideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("an old generation direct utterance completion cannot mutate replacement diagnostics", async (t) => {
  const relay = new GatewayRelayClient(), firstSideband = new FakeSideband(), secondSideband = new FakeSideband(); let creates = 0, attaches = 0;
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: `live-${++creates}` }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => (++attaches === 1 ? firstSideband : secondSideband) }); t.after(() => gateway.stop());
  const start = async () => (await (await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "direct" }) })).json() as any).generation as string;
  await start(); let release!: () => void; const gate = new Promise<void>((resolve) => { release = resolve; });
  relay.sendExact = async (target, options) => { relay.sends.push({ target, options }); await gate; return { id: String(options.messageId), delivered: true, delivery: "socket_delivered", retryable: false, outcomeKnown: true }; };
  firstSideband.emit("message", JSON.stringify({ type: "session.input_transcript.delta", delta: "old action" }));
  firstSideband.emit("message", JSON.stringify({ type: "session.input_audio.append", audio: Buffer.alloc(24 * 300 * 2).toString("base64") }));
  await waitFor(() => relay.sends[0]); firstSideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
  const replacementGeneration = await start(); release(); await new Promise((resolve) => setTimeout(resolve, 20));
  const diagnostic = await (await api(base, "/api/live/diagnostics")).json() as any;
  assert.equal(diagnostic.current.generation, replacementGeneration); assert.deepEqual(diagnostic.current.sends, { attempts: 0, delivered: 0, knownFailed: 0, unknown: 0 });
  secondSideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("stale browser generation cannot mutate or close a replacement Live session", async (t) => {
  const relay = new GatewayRelayClient(), firstSideband = new FakeSideband(), secondSideband = new FakeSideband(); let creates = 0, attaches = 0;
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => new Response(JSON.stringify({ session: { id: `live-${++creates}` }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 });
  const { gateway, base } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => (++attaches === 1 ? firstSideband : secondSideband) }); t.after(() => gateway.stop());
  const start = async () => (await (await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "direct" }) })).json() as any).generation as string;
  const oldGeneration = await start(); firstSideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
  const newGeneration = await start(); assert.notEqual(oldGeneration, newGeneration);
  assert.equal((await api(base, "/api/live/close", { method: "POST", body: JSON.stringify({ generation: oldGeneration }) })).status, 409);
  assert.equal((await api(base, "/api/live/focus", { method: "POST", body: JSON.stringify({ generation: oldGeneration, targetId: "worker", targetEpoch: "worker-epoch" }) })).status, 409);
  assert.equal(relay.sends.length, 0); assert.equal(secondSideband.sent.some((event) => event.type === "session.close"), false);
  secondSideband.emit("message", JSON.stringify({ type: "session.closed", usage: {} }));
});

test("concurrent delayed Live request bodies atomically create at most one paid session", async (t) => {
  let upstreamCalls = 0; const relay = new GatewayRelayClient(); const sideband = new FakeSideband();
  relay.sessions = [{ id: "worker", endpointEpoch: "worker-epoch", name: "worker", cwd: "/tmp", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const fakeFetch = async () => { upstreamCalls++; return new Response(JSON.stringify({ session: { id: `live-${upstreamCalls}` }, transport: { type: "webrtc", sdp: "answer" } }), { status: 200 }); };
  const { gateway } = await setup({ openAiKey: "secret", relayClient: relay, fetchImpl: fakeFetch as typeof fetch, sidebandFactory: async () => sideband }); t.after(() => gateway.stop());
  const payload = JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "worker", targetEpoch: "worker-epoch", voice: "marin", inputMode: "continuous", routingMode: "direct" });
  const slow = () => {
    let release!: () => void; const released = new Promise<void>((resolve) => { release = resolve; });
    const result = new Promise<number>((resolve, reject) => {
      const req = request({ hostname: "localhost", port: gateway.port, path: "/api/live/session", method: "POST", headers: { host: `localhost:${gateway.port}`, origin: `http://localhost:${gateway.port}`, authorization: `Bearer ${TEST_TOKEN}`, "content-type": "application/json" } }, (res) => { res.resume(); res.on("end", () => resolve(res.statusCode!)); });
      req.on("error", reject); req.write(payload.slice(0, 1)); void released.then(() => req.end(payload.slice(1)));
    });
    return { result, release };
  };
  const a = slow(), b = slow(); await new Promise((resolve) => setTimeout(resolve, 10)); a.release(); b.release();
  const statuses = await Promise.all([a.result, b.result]);
  assert.deepEqual(statuses.sort(), [200, 409]); assert.equal(upstreamCalls, 1);
});

test("Live upstream rejection returns only bounded safe diagnostics", async (t) => {
  const hidden = "v=0\\no=secret SDP and sk-secret";
  const fakeFetch = async () => new Response(JSON.stringify({
    error: {
      type: "invalid_request_error",
      code: "unknown_parameter",
      message: "Bad field\u0000 " + "m".repeat(500),
      internal_payload: hidden,
    },
    transport: { sdp: hidden },
  }), { status: 400, headers: { "content-type": "application/json", "x-request-id": "req_safe_123" } });
  const relay = new GatewayRelayClient();
  relay.sessions = [{ id: "voice-reject", endpointEpoch: "epoch-reject-1234", name: "fake Pi", cwd: "/tmp/project", model: "test", kind: "agent", status: "idle", lastActivity: 1 }];
  const { gateway, base } = await setup({ openAiKey: "server-secret", fetchImpl: fakeFetch as typeof fetch, relayClient: relay }); t.after(() => gateway.stop());
  const response = await api(base, "/api/live/session", { method: "POST", body: JSON.stringify({ sdp: "offer-sdp-long-enough", targetId: "voice-reject", targetEpoch: "epoch-reject-1234", voice: "marin", inputMode: "continuous", routingMode: "direct" }) });
  assert.equal(response.status, 502);
  const body = await response.json() as any;
  assert.deepEqual({ error: body.error, status: body.upstream.status, requestId: body.upstream.requestId, type: body.upstream.type, code: body.upstream.code }, {
    error: "live_session_failed", status: 400, requestId: "req_safe_123", type: "invalid_request_error", code: "unknown_parameter",
  });
  assert.match(body.upstream.message, /^Bad field m+$/);
  assert.equal(body.upstream.message.length, 300);
  const serialized = JSON.stringify(body);
  assert.doesNotMatch(serialized, /secret|transport|internal_payload|server-secret|offer-sdp/);
});

test("gateway refuses to listen when the persistent device store is corrupt", async () => {
  const dir = await mkdtemp(join(tmpdir(), "companion-corrupt-devices-")), deviceStoreFile = join(dir, "devices.json"); await writeFile(deviceStoreFile, "{broken", { mode: 0o600 });
  const gateway = new CompanionGateway({ port: 0, deviceStoreFile, publicDir: builtPublicDir() });
  await assert.rejects(gateway.start(), /device_store_corrupt/); assert.equal(gateway.port, 0);
});

test("gateway writes a private discovery file and removes it on stop", async () => {
  const dir = await mkdtemp(join(tmpdir(), "companion-discovery-"));
  const discoveryFile = join(dir, "runtime", "bridge.json");
  const gateway = new CompanionGateway({ port: 0, discoveryFile, deviceStoreFile: join(dir, "devices.json"), publicOrigin: "https://voice.example.test\n", publicDir: builtPublicDir() });
  await gateway.start();
  assert.equal((await stat(join(dir, "runtime"))).mode & 0o777, 0o700);
  assert.equal((await stat(discoveryFile)).mode & 0o777, 0o600);
  const discovery = JSON.parse(await readFile(discoveryFile, "utf8")); assert.equal(discovery.url, `http://localhost:${gateway.port}/`); assert.equal(discovery.browserOrigin, "https://voice.example.test"); assert.match(discovery.instanceId, /^[A-Za-z0-9_-]{22}$/); assert.doesNotMatch(JSON.stringify(discovery), /token|test-token/);
  await gateway.stop();
  await assert.rejects(() => stat(discoveryFile));
});
