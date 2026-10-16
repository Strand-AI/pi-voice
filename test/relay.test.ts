import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import {
  MAX_RELAY_MESSAGES,
  MAX_RELAY_TEXT_CHARS,
  MAX_RELAY_VOICE_TEXT_BYTES,
  MAX_RELAY_VOICE_TEXT_CHARS,
  RelayState,
  type RelayClient,
  type RelayDelivery,
  type RelayInboundMessage,
  type RelaySession,
  type RelayStateEvent,
} from "../src/relay.ts";

class FakeRelayClient extends EventEmitter implements RelayClient {
  sessionId: string | null = "voice-human-id";
  endpointEpoch: string | null = "human-epoch";
  connected = true;
  sessions: RelaySession[] = [];
  sends: Array<{ target: { id: string; endpointEpoch: string }; options: Record<string, unknown> }> = [];
  result: RelayDelivery = { id: "sent-id", delivered: true, delivery: "socket_delivered", retryable: false, outcomeKnown: true };
  async listSessions(): Promise<RelaySession[]> { return this.sessions; }
  async sendExact(target: { id: string; endpointEpoch: string }, options: { text: string; messageId: string; replyTo?: string; expectsReply?: boolean }): Promise<RelayDelivery> {
    this.sends.push({ target, options }); return this.result;
  }
  roster(sessions: RelaySession[]): void { this.emit("roster", sessions); }
  incoming(from: RelaySession, message: RelayInboundMessage): void { this.emit("message", from, message); }
}

function session(id: string, epoch = `${id}-epoch`): RelaySession {
  return { id, endpointEpoch: epoch, name: id, cwd: `/tmp/${id}`, model: "test", kind: "agent", status: "idle", lastActivity: 1 };
}
function incoming(id: string, text = id): RelayInboundMessage {
  return { id, timestamp: 1, content: { text } };
}

test("relay sends only to the selected exact id and endpoint epoch", async () => {
  const client = new FakeRelayClient(); const events: RelayStateEvent[] = [];
  const relay = new RelayState({ client, publish: (event) => events.push(event) });
  client.roster([session("worker", "epoch-1")]);
  await relay.send({ targetId: "worker", targetEpoch: "epoch-1", text: "hello", source: "human", messageId: "browser-action-1" });
  assert.deepEqual(client.sends, [{ target: { id: "worker", endpointEpoch: "epoch-1" }, options: { text: "hello", messageId: "browser-action-1" } }]);
  assert.equal(events.at(-1)?.type, "relay_message");
  await assert.rejects(relay.send({ targetId: "worker", targetEpoch: "old", text: "no", source: "human" }), /stale_relay_target/);
  assert.equal(client.sends.length, 1);
});

test("only trusted internal voice sends receive the raised atomic text bound", async () => {
  const client = new FakeRelayClient(); const relay = new RelayState({ client, publish() {} }); client.roster([session("worker")]);
  await relay.send({ targetId: "worker", targetEpoch: "worker-epoch", text: "v".repeat(MAX_RELAY_VOICE_TEXT_CHARS), source: "voice", messageId: "voice-at-bound" });
  await assert.rejects(relay.send({ targetId: "worker", targetEpoch: "worker-epoch", text: "v".repeat(MAX_RELAY_VOICE_TEXT_CHARS + 1), source: "voice", messageId: "voice-over-char-bound" }), /message_text_out_of_bounds/);
  await relay.send({ targetId: "worker", targetEpoch: "worker-epoch", text: "é".repeat(MAX_RELAY_VOICE_TEXT_BYTES / 2), source: "voice", messageId: "voice-at-byte-bound" });
  await assert.rejects(relay.send({ targetId: "worker", targetEpoch: "worker-epoch", text: "é".repeat(MAX_RELAY_VOICE_TEXT_BYTES / 2 + 1), source: "voice", messageId: "voice-over-byte-bound" }), /message_text_out_of_bounds/);
  await relay.send({ targetId: "worker", targetEpoch: "worker-epoch", text: "h".repeat(MAX_RELAY_TEXT_CHARS), source: "human", messageId: "human-at-bound" });
  await assert.rejects(relay.send({ targetId: "worker", targetEpoch: "worker-epoch", text: "h".repeat(MAX_RELAY_TEXT_CHARS + 1), source: "human", messageId: "human-over-bound" }), /message_text_out_of_bounds/);
  assert.deepEqual(client.sends.map((send) => send.options.messageId), ["voice-at-bound", "voice-at-byte-bound", "human-at-bound"]);
});

