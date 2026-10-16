import { randomBytes } from "node:crypto";
import { EventEmitter } from "node:events";
import { NativeIntercomClient, type Message, type SessionInfo } from "pi-intercom/client";
import { RELAY_NAME, type RelayClient, type RelayDelivery, type RelayInboundMessage, type RelaySession } from "./relay.ts";

function relaySession(value: SessionInfo): RelaySession | null {
  if (!value.endpointEpoch || !value.kind) return null;
  return {
    id: value.id,
    endpointEpoch: value.endpointEpoch,
    kind: value.kind,
    ...(value.name ? { name: value.name } : {}),
    ...(value.runtimeFallbackAlias !== undefined ? { runtimeFallbackAlias: value.runtimeFallbackAlias } : {}),
    cwd: value.cwd,
    ...(value.model ? { model: value.model } : {}),
    ...(value.status ? { status: value.status } : {}),
    lastActivity: value.lastActivity,
  };
}
function relayMessage(value: Message): RelayInboundMessage {
  return {
    id: value.id, timestamp: value.timestamp,
    ...(value.senderSequence !== undefined ? { senderSequence: value.senderSequence } : {}),
    ...(value.brokerReceivedAt !== undefined ? { brokerReceivedAt: value.brokerReceivedAt } : {}),
    ...(value.brokerDeliveredAt !== undefined ? { brokerDeliveredAt: value.brokerDeliveredAt } : {}),
    ...(value.receiverReceivedAt !== undefined ? { receiverReceivedAt: value.receiverReceivedAt } : {}),
    ...(value.replyTo ? { replyTo: value.replyTo } : {}),
    ...(value.supersedes ? { supersedes: value.supersedes } : {}),
    ...(value.expectsReply !== undefined ? { expectsReply: value.expectsReply } : {}),
    content: { text: value.content.text, ...(value.content.attachments ? { attachments: value.content.attachments.map((item) => ({ ...item })) } : {}) },
  };
}

type NativeClient = InstanceType<typeof NativeIntercomClient>;
type NativeOptions = ConstructorParameters<typeof NativeIntercomClient>[0];
type NativeFactory = (options: NativeOptions) => NativeClient;

/** Persistent roster observer plus a never-reused human endpoint scoped to one Live generation. */
export class PersistentNativeRelay extends EventEmitter implements RelayClient {
  private readonly observer: NativeClient;
  private readonly createNative: NativeFactory;
  private readonly cwd: string;
  private readonly scopeId: string | undefined;
  private human: NativeClient | null = null;
  private humanGeneration: string | null = null;
  private stopped = true;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private retryMs = 500;

  constructor(cwd: string, scopeId?: string, createNative: NativeFactory = (options) => new NativeIntercomClient(options)) {
    super();
    this.cwd = cwd; this.scopeId = scopeId; this.createNative = createNative;
    this.observer = createNative({ id: "pi-voice-roster", name: "pi-voice-roster", kind: "service", cwd, status: "available", ...(scopeId ? { scopeId } : {}) });
    this.observer.on("roster", (sessions: SessionInfo[]) => this.emit("roster", sessions.flatMap((item) => { const mapped = relaySession(item); return mapped ? [mapped] : []; })));
    this.observer.on("connected", () => { this.retryMs = 500; this.emit("connected"); });
    this.observer.on("disconnected", () => { const generation = this.humanGeneration; if (generation) void this.deactivateHuman(generation).catch((error) => this.emit("relay_error", error)); this.emit("disconnected"); this.scheduleReconnect(); });
    this.observer.on("client_error", (error) => this.emit("relay_error", error));
    this.observer.on("roster_error", (error) => this.emit("relay_error", error));
    // Observer message events are deliberately ignored: it is never a human inbox.
  }

  get sessionId(): string | null { return this.human?.sessionId ?? null; }
  get endpointEpoch(): string | null { return this.human?.endpointEpoch ?? null; }
  get connected(): boolean { return this.observer.connected; }

  async start(): Promise<void> {
    this.stopped = false;
    await this.observer.connect();
  }
  async stop(): Promise<void> {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    if (this.humanGeneration) await this.deactivateHuman(this.humanGeneration);
    await this.observer.disconnect();
  }
  async listSessions(): Promise<RelaySession[]> {
    return (await this.observer.listSessions()).flatMap((item) => { const mapped = relaySession(item); return mapped ? [mapped] : []; });
  }

  async activateHuman(generation: string): Promise<{ id: string; endpointEpoch: string }> {
    if (this.stopped || !this.observer.connected) throw new Error("relay_observer_disconnected");
    if (this.human) throw new Error("voice_human_already_active");
    const identity = `pivoice-human-${randomBytes(9).toString("hex")}`;
    const human = this.createNative({ id: identity, name: identity, kind: "human", cwd: this.cwd, status: "available", offlineDelivery: "reject", ...(this.scopeId ? { scopeId: this.scopeId } : {}) });
    this.human = human; this.humanGeneration = generation;
    human.on("message", (from, message) => {
      if (this.human !== human || this.humanGeneration !== generation) return;
      const session = relaySession(from); if (session) this.emit("message", session, relayMessage(message));
    });
    human.on("disconnected", () => {
      if (this.human !== human || this.humanGeneration !== generation) return;
      this.human = null; this.humanGeneration = null;
      this.emit("connected"); // Observer remains connected; publish the now-absent human endpoint.
      this.emit("human_disconnected");
    });
    human.on("client_error", (error) => this.emit("relay_error", error));
    try {
      await human.connect();
      if (this.human !== human || this.humanGeneration !== generation || !human.sessionId || !human.endpointEpoch) throw new Error("voice_human_identity_unverified");
      this.emit("connected");
      return { id: human.sessionId, endpointEpoch: human.endpointEpoch };
    } catch (error) {
      if (this.human === human) { this.human = null; this.humanGeneration = null; }
      await human.disconnect().catch(() => undefined);
      throw error;
    }
  }

  async deactivateHuman(generation: string): Promise<void> {
    const human = this.human;
    if (!human || this.humanGeneration !== generation) return;
    this.human = null; this.humanGeneration = null; // Fence callbacks and sends before transport teardown.
    this.emit("connected");
    await human.disconnect();
  }

  async sendExact(target: { id: string; endpointEpoch: string }, options: Parameters<RelayClient["sendExact"]>[1]): Promise<RelayDelivery> {
    const human = this.human;
    if (!human?.connected) throw new Error("voice_human_not_active");
    return await human.sendExact(target, options);
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
    const delay = this.retryMs; this.retryMs = Math.min(10_000, this.retryMs * 2);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      void this.observer.connect().catch((error) => { this.emit("relay_error", error); this.scheduleReconnect(); });
    }, delay);
    this.reconnectTimer.unref?.();
  }
}
