import { randomUUID } from "node:crypto";

export const RELAY_NAME = "pi-voice-human";
export const MAX_RELAY_MESSAGES = 256;
export const MAX_RELAY_MEMORY_BYTES = 4 * 1024 * 1024;
export const MAX_RELAY_TEXT_CHARS = 16_000;
// Only internally authored voice actions use the larger one-message transcript body.
export const MAX_RELAY_VOICE_TEXT_CHARS = 60_000;
export const MAX_RELAY_VOICE_TEXT_BYTES = 60 * 1024;
export const MAX_RELAY_ATTACHMENTS = 8;
export const MAX_RELAY_ATTACHMENT_CHARS = 64_000;

export type RelayAttachment = {
  type: "file" | "snippet" | "context";
  name: string;
  content: string;
  language?: string;
};

export type RelaySession = {
  id: string;
  endpointEpoch: string;
  name?: string;
  runtimeFallbackAlias?: boolean;
  cwd: string;
  model?: string;
  status?: string;
  lastActivity: number;
  kind: "agent" | "human" | "service";
  location?: string;
};

export type RelayMessageContent = { text: string; attachments?: RelayAttachment[] };

export type RelayInboundMessage = {
  id: string;
  timestamp: number;
  senderSequence?: number;
  brokerReceivedAt?: number;
  brokerDeliveredAt?: number;
  receiverReceivedAt?: number;
  replyTo?: string;
  supersedes?: string;
  expectsReply?: boolean;
  content: RelayMessageContent;
};

export type RelayDelivery = {
  id: string;
  delivered: boolean;
  delivery: "socket_delivered" | "queued" | "failed" | "unknown";
  code?: string;
  reason?: string;
  retryable: boolean;
  outcomeKnown: boolean;
};

export type RelayClient = {
  readonly sessionId: string | null;
  readonly endpointEpoch: string | null;
  readonly connected: boolean;
  listSessions(): Promise<RelaySession[]>;
  sendExact(target: { id: string; endpointEpoch: string }, options: {
    text: string;
    attachments?: RelayAttachment[];
    replyTo?: string;
    expectsReply?: boolean;
    messageId: string;
  }): Promise<RelayDelivery>;
  activateHuman?(generation: string): Promise<{ id: string; endpointEpoch: string }>;
  deactivateHuman?(generation: string): Promise<void>;
  on(event: "message", listener: (from: RelaySession, message: RelayInboundMessage) => void): RelayClient;
  on(event: "roster", listener: (sessions: RelaySession[]) => void): RelayClient;
  on(event: "connected" | "disconnected" | "human_disconnected", listener: () => void): RelayClient;
};

export type RelayParty = { id: string; endpointEpoch: string; name?: string };

export type RelayConversationMessage = {
  direction: "inbound" | "outbound";
  source: "agent" | "human" | "voice";
  from: RelayParty;
  to?: RelayParty;
  message: RelayInboundMessage;
  delivery?: RelayDelivery;
};

export type RelaySnapshot = {
  connected: boolean;
  endpoint: { id: string; endpointEpoch: string; name: typeof RELAY_NAME } | null;
  sessions: RelaySession[];
  messages: RelayConversationMessage[];
};

export type RelayStateEvent =
  | { type: "relay_snapshot"; snapshot: RelaySnapshot }
  | { type: "relay_roster"; sessions: RelaySession[] }
  | { type: "relay_message"; entry: RelayConversationMessage }
  | { type: "relay_error"; code: string; message: string }
  | { type: "relay_connection"; connected: boolean; endpoint: RelaySnapshot["endpoint"] };

type OutboundAction = {
  fingerprint: string;
  state: "pending" | "sent" | "failed";
  promise: Promise<RelayConversationMessage>;
};

export type RelayStateOptions = {
  client: RelayClient;
  publish: (event: RelayStateEvent) => void;
};

function contentBytes(content: RelayMessageContent): number {
  let bytes = Buffer.byteLength(content.text);
  for (const attachment of content.attachments ?? []) {
    bytes += Buffer.byteLength(attachment.name) + Buffer.byteLength(attachment.content) + Buffer.byteLength(attachment.language ?? "") + 32;
  }
  return bytes;
}

function entryBytes(entry: RelayConversationMessage): number {
  return contentBytes(entry.message.content) + 512;
}

function exactSession(value: RelaySession): boolean {
  return typeof value.id === "string" && value.id.length > 0
    && typeof value.endpointEpoch === "string" && value.endpointEpoch.length > 0;
}

export function validateRelayContent(content: RelayMessageContent, maxTextChars = MAX_RELAY_TEXT_CHARS, maxTextBytes: number | null = null): void {
  if (typeof content.text !== "string" || !content.text.trim() || content.text.length > maxTextChars || (maxTextBytes !== null && Buffer.byteLength(content.text) > maxTextBytes)) {
    throw new Error("message_text_out_of_bounds");
  }
  const attachments = content.attachments ?? [];
  if (attachments.length > MAX_RELAY_ATTACHMENTS) throw new Error("message_attachments_out_of_bounds");
  for (const attachment of attachments) {
    if (!(["file", "snippet", "context"] as const).includes(attachment.type)
      || !attachment.name || attachment.name.length > 200
      || attachment.content.length > MAX_RELAY_ATTACHMENT_CHARS
      || (attachment.language !== undefined && attachment.language.length > 80)) {
      throw new Error("message_attachment_out_of_bounds");
    }
  }
}