test("expectsReply is part of the immutable native action and creates a reply-capable message", async () => {
  const client = new FakeRelayClient(); const relay = new RelayState({ client, publish() {} }); client.roster([session("worker")]);
  const entry = await relay.send({ targetId: "worker", targetEpoch: "worker-epoch", text: "work", source: "voice", messageId: "ask-action", expectsReply: true });
  assert.equal(client.sends[0]?.options.expectsReply, true); assert.equal(entry.message.expectsReply, true);
  await assert.rejects(relay.send({ targetId: "worker", targetEpoch: "worker-epoch", text: "work", source: "voice", messageId: "ask-action" }), /duplicate_message_id_conflict/);
});

test("reply remains bound to the explicitly selected sender and message", async () => {
  const client = new FakeRelayClient(); const relay = new RelayState({ client, publish() {} });
  const a = session("a"), b = session("b"); client.roster([a, b]);
  client.incoming(a, { ...incoming("question-a", "Question?"), expectsReply: true });
  client.incoming(b, incoming("notice-b", "FYI"));
  await assert.rejects(relay.send({ targetId: "b", targetEpoch: b.endpointEpoch, text: "answer", source: "human", reply: { messageId: "question-a", senderId: a.id, senderEpoch: a.endpointEpoch } }), /reply_target_mismatch/);
  await relay.send({ targetId: "a", targetEpoch: a.endpointEpoch, text: "answer", source: "human", reply: { messageId: "question-a", senderId: a.id, senderEpoch: a.endpointEpoch } });
  assert.equal(client.sends.length, 1);
  assert.equal(client.sends[0]?.options.replyTo, "question-a");
});

test("unknown or failed exact delivery is never replayed", async () => {
  const client = new FakeRelayClient(); const relay = new RelayState({ client, publish() {} });
  client.roster([session("worker")]);
  client.result = { id: "unknown", delivered: false, delivery: "unknown", reason: "socket closed", retryable: true, outcomeKnown: false };
  const authored = { targetId: "worker", targetEpoch: "worker-epoch", text: "once", source: "voice" as const, messageId: "one-action" };
  await assert.rejects(relay.send(authored), /relay_delivery_unknown/);
  await assert.rejects(relay.send(authored), /relay_delivery_unknown/);
  assert.equal(client.sends.length, 1, "an unknown authored action is never replayed");
  assert.equal(relay.snapshot().messages.length, 0);
});

test("native timeout or disconnect rejection is UNKNOWN and never replayed", async () => {
  const client = new FakeRelayClient(); const relay = new RelayState({ client, publish() {} }); client.roster([session("worker")]);
  client.sendExact = async (target, options) => { client.sends.push({ target, options }); throw new Error("Exact send timeout; delivery outcome is unknown"); };
  const action = { targetId: "worker", targetEpoch: "worker-epoch", text: "may have crossed socket", source: "voice" as const, messageId: "unknown-throw" };
  await assert.rejects(relay.send(action), /relay_delivery_unknown.*Exact send timeout/);
  await assert.rejects(relay.send(action), /relay_delivery_unknown/);
  assert.equal(client.sends.length, 1);
});

test("send attribution captures the human endpoint generation before awaiting delivery", async () => {
  const client = new FakeRelayClient(); const relay = new RelayState({ client, publish() {} }); client.roster([session("worker")]);
  let complete!: (value: RelayDelivery) => void;
  client.sendExact = async () => await new Promise<RelayDelivery>((resolve) => { complete = resolve; });
  const pending = relay.send({ targetId: "worker", targetEpoch: "worker-epoch", text: "hello", source: "human", messageId: "generation-test" });
  client.endpointEpoch = "replacement-epoch";
  complete({ id: "generation-test", delivered: true, delivery: "socket_delivered", retryable: false, outcomeKnown: true });
  assert.equal((await pending).from.endpointEpoch, "human-epoch");
});

