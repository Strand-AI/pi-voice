import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { NativeIntercomClient, OFFLINE_DELIVERY_REJECT_FEATURE } from "pi-intercom/client";
import { PersistentNativeRelay } from "../src/native-relay.ts";
import { RelayState, type RelayStateEvent } from "../src/relay.ts";
import { LiveControl, type LiveClock } from "../src/live-control.ts";

class FakeNative extends EventEmitter {
  readonly options: any; sessionId: string | null = null; endpointEpoch: string | null = null; connected = false; disconnects = 0; sent: any[] = []; roster: any[] = [];
  constructor(options: any) { super(); this.options = options; }
  async connect() { this.connected = true; this.sessionId = this.options.id; this.endpointEpoch = `epoch-${this.options.id}`; this.emit("connected"); }
  async disconnect() { this.disconnects++; const wasConnected = this.connected; this.connected = false; this.sessionId = null; this.endpointEpoch = null; if (wasConnected) this.emit("disconnected"); }
  async listSessions() { return this.roster; }
  async sendExact(target: any, options: any) { this.sent.push({ target, options }); return { id: options.messageId, delivered: true, delivery: "socket_delivered", retryable: false, outcomeKnown: true }; }
}

test("supported plain-JS pi-intercom/client export loads without a TypeScript runtime loader", () => {
  assert.equal(typeof NativeIntercomClient, "function");
  assert.equal(OFFLINE_DELIVERY_REJECT_FEATURE, "offline-delivery-reject-v1");
  const relay = new PersistentNativeRelay("/tmp/pi-companion-test");
  assert.equal(relay.connected, false); assert.equal(relay.sessionId, null); assert.equal(relay.endpointEpoch, null);
});

test("real native adapter preserves validated supersedes through RelayState into LiveControl", async () => {
  const clients: FakeNative[] = [];
  const native = new PersistentNativeRelay("/tmp/pi-voice", "scope", ((options: any) => { const client = new FakeNative(options); clients.push(client); return client; }) as any);
  const clock: LiveClock = { now: () => 0, setTimeout: () => 1, clearTimeout: () => {} };
  const control = new LiveControl({ socket: { send() {}, close() {} }, clock, routingMode: "liaison", publish() {}, onClosed() {} });
  new RelayState({ client: native, publish: (event: RelayStateEvent) => {
    if (event.type !== "relay_message" || event.entry.direction !== "inbound") return;
    const entry = event.entry;
    control.appendIncomingAgentMessage(entry.message.id, `${entry.from.id}\u0000${entry.from.endpointEpoch}`, entry.from.name ?? entry.from.id, entry.message.content.text, null, entry.message.supersedes ?? null);
  } });
  await native.start(); await native.activateHuman("generation-one");
  const human = clients[1]!, from = { id: "agent", endpointEpoch: "agent-epoch", kind: "agent", cwd: "/tmp", lastActivity: 1 };
  human.emit("message", from, { id: "old", timestamp: 1, content: { text: "old" } });
  human.emit("message", from, { id: "replacement", timestamp: 2, supersedes: "old", content: { text: "new" } });
  const entries = control.diagnostics.routing.agentSpeech.entries;
  assert.equal(entries.find((entry) => entry.messageId === "old")?.state, "superseded");
  assert.equal(entries.find((entry) => entry.messageId === "replacement")?.state, "never_attempted");
  await native.stop();
});

test("observer persists while each Live generation gets a fenced never-reused human identity", async () => {
  const clients: FakeNative[] = [], relay = new PersistentNativeRelay("/tmp/pi-voice", "scope", ((options: any) => { const client = new FakeNative(options); clients.push(client); return client; }) as any);
  const inbound: any[] = [], disconnects: number[] = []; relay.on("message", (...args) => inbound.push(args)); relay.on("human_disconnected", () => disconnects.push(1));
  await relay.start(); const observer = clients[0]!;
  assert.equal(observer.options.kind, "service"); assert.equal(observer.options.offlineDelivery, undefined, "roster observer keeps ordinary non-human policy"); assert.equal(relay.connected, true); assert.equal(relay.sessionId, null, "voice-off has no human endpoint");
  observer.emit("message", { id: "agent", endpointEpoch: "a", kind: "agent", cwd: "/tmp", lastActivity: 1 }, { id: "ignored" }); assert.equal(inbound.length, 0, "observer is never a human inbox");

  const first = await relay.activateHuman("generation-one"), firstHuman = clients[1]!;
  assert.match(first.id, /^pivoice-human-[a-f0-9]{18}$/); assert.equal(firstHuman.options.name, first.id); assert.equal(firstHuman.options.offlineDelivery, "reject", "active human endpoint must fail closed instead of acquiring offline mail"); assert.equal(relay.sessionId, first.id);
  const contextAttachment = { type: "context" as const, name: "pi-voice-live-transcript.json", content: JSON.stringify({ schema: "pi-voice-live-transcript/v1", transcript: [{ role: "user", delta: "hello" }] }), language: "json" };
  await relay.sendExact({ id: "agent", endpointEpoch: "agent-epoch" }, { text: "hello", attachments: [contextAttachment], messageId: "m1" });
  assert.equal(firstHuman.sent.length, 1); assert.equal(observer.sent.length, 0);
  assert.deepEqual(firstHuman.sent[0], { target: { id: "agent", endpointEpoch: "agent-epoch" }, options: { text: "hello", attachments: [contextAttachment], messageId: "m1" } }, "typed context attachment changed before the Native client wire boundary");
  firstHuman.emit("message", { id: "agent", endpointEpoch: "agent-epoch", kind: "agent", cwd: "/tmp", lastActivity: 1 }, { id: "replacement", timestamp: 1, supersedes: "old-message", content: { text: "new" } });
  assert.equal(inbound[0]?.[1]?.supersedes, "old-message", "the native adapter dropped explicit broker-validated supersedes metadata");
  await relay.deactivateHuman("generation-one"); assert.equal(firstHuman.disconnects, 1); assert.equal(relay.sessionId, null); assert.equal(relay.connected, true);
  firstHuman.emit("message", { id: "agent", endpointEpoch: "a", kind: "agent", cwd: "/tmp", lastActivity: 1 }, { id: "late" }); assert.equal(inbound.length, 1, "late callback is generation-fenced");

  const second = await relay.activateHuman("generation-two"); assert.notEqual(second.id, first.id); assert.notEqual(clients[2]!.options.name, firstHuman.options.name, "canonical name is also never reused");
  clients[2]!.emit("disconnected"); assert.equal(relay.sessionId, null); assert.equal(disconnects.length, 1, "unexpected human loss is surfaced once");
  await relay.stop(); assert.equal(observer.disconnects, 1);
});