/**
 * Owns bounded in-memory relay state. It never resolves a target by name, retries
 * an unknown outcome, or changes browser focus in response to an incoming message.
 */
export class RelayState {
  private readonly client: RelayClient;
  private readonly publish: RelayStateOptions["publish"];
  private readonly sessions = new Map<string, RelaySession>();
  private readonly messages: RelayConversationMessage[] = [];
  private readonly seenInbound = new Set<string>();
  private readonly outboundActions = new Map<string, OutboundAction>();
  private memoryBytes = 0;

  constructor({ client, publish }: RelayStateOptions) {
    this.client = client;
    this.publish = publish;
    client.on("message", (from, message) => this.acceptInbound(from, message));
    client.on("roster", (sessions) => this.replaceRoster(sessions));
    client.on("connected", () => this.connectionChanged(true));
    client.on("disconnected", () => this.connectionChanged(false));
  }

  snapshot(): RelaySnapshot {
    return {
      connected: this.client.connected,
      endpoint: this.endpoint(),
      sessions: this.publicSessions(),
      messages: [...this.messages],
    };
  }

  publishSnapshot(): void { this.publish({ type: "relay_snapshot", snapshot: this.snapshot() }); }

  target(id: string, endpointEpoch: string): RelaySession | undefined {
    const session = this.sessions.get(id);
    return session?.endpointEpoch === endpointEpoch ? { ...session } : undefined;
  }

  replyTarget(messageId: string, senderId: string, senderEpoch: string): { messageId: string; senderId: string; senderEpoch: string } | undefined {
    const entry = this.messages.findLast((item) => item.direction === "inbound" && item.message.id === messageId);
    return entry && entry.from.id === senderId && entry.from.endpointEpoch === senderEpoch
      ? { messageId, senderId, senderEpoch }
      : undefined;
  }

  replaceRoster(values: RelaySession[]): void {
    this.sessions.clear();
    for (const session of values) {
      if (!exactSession(session) || session.id === this.client.sessionId || session.kind !== "agent") continue;
      this.sessions.set(session.id, { ...session });
    }
    this.publish({ type: "relay_roster", sessions: this.publicSessions() });
  }

  async refreshRoster(): Promise<void> {
    const sessions = await this.client.listSessions();
    this.replaceRoster(sessions);
  }

  async activateHuman(generation: string): Promise<{ id: string; endpointEpoch: string } | null> {
    const endpoint = this.client.activateHuman ? await this.client.activateHuman(generation) : this.endpoint();
    this.connectionChanged(this.client.connected);
    return endpoint;
  }

  async deactivateHuman(generation: string): Promise<void> {
    if (this.client.deactivateHuman) await this.client.deactivateHuman(generation);
    this.connectionChanged(this.client.connected);
  }

  send(input: {
    targetId: string;
    targetEpoch: string;
    text: string;
    attachments?: RelayAttachment[];
    reply?: { messageId: string; senderId: string; senderEpoch: string };
    expectsReply?: boolean;
    source: "human" | "voice";
    messageId?: string;
  }): Promise<RelayConversationMessage> {
    const messageId = input.messageId ?? randomUUID();
    const fingerprint = JSON.stringify([input.targetId, input.targetEpoch, input.text, input.attachments ?? [], input.reply ?? null, input.expectsReply ?? false, input.source]);
    const existing = this.outboundActions.get(messageId);
    if (existing) {
      if (existing.fingerprint !== fingerprint) return Promise.reject(new Error("duplicate_message_id_conflict"));
      return existing.promise;
    }
    const action: OutboundAction = { fingerprint, state: "pending", promise: Promise.resolve(null as never) };
    action.promise = this.performSend({ ...input, messageId }).then(
      (entry) => { action.state = "sent"; return entry; },
      (error: unknown) => { action.state = "failed"; throw error; },
    );
    this.outboundActions.set(messageId, action);
    while (this.outboundActions.size > 1024) {
      const oldest = this.outboundActions.keys().next().value;
      if (typeof oldest !== "string") break;
      if (this.outboundActions.get(oldest)?.state === "pending") break;
      this.outboundActions.delete(oldest);
    }
    return action.promise;
  }