test("same authored message ID is idempotent and conflicting reuse fails", async () => {
  const client = new FakeRelayClient(); const events: RelayStateEvent[] = []; const relay = new RelayState({ client, publish: (event) => events.push(event) });
  client.roster([session("worker")]);
  const input = { targetId: "worker", targetEpoch: "worker-epoch", text: "once", source: "human" as const, messageId: "stable-id" };
  const [first, second] = await Promise.all([relay.send(input), relay.send(input)]);
  assert.equal(first, second); assert.equal(client.sends.length, 1);
  assert.equal(events.filter((event) => event.type === "relay_message").length, 1);
  await assert.rejects(relay.send({ ...input, text: "different" }), /duplicate_message_id_conflict/);
});

test("incoming messages preserve text and attachments, dedupe, and remain bounded in memory", () => {
  const client = new FakeRelayClient(); const events: RelayStateEvent[] = [];
  const relay = new RelayState({ client, publish: (event) => events.push(event) });
  const from = session("worker");
  const rich: RelayInboundMessage = { id: "rich", timestamp: 1, expectsReply: true, content: { text: "hello", attachments: [{ type: "snippet", name: "x.ts", language: "ts", content: "export {}" }] } };
  client.incoming(from, rich); client.incoming(from, rich);
  assert.deepEqual(relay.snapshot().messages[0]?.message, rich);
  for (let i = 0; i < MAX_RELAY_MESSAGES + 10; i++) client.incoming(from, incoming(`m-${i}`));
  assert.equal(relay.snapshot().messages.length, MAX_RELAY_MESSAGES);
  assert.equal(events.filter((event) => event.type === "relay_message" && event.entry.message.id === "rich").length, 1);
});

test("explicit supersedes metadata is retained only for the same exact sender and human generation", () => {
  const client = new FakeRelayClient(); const events: RelayStateEvent[] = [];
  const relay = new RelayState({ client, publish: (event) => events.push(event) });
  const worker = session("worker"), other = session("other");
  client.incoming(worker, incoming("old", "old"));
  client.incoming(worker, { ...incoming("replacement", "new"), supersedes: "old" });
  assert.equal(relay.snapshot().messages.at(-1)?.message.supersedes, "old");

  client.incoming(other, { ...incoming("wrong-sender", "new"), supersedes: "old" });
  assert.equal(relay.snapshot().messages.at(-1)?.message.supersedes, undefined);
  client.endpointEpoch = "replacement-human-epoch";
  client.incoming(worker, { ...incoming("wrong-generation", "new"), supersedes: "old" });
  assert.equal(relay.snapshot().messages.at(-1)?.message.supersedes, undefined);
  assert.equal(events.filter((event) => event.type === "relay_error" && event.code === "incoming_supersedes_invalid").length, 2);
});

test("malformed or oversized native input is dropped with a bounded diagnostic instead of throwing", () => {
  const client = new FakeRelayClient(); const events: RelayStateEvent[] = [];
  new RelayState({ client, publish: (event) => events.push(event) });
  assert.doesNotThrow(() => client.incoming(session("worker"), { id: "bad", timestamp: 1, content: { text: "x".repeat(MAX_RELAY_TEXT_CHARS + 1) } }));
  assert.deepEqual(events.at(-1), { type: "relay_error", code: "incoming_message_out_of_bounds", message: "Dropped out-of-bounds native message bad from worker." });
});

test("roster excludes the human endpoint and stale disconnect clears targets without history loss", () => {
  const client = new FakeRelayClient(); const events: RelayStateEvent[] = [];
  const relay = new RelayState({ client, publish: (event) => events.push(event) });
  client.roster([session("voice-human-id", "human-epoch"), session("worker")]);
  client.incoming(session("worker"), incoming("m"));
  assert.deepEqual(relay.snapshot().sessions.map((item) => item.id), ["worker"]);
  client.connected = false; client.emit("disconnected");
  assert.equal(relay.snapshot().sessions.length, 0);
  assert.equal(relay.snapshot().messages.length, 1);
});