  private async performSend(input: {
    targetId: string; targetEpoch: string; text: string; attachments?: RelayAttachment[];
    reply?: { messageId: string; senderId: string; senderEpoch: string };
    expectsReply?: boolean;
    source: "human" | "voice"; messageId: string;
  }): Promise<RelayConversationMessage> {
    const content: RelayMessageContent = { text: input.text, ...(input.attachments?.length ? { attachments: input.attachments } : {}) };
    if (input.source === "voice") validateRelayContent(content, MAX_RELAY_VOICE_TEXT_CHARS, MAX_RELAY_VOICE_TEXT_BYTES);
    else validateRelayContent(content);
    const target = this.sessions.get(input.targetId);
    if (!target || target.endpointEpoch !== input.targetEpoch) throw new Error("stale_relay_target");
    const own = this.endpoint();
    if (!own) throw new Error("relay_disconnected");
    if (input.reply && (input.reply.senderId !== target.id || input.reply.senderEpoch !== target.endpointEpoch)) throw new Error("reply_target_mismatch");
    let delivery: RelayDelivery;
    try {
      delivery = await this.client.sendExact(
        { id: target.id, endpointEpoch: target.endpointEpoch },
        { text: content.text, ...(content.attachments ? { attachments: content.attachments } : {}), ...(input.reply ? { replyTo: input.reply.messageId } : {}), ...(input.expectsReply ? { expectsReply: true } : {}), messageId: input.messageId },
      );
    } catch (error) {
      // A rejected native send may have crossed the socket before timeout/disconnect.
      // Without a broker delivery result its outcome is unknown and must never be replayed.
      throw new Error(`relay_delivery_unknown: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (!delivery.delivered) {
      const reason = delivery.reason ?? delivery.code ?? "delivery_failed";
      throw new Error(`${delivery.outcomeKnown ? "relay_delivery_failed" : "relay_delivery_unknown"}: ${reason}`);
    }
    const entry: RelayConversationMessage = {
      direction: "outbound", source: input.source, from: own,
      to: { id: target.id, endpointEpoch: target.endpointEpoch, ...(target.name ? { name: target.name } : {}) },
      message: { id: delivery.id, timestamp: Date.now(), ...(input.reply ? { replyTo: input.reply.messageId } : {}), ...(input.expectsReply ? { expectsReply: true } : {}), content },
      delivery,
    };
    this.remember(entry);
    this.publish({ type: "relay_message", entry });
    return entry;
  }

  private endpoint(): RelaySnapshot["endpoint"] {
    return this.client.connected && this.client.sessionId && this.client.endpointEpoch
      ? { id: this.client.sessionId, endpointEpoch: this.client.endpointEpoch, name: RELAY_NAME }
      : null;
  }

  private publicSessions(): RelaySession[] {
    return [...this.sessions.values()].sort((a, b) => (b.lastActivity - a.lastActivity) || (a.name ?? a.id).localeCompare(b.name ?? b.id));
  }

  private connectionChanged(connected: boolean): void {
    if (!connected) this.sessions.clear();
    this.publish({ type: "relay_connection", connected, endpoint: this.endpoint() });
    if (!connected) this.publish({ type: "relay_roster", sessions: [] });
  }

  private acceptInbound(from: RelaySession, message: RelayInboundMessage): void {
    if (!exactSession(from) || !message.id || this.seenInbound.has(message.id)) return;
    try {
      validateRelayContent(message.content);
    } catch {
      this.publish({ type: "relay_error", code: "incoming_message_out_of_bounds", message: `Dropped out-of-bounds native message ${message.id.slice(0, 80)} from ${from.id.slice(0, 80)}.` });
      return;
    }
    this.seenInbound.add(message.id);
    while (this.seenInbound.size > 1024) {
      const oldest = this.seenInbound.values().next().value;
      if (typeof oldest !== "string") break;
      this.seenInbound.delete(oldest);
    }
    const receiver = this.endpoint();
    const superseded = typeof message.supersedes === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(message.supersedes)
      ? [...this.messages].reverse().find((candidate) => candidate.direction === "inbound" && candidate.message.id === message.supersedes &&
          candidate.from.id === from.id && candidate.from.endpointEpoch === from.endpointEpoch && receiver !== null &&
          candidate.to?.id === receiver.id && candidate.to.endpointEpoch === receiver.endpointEpoch)
      : undefined;
    if (message.supersedes !== undefined && !superseded) {
      this.publish({ type: "relay_error", code: "incoming_supersedes_invalid", message: `Ignored invalid supersedes metadata on native message ${message.id.slice(0, 80)}.` });
    }
    const { supersedes: _untrustedSupersedes, ...messageWithoutSupersedes } = message;
    const entry: RelayConversationMessage = {
      direction: "inbound",
      source: "agent",
      from: { id: from.id, endpointEpoch: from.endpointEpoch, ...(from.name ? { name: from.name } : {}) },
      ...(receiver ? { to: { ...receiver } } : {}),
      message: { ...messageWithoutSupersedes, ...(superseded ? { supersedes: superseded.message.id } : {}), content: { ...message.content, ...(message.content.attachments ? { attachments: message.content.attachments.map((item) => ({ ...item })) } : {}) } },
    };
    this.remember(entry);
    this.publish({ type: "relay_message", entry });
  }

  private remember(entry: RelayConversationMessage): void {
    this.messages.push(entry);
    this.memoryBytes += entryBytes(entry);
    while (this.messages.length > MAX_RELAY_MESSAGES || this.memoryBytes > MAX_RELAY_MEMORY_BYTES) {
      const removed = this.messages.shift();
      if (!removed) break;
      this.memoryBytes -= entryBytes(removed);
    }
  }
}
