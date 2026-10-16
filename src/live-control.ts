import { createHash, randomUUID } from "node:crypto";
import type { LiveRoutingMode } from "./live.ts";
import { MAX_RELAY_VOICE_TEXT_BYTES, MAX_RELAY_VOICE_TEXT_CHARS } from "./relay.ts";

export const LIVE_IDLE_MS = 5 * 60_000;
export const LIVE_HARD_MS = 120 * 60_000;
export const LIVE_ACTIVITY_RMS = 700;
export const LIVE_ACTIVITY_MIN_MS = 240;
export const LIVE_TRANSCRIPT_CHARS = 16_000;
export const LIVE_UTTERANCE_STABLE_MS = 1_100;
export const LIVE_QUIET_HINT_MS = 240;
export const LIVE_PTT_TRAILING_MS = 1_100;
export const LIVE_CAPTION_BURST_QUIET_MS = 1_100;
export const LIVE_AGENT_SPEECH_CHARS = 16_000;
export const LIVE_AGENT_OUTPUT_QUIET_MS = 800;
export const LIVE_AGENT_MESSAGE_TTL_MS = 60_000;
export const LIVE_AGENT_MESSAGE_CAPACITY = 32;
export const LIVE_AGENT_MESSAGE_IDENTITY_CAPACITY = 256;
export const LIVE_HANDOFF_JOURNAL_BYTES = 256 * 1024;
export const LIVE_HANDOFF_RENDERED_BYTES = 48 * 1024;
export const LIVE_HANDOFF_CONTEXT_EVENTS = 512;
export const LIVE_HANDOFF_EVENT_IDS = 32_768;
const LIVE_FEEDBACK_EPOCHS = 32;
export type LiveInputMode = "continuous" | "ptt";
export type LiveDispatchBlockReason =
  | "journal_event_limit"
  | "journal_retained_byte_limit"
  | "rendered_reserve_byte_limit"
  | "event_identity_limit"
  | "event_identity_invalid"
  | "event_identity_conflict"
  | "delegation_identity_limit"
  | "delegation_queue_limit"
  | "wire_character_limit"
  | "wire_byte_limit"
  | "delivery_uncommitted"
  | "stale_cursor";

export type LiveSideband = {
  send(data: string): void;
  close(): void;
  /** Begin inbound delivery after all handlers are installed. Real sidebands start paused. */
  startReading?(): void;
};
export type LiveRecentTextEvent = {
  timestampMs: number;
  role: "user" | "assistant" | "application";
  kind: "transcript" | "delegation" | "delivery" | "ptt";
  text: string;
};
export type LiveProviderStartupDiagnostic = {
  source: "creation_response" | "sideband_session_started";
  model: string | null;
  delegationType: "client" | "responses" | null;
  store: boolean | null;
  voice: string | null;
  instructionsMatched: boolean | null;
};
export type LiveCloseRequestCode = "browser_stop" | "input_idle" | "hard_max" | "gateway_stopping" | "browser_connection_lost" | "device_revoked" | "native_relay_disconnected" | "native_human_endpoint_lost" | "other";
export type LiveTerminalCode = "provider_closed" | "close_timeout" | "sideband_disconnected";

export type LiveDiagnostics = {
  state: "active" | "closing" | "closed";
  arrivalSequence: number;
  events: { inputAudio: number; inputTranscriptDelta: number; outputTranscriptDelta: number; delegationCreated: number; errors: number; sessionClosed: number; other: number };
  provider: {
    startup: LiveProviderStartupDiagnostic;
    otherEventTypes: Array<{ type: string; count: number }>;
    otherEventTypeOverflow: number;
    primary: { source: "client_reported"; eventTypes: Array<{ type: string; count: number }>; overflow: number } | null;
  };
  pcm: { activityFrames: number; quietFrames: number; invalidFrames: number; quietHints: number };
  timing: {
    firstInputAudioOffsetMs: number | null;
    firstInputTranscriptOffsetMs: number | null;
    firstOutputTranscriptOffsetMs: number | null;
    firstDelegationOffsetMs: number | null;
    firstLiaisonRequestOffsetMs: number | null;
    closedOffsetMs: number | null;
    // Observation offsets are monotonic diagnostics. Deadline values are the exact
    // clock-basis timestamps used by enforcement and may move after clock adjustment.
    lastActualInputOffsetMs: number | null;
    inputIdleDeadlineAtMs: number;
    hardDeadlineAtMs: number;
  };
  ending: {
    requested: { code: LiveCloseRequestCode; offsetMs: number } | null;
    terminal: { code: LiveTerminalCode; offsetMs: number; providerClosed: boolean } | null;
  };
  routing: {
    ignoredDelegations: number;
    clientDelegations: number;
    utterances: number;
    liaisonRequests: number;
    inputMode: LiveInputMode;
    routingMode: LiveRoutingMode;
    pttHeld: boolean;
    pttAwaitingTrailing: boolean;
    pttHolds: number;
    pttReleases: number;
    pttCancels: number;
    delegationsWhilePttHeld: number;
    pendingDelegationAtClose: boolean;
    dispatchBlock: { reason: LiveDispatchBlockReason; used: number | null; limit: number | null } | null;
    delegationOutcomes: { accepted: number; emitted: number; expired: number; coalesced: number; cancelled: number; rejected: number };
    agentSpeech: {
      pendingText: number;
      activeText: number;
      identityCount: number;
      awaitingOutputObservation: boolean;
      neverAttempted: number;
      appendInFlight: number;
      providerAcceptedSpeechUnconfirmed: number;
      outputObservedUnattributed: number;
      appendUnknown: number;
      expired: number;
      superseded: number;
      correctionNeeded: number;
      outputActivityFrames: number;
      outputQuietFrames: number;
      outputInvalidFrames: number;
      entries: Array<{
        messageId: string;
        state: AgentSpeechState;
        receivedOffsetMs: number;
        stateOffsetMs: number;
        attemptedAppends: Array<{ eventId: string; chunkIndex: number; offsetMs: number }>;
        chunkCount: number;
        acknowledgedChunks: number;
        lastAcknowledgedOffsetMs: number | null;
        outputObserved: boolean;
        outputObservedOffsetMs: number | null;
        correctionNeeded: boolean;
      }>;
    };
    journal: {
      events: number;
      eventLimit: number;
      retainedBytes: number;
      retainedByteLimit: number;
      renderedReserveBytes: number;
      renderedReserveByteLimit: number;
    };
  };
};
export type LiveTerminalSnapshot = {
  control: LiveDiagnostics;
  recentText: LiveRecentTextEvent[];
  closure: { reason: string; providerClosed: boolean };
};
export type LiveClock = {
  now(): number;
  setTimeout(callback: () => void, delay: number): unknown;
  clearTimeout(handle: unknown): void;
};
export type LiveControlEvent =
  | { type: "voice_state"; state: "active" | "closing" | "closed"; idleDeadline: number; hardDeadline: number; reason?: string }
  | { type: "voice_caption"; speaker: "user" | "assistant"; delta: string; groupId: string | null }
  | { type: "voice_caption_stable"; speaker: "user"; groupId: string }
  | { type: "voice_utterance"; utteranceId: string; text: string; grouping: "bounded_transcript_stability" }
  | { type: "voice_liaison_request"; delegationId: string; requestId: string; text: string; grouping: "bounded_transcript_stability"; transcriptFromSequence: number; transcriptThroughSequence: number }
  | { type: "voice_ptt_ready" }
  | { type: "voice_agent_reply_window"; replyId: string; durationMs: number }
  | { type: "voice_error"; code: string; message: string }
  | { type: "voice_usage"; usage: unknown; complete: boolean };

const systemClock: LiveClock = {
  now: () => Date.now(),
  setTimeout: (callback, delay) => setTimeout(callback, delay),
  clearTimeout: (handle) => clearTimeout(handle as NodeJS.Timeout),
};

function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function truncateUtf8(text: string, maxBytes: number): string {
  let result = "", bytes = 0;
  for (const character of text) { const size = Buffer.byteLength(character); if (bytes + size > maxBytes) break; result += character; bytes += size; }
  return result;
}

function suffixUtf8(text: string, maxBytes: number): string {
  let result = "", bytes = 0;
  for (const character of Array.from(text).reverse()) { const size = Buffer.byteLength(character); if (bytes + size > maxBytes) break; result = character + result; bytes += size; }
  return result;
}

type HandoffTranscriptDelta = {
  sequence: number;
  role: "user" | "live_assistant";
  source: "session.input_transcript.delta" | "session.output_transcript.delta";
  eventId: string | null;
  startMs: number | null;
  endMs: number | null;
  timelineOrderValid: boolean;
  userUtteranceId: number | null;
  delta: string;
};

type HandoffBodyPart = { sequence: number; text: string };
type HandoffBodyTurn = { role: HandoffTranscriptDelta["role"]; parts: HandoffBodyPart[]; userUtteranceId: number | null };
export type AgentSpeechState = "never_attempted" | "append_in_flight" | "provider_accepted_speech_unconfirmed" | "output_observed_unattributed" | "append_unknown" | "expired" | "superseded";
type AgentSpeechLedgerEntry = {
  state: AgentSpeechState;
  receivedOffsetMs: number;
  stateOffsetMs: number;
  appendAttempts: Array<{ eventId: string; chunkIndex: number; offsetMs: number }>;
  chunkCount: number;
  acknowledgedChunks: number;
  lastAcknowledgedOffsetMs: number | null;
  outputObserved: boolean;
  outputObservedOffsetMs: number | null;
  correctionNeeded: boolean;
};
type PendingAgentMessage = { messageId: string; senderIdentityHash: string; senderLabel: string; text: string; delegationId: string | null; expiresAt: number };
type AppendEntry = {
  type: "session.instructions.append" | "session.thinking.append" | "session.commentary.append";
  event_id: string;
  delegation_id: string | null;
  content: string;
  agentMessageId: string | null;
  agentChunkIndex: number | null;
  agentChunkCount: number | null;
};

const LIVE_BACKCHANNEL_FILLERS = new Set([".", "huh", "huh.", "hm", "hm.", "hmm", "hmm.", "mm", "mm.", "mhm", "mhm.", "uh", "uh.", "uh-huh", "uh-huh."]);

function handoffBodyTurnText(turn: HandoffBodyTurn): string { return turn.parts.map((part) => part.text).join(""); }

function isLiveBackchannelFiller(text: string): boolean {
  const canonical = text.trim().toLowerCase();
  if (!/^[a-z.\-]+$/.test(canonical) || !LIVE_BACKCHANNEL_FILLERS.has(canonical)) return false;
  return (canonical.match(/[a-z]+(?:-[a-z]+)?/g) ?? []).length <= 3;
}

function oneLineTranscriptText(text: string): string {
  return text.replace(/[\\\u0000-\u001f\u007f-\u009f\u2028\u2029]/gu, (character) => {
    if (character === "\\") return "\\\\";
    if (character === "\n") return "\\n";
    if (character === "\r") return "\\r";
    if (character === "\t") return "\\t";
    return `\\u${character.codePointAt(0)!.toString(16).padStart(4, "0")}`;
  });
}

function handoffEventFingerprint(
  role: HandoffTranscriptDelta["role"],
  source: HandoffTranscriptDelta["source"],
  startMs: number | null,
  endMs: number | null,
  delta: string,
): string {
  return createHash("sha256").update(JSON.stringify([role, source, startMs, endMs, delta])).digest("hex");
}

function handoffEntryRetainedBytes(entry: HandoffTranscriptDelta): number {
  return Buffer.byteLength(JSON.stringify(entry)) + 128;
}

function handoffEntryRenderedReserveBytes(entry: HandoffTranscriptDelta): number {
  // Reserve the largest current formatter output for this entry as a standalone
  // line. Every User line gets the optional arrow; grouping can only replace a
  // label/newline with one space, so the sum remains a conservative upper bound.
  const speaker = entry.role === "user" ? "→ User" : "Live";
  return Buffer.byteLength(`${speaker}: ${oneLineTranscriptText(entry.delta)}\n`);
}

function appendHandoffBodyTurn(turns: HandoffBodyTurn[], turn: HandoffBodyTurn): void {
  const last = turns.at(-1);
  const sequenceIsContiguous = last !== undefined && last.parts.at(-1)!.sequence + 1 === turn.parts[0]!.sequence;
  const sameUserUtterance = last?.role !== "user" || last.userUtteranceId === turn.userUtteranceId;
  if (last?.role === turn.role && sequenceIsContiguous && sameUserUtterance) last.parts.push(...turn.parts);
  else turns.push(turn);
}

export function formatHandoffBody(entries: readonly HandoffTranscriptDelta[], currentRequestFromSequence: number | null, currentRequestThroughSequence: number | null): string {
  const turns: HandoffBodyTurn[] = [];
  for (let index = 0; index < entries.length;) {
    const entry = entries[index]!;
    // Presentation-only exception: reorder only fully bracketed, whitelisted Live
    // fillers that share this exact local transcript-stability/PTT group.
    if (entry.role === "user" && entry.userUtteranceId !== null) {
      let lastUserIndex = index;
      for (let candidate = index + 1; candidate < entries.length; candidate++) {
        const later = entries[candidate]!;
        if (later.role === "user" && later.userUtteranceId === entry.userUtteranceId) lastUserIndex = candidate;
      }
      if (lastUserIndex > index) {
        const span = entries.slice(index, lastUserIndex + 1);
        const fillerTurns: HandoffBodyTurn[] = [];
        let valid = true;
        for (let spanIndex = 0; spanIndex < span.length;) {
          const item = span[spanIndex]!;
          if (item.role === "user" && item.userUtteranceId === entry.userUtteranceId) { spanIndex++; continue; }
          if (item.role !== "live_assistant" || item.userUtteranceId !== entry.userUtteranceId) { valid = false; break; }
          const filler: HandoffBodyTurn = { role: "live_assistant", parts: [{ sequence: item.sequence, text: item.delta }], userUtteranceId: item.userUtteranceId };
          spanIndex++;
          while (spanIndex < span.length) {
            const fragment = span[spanIndex]!;
            if (fragment.role !== "live_assistant" || fragment.userUtteranceId !== entry.userUtteranceId || filler.parts.at(-1)!.sequence + 1 !== fragment.sequence) break;
            filler.parts.push({ sequence: fragment.sequence, text: fragment.delta }); spanIndex++;
          }
          if (!isLiveBackchannelFiller(handoffBodyTurnText(filler))) { valid = false; break; }
          fillerTurns.push(filler);
        }
        if (valid && fillerTurns.length > 0) {
          const userItems = span.filter((item) => item.role === "user") as HandoffTranscriptDelta[];
          turns.push({ role: "user", parts: userItems.map((item) => ({ sequence: item.sequence, text: item.delta })), userUtteranceId: entry.userUtteranceId });
          turns.push(...fillerTurns);
          index = lastUserIndex + 1;
          continue;
        }
      }
    }
    appendHandoffBodyTurn(turns, { role: entry.role, parts: [{ sequence: entry.sequence, text: entry.delta }], userUtteranceId: entry.userUtteranceId });
    index++;
  }

  const partIsCurrent = (part: HandoffBodyPart) => currentRequestFromSequence !== null && currentRequestThroughSequence !== null && part.sequence >= currentRequestFromSequence && part.sequence <= currentRequestThroughSequence;
  const rangeSplitTurns = turns.flatMap((turn) => {
    if (turn.role !== "user" || currentRequestFromSequence === null || currentRequestThroughSequence === null) return [turn];
    const split: HandoffBodyTurn[] = [];
    for (const part of turn.parts) {
      const last = split.at(-1);
      if (last && partIsCurrent(last.parts[0]!) === partIsCurrent(part)) last.parts.push(part);
      else split.push({ role: "user", parts: [part], userUtteranceId: turn.userUtteranceId });
    }
    return split;
  });
  const currentTurnIndexes = new Set(rangeSplitTurns.flatMap((turn, index) => turn.role === "user" && turn.parts.every(partIsCurrent) ? [index] : []));
  const userTurnIndexes = rangeSplitTurns.flatMap((turn, index) => turn.role === "user" ? [index] : []);
  const currentIndexes = [...currentTurnIndexes];
  const trailingUserIndexes = userTurnIndexes.slice(-currentIndexes.length);
  const arrowNeeded = currentIndexes.length > 0 && (currentIndexes.length !== trailingUserIndexes.length || currentIndexes.some((index, offset) => index !== trailingUserIndexes[offset]));
  return rangeSplitTurns.map((turn, index) => `${turn.role === "user" ? arrowNeeded && currentTurnIndexes.has(index) ? "→ User" : "User" : "Live"}: ${oneLineTranscriptText(handoffBodyTurnText(turn))}`).join("\n");
}

function splitForLiveAppend(text: string, maxBytes: number): string[] {
  const chunks: string[] = []; let chunk = "", bytes = 0;
  for (const character of text) {
    const size = Buffer.byteLength(character);
    if (chunk && bytes + size > maxBytes) { chunks.push(chunk); chunk = ""; bytes = 0; }
    chunk += character; bytes += size;
  }
  if (chunk || chunks.length === 0) chunks.push(chunk);
  return chunks;
}

export function pcm16Rms(base64: string): { rms: number; durationMs: number } | null {
  if (base64.length === 0 || base64.length % 4 !== 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(base64)) return null;
  let bytes: Buffer;
  try { bytes = Buffer.from(base64, "base64"); } catch { return null; }
  if (bytes.toString("base64") !== base64) return null;
  if (bytes.length < 2 || bytes.length % 2 !== 0) return null;
  let sum = 0;
  for (let offset = 0; offset < bytes.length; offset += 2) {
    const sample = bytes.readInt16LE(offset);
    sum += sample * sample;
  }
  const samples = bytes.length / 2;
  return { rms: Math.sqrt(sum / samples), durationMs: samples / 24 };
}

/** Server-side single owner for Live routing, deadlines, transcript staging, and graceful close. */
export class LiveControl {
  private readonly socket: LiveSideband;
  private readonly clock: LiveClock;
  private readonly publish: (event: LiveControlEvent) => void;
  private readonly onClosed: () => void;
  private readonly startedAt: number;
  private lastActualInputAt: number;
  private lastActualInputObservedOffsetMs: number | null = null;
  private closeRequest: { code: LiveCloseRequestCode; offsetMs: number } | null = null;
  private timer: unknown = null;
  private closeTimer: unknown = null;
  private utteranceTimer: unknown = null;
  private assistantCaptionBurstTimer: unknown = null;
  private agentReplyTimer: unknown = null;
  private agentMessageExpiryTimer: unknown = null;
  private appendAckTimer: unknown = null;
  private readonly appendQueue: AppendEntry[] = [];
  private appendInFlight: AppendEntry | null = null;
  private greetingEnqueued = false;
  private readonly greeting: string;
  private lastProviderOutputAt = Number.NEGATIVE_INFINITY;
  private readonly outputPcmCounts = { activityFrames: 0, quietFrames: 0, invalidFrames: 0 };
  private activeAgentMessageId: string | null = null;
  private activeAgentOutputObserved = false;
  private awaitingAgentOutputId: string | null = null;
  private state: "active" | "closing" | "closed" = "active";
  private activeAudioMs = 0;
  private quietAudioMs = 0;
  private quietThresholdReached = false;
  private transcriptFragments: Array<{ sequence: number; text: string; handoffSequence: number | null }> = [];
  private transcriptChars = 0;
  private nextTranscriptSequence = 1;
  // Local structural grouping only; this is not a provider-final-turn or intent claim.
  private activeUserUtteranceId: number | null = null;
  private nextUserUtteranceId = 1;
  private activeAssistantCaptionBurstId: number | null = null;
  private nextAssistantCaptionBurstId = 1;
  private arrivalSequence = 0;
  private readonly eventCounts = { inputAudio: 0, inputTranscriptDelta: 0, outputTranscriptDelta: 0, delegationCreated: 0, errors: 0, sessionClosed: 0, other: 0 };
  private readonly otherEventTypes = new Map<string, number>();
  private otherEventTypeOverflow = 0;
  private providerStartup: LiveProviderStartupDiagnostic;
  private readonly resolveProviderStartup: ((session: unknown) => LiveProviderStartupDiagnostic) | undefined;
  private primaryEventTypes: Array<{ type: string; count: number }> = [];
  private primaryEventOverflow = 0;
  private primaryReportSequence = 0;
  private primaryReportAt = Number.NEGATIVE_INFINITY;
  private readonly pcmCounts = { activityFrames: 0, quietFrames: 0, invalidFrames: 0, quietHints: 0 };
  private readonly routingCounts = { ignoredDelegations: 0, clientDelegations: 0, utterances: 0, liaisonRequests: 0 };
  private readonly delegationOutcomes = { accepted: 0, emitted: 0, expired: 0, coalesced: 0, cancelled: 0, rejected: 0 };
  private readonly timing = {
    firstInputAudioOffsetMs: null as number | null,
    firstInputTranscriptOffsetMs: null as number | null,
    firstOutputTranscriptOffsetMs: null as number | null,
    firstDelegationOffsetMs: null as number | null,
    firstLiaisonRequestOffsetMs: null as number | null,
  };
  private readonly pttCounts = { holds: 0, releases: 0, cancels: 0, delegationsWhileHeld: 0 };
  private lastMonotonicOffsetMs = 0;
  private terminalValue: LiveTerminalSnapshot | null = null;
  private closingEvidence: { control: LiveDiagnostics; recentText: LiveRecentTextEvent[] } | null = null;
  private recentTextEvents: LiveRecentTextEvent[] = [];
  private readonly pendingAgentMessages: PendingAgentMessage[] = [];
  private readonly agentMessageLedger = new Map<string, AgentSpeechLedgerEntry>();
  private lastSpokenAgentIdentity: string | null = null;
  private readonly inputMode: LiveInputMode;
  private readonly idleTimeoutMs: number;
  private readonly routingMode: LiveRoutingMode;
  private readonly seenDelegations = new Set<string>();
  private readonly feedbackUserInputEpochs = new Set<number>();
  private lastAcceptedUserInputEpoch: number | null = null;
  private readonly pendingDelegations: Array<{ id: string; currentRequestFromSequence: number | null; userInputEpoch: number | null }> = [];
  private pendingDelegationTimer: unknown = null;
  private liaisonAwaitingNewInput = false;
  private readonly liaisonContext: Array<{ text: string; fromSequence: number | null; throughSequence: number | null }> = [];
  private readonly liaisonReadyQueue: Array<{ delegationId: string; text: string; currentRequestFromSequence: number | null; currentRequestThroughSequence: number | null; throughSequence: number; userInputEpoch: number | null }> = [];
  private readonly handoffTranscript: HandoffTranscriptDelta[] = [];
  private readonly handoffEventIds = new Map<string, string>();
  private handoffRetainedBytes = 0;
  private handoffRenderedReserveBytes = 0;
  private nextHandoffSequence = 1;
  private committedHandoffSequence = 0;
  private lastHandoffStartMs: number | null = null;
  private liaisonDispatchInFlight: { requestId: string; fromSequence: number; throughSequence: number } | null = null;
  private liaisonDispatchBlocked: "overflow" | "integrity" | "delivery" | null = null;
  private liaisonDispatchBlock: { reason: LiveDispatchBlockReason; used: number | null; limit: number | null } | null = null;
  private pttHeld = false;
  private pttAwaitingTrailing = false;
  private pttHoldStartHandoffSequence: number | null = null;
  private pttHoldStartPendingDelegations: number | null = null;
  private pttHoldStartReadyQueue: number | null = null;
  private pttHoldStartLiaisonContext: number | null = null;
  private pttCommandSequence = 0;
  private resolveClosed!: () => void;
  private readonly closedPromise = new Promise<void>((resolve) => { this.resolveClosed = resolve; });

  constructor(options: { socket: LiveSideband; publish: (event: LiveControlEvent) => void; onClosed: () => void; inputMode?: LiveInputMode; routingMode?: LiveRoutingMode; idleTimeoutMs?: number; clock?: LiveClock; providerStartup?: LiveProviderStartupDiagnostic; resolveProviderStartup?: (session: unknown) => LiveProviderStartupDiagnostic; greeting?: string }) {
    this.socket = options.socket;
    this.publish = options.publish;
    this.onClosed = options.onClosed;
    this.clock = options.clock ?? systemClock;
    this.idleTimeoutMs = options.idleTimeoutMs ?? LIVE_IDLE_MS;
    if (!Number.isSafeInteger(this.idleTimeoutMs) || this.idleTimeoutMs < 60_000 || this.idleTimeoutMs > 30 * 60_000) throw new RangeError("Invalid idle timeout");
    this.inputMode = options.inputMode ?? "continuous";
    this.routingMode = options.routingMode ?? "direct";
    this.providerStartup = options.providerStartup ?? { source: "creation_response", model: null, delegationType: null, store: null, voice: null, instructionsMatched: null };
    this.resolveProviderStartup = options.resolveProviderStartup;
    this.greeting = options.greeting ?? "Hello there.";
    if (this.greeting.length < 1 || this.greeting.length > 160 || Buffer.byteLength(this.greeting) > 256 || /[\p{Cc}\p{Cf}\p{Cs}\p{Co}\p{Cn}]/u.test(this.greeting)) throw new RangeError("Invalid greeting");
    this.startedAt = this.clock.now();
    this.lastActualInputAt = this.startedAt;
    this.publishState("active");
    this.armDeadline();
  }

  get active(): boolean { return this.state === "active"; }
  get occupied(): boolean { return this.state !== "closed"; }
  get deadlines(): { idleDeadline: number; hardDeadline: number } { return { idleDeadline: this.lastActualInputAt + this.idleTimeoutMs, hardDeadline: this.startedAt + LIVE_HARD_MS }; }
  waitClosed(): Promise<void> { return this.closedPromise; }
  get diagnostics(): LiveDiagnostics { return this.snapshotDiagnostics(this.state, this.state === "active"); }
  get recentText(): LiveRecentTextEvent[] { return this.state === "active" ? this.copyRecentText() : []; }
  takeTerminalSnapshot(): LiveTerminalSnapshot | null {
    const terminal = this.terminalValue;
    this.terminalValue = null;
    this.closingEvidence = null;
    if (!terminal) return null;
    return {
      control: structuredClone(terminal.control),
      recentText: terminal.recentText.map((event) => ({ ...event })),
      closure: { ...terminal.closure },
    };
  }

  recordDeliveryDiagnostic(text: string): void { this.appendRecentText("application", "delivery", text); }

  resolveLiaisonDispatch(requestId: string, fromSequence: number, throughSequence: number, committed: boolean): boolean {
    const pending = this.liaisonDispatchInFlight;
    if (this.state !== "active" || !pending || pending.requestId !== requestId || pending.fromSequence !== fromSequence || pending.throughSequence !== throughSequence || this.committedHandoffSequence !== fromSequence) return false;
    this.liaisonDispatchInFlight = null;
    if (!committed) {
      this.blockLiaisonDispatch("delivery", "delivery_uncommitted", null, null, "The transcript-bearing agent task was not confirmed delivered; it was not retried. End and explicitly start a new voice session.");
      return true;
    }
    if (throughSequence < this.committedHandoffSequence) {
      this.blockLiaisonDispatch("integrity", "stale_cursor", throughSequence, this.committedHandoffSequence, "A stale transcript cursor acknowledgement was rejected.");
      return false;
    }
    this.committedHandoffSequence = throughSequence;
    for (let index = this.handoffTranscript.length - 1; index >= 0; index--) if (this.handoffTranscript[index]!.sequence <= throughSequence) this.handoffTranscript.splice(index, 1);
    this.recountHandoffTranscriptBudgets();
    this.tryEmitLiaisonRequest();
    return true;
  }

  enqueueGreeting(): 0 | 1 {
    if (this.state !== "active" || this.greetingEnqueued) return 0;
    // Consume the one-shot authority before queueing. An unknown acknowledgement
    // outcome must never cause a second greeting.
    this.greetingEnqueued = true;
    this.enqueueAppend("session.commentary.append", null, this.greeting);
    return 1;
  }

  recordPrimaryEventTypes(sequence: number, eventTypes: Array<{ type: string; count: number }>, overflow: number): "accepted" | "stale" | "rate_limited" {
    if (this.state !== "active" || sequence <= this.primaryReportSequence) return "stale";
    const now = this.clock.now();
    if (now - this.primaryReportAt < 1_000) return "rate_limited";
    this.primaryReportSequence = sequence; this.primaryReportAt = now;
    this.primaryEventTypes = eventTypes.map((entry) => ({ type: entry.type, count: entry.count })); this.primaryEventOverflow = overflow;
    return "accepted";
  }

  receive(raw: string): void {
    if (this.state === "closed") return;
    let parsed: unknown;
    try { parsed = JSON.parse(raw); } catch { return; }
    const event = record(parsed); this.arrivalSequence++;
    if ((event.type === "session.instructions.appended" || event.type === "session.thinking.appended" || event.type === "session.commentary.appended") && typeof event.client_event_id === "string" && event.client_event_id === this.appendInFlight?.event_id) {
      const acknowledged = this.appendInFlight;
      if (acknowledged.agentMessageId && acknowledged.agentChunkIndex) {
        this.updateAgentMessage(acknowledged.agentMessageId, { acknowledgedChunks: acknowledged.agentChunkIndex, lastAcknowledgedOffsetMs: this.monotonicOffsetMs() });
      }
      if (this.appendAckTimer) this.clock.clearTimeout(this.appendAckTimer);
      this.appendAckTimer = null; this.appendInFlight = null;
      if (acknowledged.agentMessageId && acknowledged.agentChunkIndex === acknowledged.agentChunkCount) {
        this.updateAgentMessage(acknowledged.agentMessageId, {
          state: this.activeAgentOutputObserved ? "output_observed_unattributed" : "provider_accepted_speech_unconfirmed",
          acknowledgedChunks: acknowledged.agentChunkCount ?? 0,
          lastAcknowledgedOffsetMs: this.monotonicOffsetMs(),
          outputObserved: this.activeAgentOutputObserved,
        });
        this.activeAgentMessageId = null;
        this.awaitingAgentOutputId = this.activeAgentOutputObserved ? null : acknowledged.agentMessageId;
        this.activeAgentOutputObserved = false;
      }
      this.flushAppendQueue(); this.recordOtherEvent(event.type); return;
    }
    if (event.type === "session.started" && this.state === "active" && this.resolveProviderStartup && this.providerStartup.source !== "sideband_session_started") {
      this.providerStartup = this.resolveProviderStartup(event.session);
      this.recordOtherEvent(event.type);
    } else if (event.type === "session.input_audio.append" && typeof event.audio === "string") {
      this.eventCounts.inputAudio++; this.markFirst("firstInputAudioOffsetMs"); this.inputAudio(event.audio);
    }
    else if (event.type === "session.input_transcript.delta" && typeof event.delta === "string") {
      if (this.handoffTranscriptReplayStatus("user", "session.input_transcript.delta", event) !== "new") return;
      this.eventCounts.inputTranscriptDelta++; this.markFirst("firstInputTranscriptOffsetMs");
      this.appendRecentText("user", "transcript", event.delta);
      const acceptsForBuffer = event.delta.length > 0 && !(this.inputMode === "ptt" && !this.pttHeld && !this.pttAwaitingTrailing);
      if (acceptsForBuffer && this.activeUserUtteranceId === null) {
        this.activeUserUtteranceId = this.nextUserUtteranceId++;
        this.lastAcceptedUserInputEpoch = this.activeUserUtteranceId;
      }
      if (acceptsForBuffer) this.endAssistantCaptionBurst();
      const userUtteranceId = acceptsForBuffer ? this.activeUserUtteranceId : null;
      const handoffResult = acceptsForBuffer ? this.appendHandoffTranscript("user", "session.input_transcript.delta", event, userUtteranceId) : null;
      if (handoffResult !== "duplicate") this.appendTranscript(event.delta, typeof handoffResult === "number" ? handoffResult : null);
      this.publish({ type: "voice_caption", speaker: "user", delta: event.delta, groupId: userUtteranceId === null ? null : `user-${userUtteranceId}` });
    } else if (event.type === "session.output_audio.delta") {
      this.recordOtherEvent(event.type);
      if (typeof event.delta === "string") this.observeProviderOutputAudio(event.delta);
    } else if (event.type === "session.output_transcript.delta" && typeof event.delta === "string") {
      if (this.handoffTranscriptReplayStatus("live_assistant", "session.output_transcript.delta", event) !== "new") return;
      this.eventCounts.outputTranscriptDelta++; this.markFirst("firstOutputTranscriptOffsetMs");
      this.appendRecentText("assistant", "transcript", event.delta);
      this.appendHandoffTranscript("live_assistant", "session.output_transcript.delta", event, this.transcriptFragments.length > 0 ? this.activeUserUtteranceId : null);
      this.publish({ type: "voice_caption", speaker: "assistant", delta: event.delta, groupId: this.continueAssistantCaptionBurst() });
    } else if (event.type === "session.delegation.created") {
      this.eventCounts.delegationCreated++; this.markFirst("firstDelegationOffsetMs");
      if (this.pttHeld) this.pttCounts.delegationsWhileHeld++;
      this.appendRecentText("application", "delegation", "created");
      const delegation = record(event.delegation);
      const validDelegationId = typeof delegation.id === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(delegation.id);
      const delegationId = validDelegationId ? delegation.id as string : null;
      const isClientDelegation = this.routingMode === "liaison" && delegation.target === "client" && delegation.type === "delegation" && delegationId !== null;
      const isNewClientDelegation = isClientDelegation && !this.seenDelegations.has(delegationId);
      if (isClientDelegation && this.liaisonDispatchBlocked) {
        const userInputEpoch = isNewClientDelegation ? this.lastAcceptedUserInputEpoch : null;
        if (isNewClientDelegation && this.seenDelegations.size < 256) this.seenDelegations.add(delegationId);
        this.routingCounts.ignoredDelegations++; this.delegationOutcomes.rejected++;
        this.rejectDelegationAfterDispatchBlock(delegationId, userInputEpoch);
      } else if (isNewClientDelegation && this.seenDelegations.size >= 256) {
        this.blockLiaisonDispatch("overflow", "delegation_identity_limit", this.seenDelegations.size + 1, 256, "The Live delegation identity bound was reached; no agent task was sent.");
        this.routingCounts.ignoredDelegations++; this.delegationOutcomes.rejected++;
        this.rejectDelegationAfterDispatchBlock(delegationId, this.lastAcceptedUserInputEpoch);
      } else if (isNewClientDelegation && !this.liaisonAwaitingNewInput) {
        this.seenDelegations.add(delegationId);
        if (this.pendingDelegations.length + this.liaisonReadyQueue.length >= 32) {
          this.blockLiaisonDispatch("overflow", "delegation_queue_limit", this.pendingDelegations.length + this.liaisonReadyQueue.length + 1, 32, "Too many Live handoffs were waiting; no agent task was guessed or partially sent.");
          this.routingCounts.ignoredDelegations++; this.delegationOutcomes.rejected++;
          this.rejectDelegationAfterDispatchBlock(delegationId, this.lastAcceptedUserInputEpoch);
        } else {
          const currentRequestFromSequence = this.transcriptFragments.flatMap((fragment) => fragment.handoffSequence === null ? [] : [fragment.handoffSequence]).at(0) ?? null;
          this.pendingDelegations.push({ id: delegationId, currentRequestFromSequence, userInputEpoch: this.lastAcceptedUserInputEpoch });
          this.routingCounts.clientDelegations++; this.delegationOutcomes.accepted++;
          this.pairLiaisonWork(); this.armPendingDelegationExpiry(); this.tryEmitLiaisonRequest();
        }
      } else {
        if (delegationId !== null && this.seenDelegations.size < 256) this.seenDelegations.add(delegationId);
        this.routingCounts.ignoredDelegations++; this.delegationOutcomes.rejected++;
      }
    } else if (event.type === "error") {
      this.eventCounts.errors++;
      const detail = record(event.error);
      this.publish({ type: "voice_error", code: clean(detail.code, 80) || "live_error", message: clean(detail.message, 300) || "Unknown Live error" });
    } else if (event.type === "session.closed") {
      this.eventCounts.sessionClosed++;
      this.publish({ type: "voice_usage", usage: event.usage, complete: true });
      this.finish("provider_closed");
    } else this.recordOtherEvent(event.type);
  }

  private recordOtherEvent(rawType: unknown): void {
    this.eventCounts.other++;
    const type = typeof rawType === "string" && /^[A-Za-z0-9._-]{1,80}$/.test(rawType) ? rawType : "<invalid>";
    const count = this.otherEventTypes.get(type);
    if (count !== undefined) this.otherEventTypes.set(type, count + 1);
    else if (this.otherEventTypes.size < 32) this.otherEventTypes.set(type, 1);
    else this.otherEventTypeOverflow++;
  }

  setPushToTalkHeld(held: boolean, cancel = false, commandSequence = this.pttCommandSequence + 1): boolean {
    if (this.inputMode !== "ptt" || this.state !== "active" || !Number.isSafeInteger(commandSequence) || commandSequence <= this.pttCommandSequence) return false;
    this.pttCommandSequence = commandSequence;
    if (held) {
      if (this.pttHeld || this.pttAwaitingTrailing) return false;
      this.pttCounts.holds++;
      this.transcriptFragments = []; this.transcriptChars = 0; this.activeUserUtteranceId = null; this.pttHeld = true;
      this.pttHoldStartHandoffSequence = this.nextHandoffSequence;
      this.pttHoldStartPendingDelegations = this.pendingDelegations.length;
      this.pttHoldStartReadyQueue = this.liaisonReadyQueue.length;
      this.pttHoldStartLiaisonContext = this.liaisonContext.length;
      this.liaisonAwaitingNewInput = false;
      this.appendRecentText("application", "ptt", "held");
      if (this.agentReplyTimer) { this.clock.clearTimeout(this.agentReplyTimer); this.agentReplyTimer = null; }
      return true;
    }
    const wasHeld = this.pttHeld;
    this.pttHeld = false;
    this.appendRecentText("application", "ptt", cancel || !wasHeld ? "cancelled" : "released");
    if (cancel || !wasHeld) {
      this.pttCounts.cancels++;
      const cancelledCaptionGroupId = this.activeUserUtteranceId === null ? null : `user-${this.activeUserUtteranceId}`;
      if (this.utteranceTimer) { this.clock.clearTimeout(this.utteranceTimer); this.utteranceTimer = null; }
      if (this.pttHoldStartHandoffSequence !== null) {
        for (let index = this.handoffTranscript.length - 1; index >= 0; index--) {
          const entry = this.handoffTranscript[index]!;
          if (entry.role === "user" && entry.sequence >= this.pttHoldStartHandoffSequence) this.handoffTranscript.splice(index, 1);
        }
        this.recountHandoffTranscriptBudgets();
      }
      this.transcriptFragments = []; this.transcriptChars = 0; this.activeUserUtteranceId = null; this.pttAwaitingTrailing = false;
      if (this.routingMode === "liaison") { this.cancelCurrentPTTLiaisonWork(); this.liaisonAwaitingNewInput = true; }
      else this.clearPTTHoldBoundaries();
      if (cancelledCaptionGroupId !== null) this.publish({ type: "voice_caption_stable", speaker: "user", groupId: cancelledCaptionGroupId });
      this.armAgentReply(); this.publish({ type: "voice_ptt_ready" });
      return true;
    }
    this.pttCounts.releases++;
    this.pttAwaitingTrailing = true;
    this.armUtterance(LIVE_PTT_TRAILING_MS); this.armAgentReply();
    return true;
  }

  appendStatus(text: string): void {
    if (this.state !== "active") return;
    this.enqueueAppend("session.commentary.append", null, truncateUtf8(text, 400));
  }

  appendDelegationStatus(delegationId: string, text: string, spoken = false): void {
    if (this.state !== "active" || this.routingMode !== "liaison" || !this.seenDelegations.has(delegationId)) return;
    this.enqueueAppend(spoken ? "session.commentary.append" : "session.thinking.append", delegationId, truncateUtf8(text, 400));
  }

  appendIncomingAgentMessage(messageId: string, senderIdentity: string, senderLabel: string, text: string, delegationId: string | null = null, supersedesMessageId: string | null = null): void {
    if (this.state !== "active") return;
    if (!/^[A-Za-z0-9_-]{1,200}$/.test(messageId)) {
      this.publish({ type: "voice_error", code: "agent_reply_invalid_identity", message: "An incoming agent update had no safe exact identity and was not queued for speech." });
      return;
    }
    if (this.agentMessageLedger.has(messageId)) return;
    if (this.agentMessageLedger.size >= LIVE_AGENT_MESSAGE_IDENTITY_CAPACITY) {
      this.publish({ type: "voice_error", code: "agent_reply_identity_capacity", message: "The same-call agent update identity bound was reached; later updates remain in the native agent view." });
      return;
    }
    const senderIdentityHash = createHash("sha256").update(senderIdentity).digest("hex");
    if (supersedesMessageId && /^[A-Za-z0-9_-]{1,200}$/.test(supersedesMessageId)) {
      const superseded = this.agentMessageLedger.get(supersedesMessageId);
      if (superseded?.state === "never_attempted") {
        const pendingIndex = this.pendingAgentMessages.findIndex((pending) => pending.messageId === supersedesMessageId && pending.senderIdentityHash === senderIdentityHash);
        if (pendingIndex >= 0) {
          this.pendingAgentMessages.splice(pendingIndex, 1);
          this.updateAgentMessage(supersedesMessageId, { state: "superseded" });
          this.publish({ type: "voice_error", code: "agent_reply_superseded", message: "A queued agent update was explicitly superseded before speech was attempted." });
          this.armAgentMessageExpiry();
        }
      } else if (superseded && superseded.state !== "expired" && superseded.state !== "superseded") {
        this.updateAgentMessage(supersedesMessageId, { correctionNeeded: true });
        this.publish({ type: "voice_error", code: "agent_reply_correction_needed", message: "An explicitly superseded update may already have reached the provider; it was not erased or replayed." });
      }
    }
    const boundedLabel = truncateUtf8(senderLabel.replace(/[\u0000-\u001f\u007f]/g, " "), 60);
    const characters = Array.from(text);
    if (characters.length > LIVE_AGENT_SPEECH_CHARS) {
      this.beginAgentMessage(messageId, "expired");
      this.publish({ type: "voice_error", code: "agent_reply_too_long", message: "The focused agent reply is too long to speak safely; read it in the native agent view." });
      return;
    }
    if (this.pendingAgentMessages.length + (this.activeAgentMessageId ? 1 : 0) >= LIVE_AGENT_MESSAGE_CAPACITY) {
      this.beginAgentMessage(messageId, "expired");
      this.publish({ type: "voice_error", code: "agent_reply_queue_full", message: "Too many agent replies are waiting for speech; read them in the native agent view." });
      return;
    }
    this.beginAgentMessage(messageId, "never_attempted");
    this.pendingAgentMessages.push({ messageId, senderIdentityHash, senderLabel: boundedLabel, text, delegationId, expiresAt: this.clock.now() + LIVE_AGENT_MESSAGE_TTL_MS });
    this.armAgentMessageExpiry();
    this.armAgentReply();
  }

  close(reason: string): void {
    if (this.state !== "active") return;
    this.closeRequest = { code: safeCloseRequestCode(reason), offsetMs: this.monotonicOffsetMs() };
    this.closingEvidence = this.captureEvidence();
    this.recentTextEvents = [];
    this.clearHandoffTranscript();
    this.state = "closing";
    this.publishState("closing", reason);
    this.send({ type: "session.close", event_id: randomUUID() });
    this.closeTimer = this.clock.setTimeout(() => {
      this.publish({ type: "voice_usage", usage: null, complete: false });
      this.finish("close_timeout");
    }, 2_000);
  }

  sidebandLost(message = "Live sideband disconnected before session.closed"): void {
    if (this.state === "closed") return;
    this.publish({ type: "voice_error", code: "sideband_disconnected", message });
    this.publish({ type: "voice_usage", usage: null, complete: false });
    this.finish("sideband_disconnected");
  }

  private inputAudio(audio: string): void {
    const signal = pcm16Rms(audio);
    if (!signal) { this.pcmCounts.invalidFrames++; return; }
    if (signal.rms >= LIVE_ACTIVITY_RMS) {
      this.pcmCounts.activityFrames++; this.liaisonAwaitingNewInput = false;
      this.activeAudioMs += signal.durationMs; this.quietAudioMs = 0; this.quietThresholdReached = false;
      if (this.utteranceTimer && this.transcriptFragments.length > 0) this.armUtterance(LIVE_UTTERANCE_STABLE_MS);
      if (this.activeAudioMs >= LIVE_ACTIVITY_MIN_MS) {
        this.lastActualInputAt = this.clock.now(); this.lastActualInputObservedOffsetMs = this.monotonicOffsetMs(); this.armDeadline();
        if (this.agentReplyTimer) { this.clock.clearTimeout(this.agentReplyTimer); this.agentReplyTimer = null; }
        this.armAgentReply();
      }
    } else {
      this.pcmCounts.quietFrames++;
      this.activeAudioMs = 0; this.quietAudioMs += signal.durationMs;
      if (this.quietAudioMs >= LIVE_QUIET_HINT_MS && !this.quietThresholdReached) {
        this.quietThresholdReached = true; this.pcmCounts.quietHints++;
      }
    }
  }

  private appendRecentText(role: LiveRecentTextEvent["role"], kind: LiveRecentTextEvent["kind"], rawText: string): void {
    if (this.state !== "active") return;
    const text = rawText.replace(/[\u0000-\u001f\u007f]/g, " "); if (!text) return;
    const last = this.recentTextEvents.at(-1);
    if (last?.role === role && last.kind === kind) last.text += text;
    else this.recentTextEvents.push({ timestampMs: this.clock.now(), role, kind, text });
    while (this.recentTextEvents.length > 32) this.recentTextEvents.shift();
    let remaining = 2_048; const kept: LiveRecentTextEvent[] = [];
    for (let index = this.recentTextEvents.length - 1; index >= 0 && remaining > 0; index--) {
      const event = this.recentTextEvents[index]!, bytes = Buffer.byteLength(event.text);
      if (bytes <= remaining) { kept.unshift(event); remaining -= bytes; }
      else { kept.unshift({ ...event, text: suffixUtf8(event.text, remaining) }); remaining = 0; }
    }
    this.recentTextEvents = kept;
  }

  private handoffTranscriptReplayStatus(
    role: HandoffTranscriptDelta["role"],
    source: HandoffTranscriptDelta["source"],
    event: Record<string, unknown>,
  ): "new" | "duplicate" | "reject" {
    if (this.state !== "active" || this.routingMode !== "liaison") return "new";
    const eventId = event.event_id;
    if (eventId === undefined) return "new";
    if (typeof eventId !== "string" || eventId.length === 0 || eventId.length > 200) {
      this.blockLiaisonDispatch("integrity", "event_identity_invalid", typeof eventId === "string" ? eventId.length : null, 200, "A Live transcript event had invalid identity; no agent task was sent.");
      return "reject";
    }
    const startMs = typeof event.start_ms === "number" && Number.isFinite(event.start_ms) && event.start_ms >= 0 ? event.start_ms : null;
    const endMs = typeof event.end_ms === "number" && Number.isFinite(event.end_ms) && event.end_ms >= 0 ? event.end_ms : null;
    const fingerprint = handoffEventFingerprint(role, source, startMs, endMs, event.delta as string);
    const previous = this.handoffEventIds.get(eventId);
    if (previous === undefined) return "new";
    if (previous === fingerprint) return "duplicate";
    this.blockLiaisonDispatch("integrity", "event_identity_conflict", null, null, "A Live transcript event ID was reused with conflicting content; no agent task was sent.");
    return "reject";
  }

  private appendHandoffTranscript(role: HandoffTranscriptDelta["role"], source: HandoffTranscriptDelta["source"], event: Record<string, unknown>, userUtteranceId: number | null): number | null | "duplicate" {
    if (this.state !== "active" || this.routingMode !== "liaison" || this.liaisonDispatchBlocked) return null;
    const eventId = event.event_id === undefined ? null : typeof event.event_id === "string" && event.event_id.length > 0 && event.event_id.length <= 200 ? event.event_id : "<invalid>";
    if (eventId === "<invalid>") { this.blockLiaisonDispatch("integrity", "event_identity_invalid", typeof event.event_id === "string" ? event.event_id.length : null, 200, "A Live transcript event had invalid identity; no agent task was sent."); return null; }
    const startMs = typeof event.start_ms === "number" && Number.isFinite(event.start_ms) && event.start_ms >= 0 ? event.start_ms : null;
    const endMs = typeof event.end_ms === "number" && Number.isFinite(event.end_ms) && event.end_ms >= 0 ? event.end_ms : null;
    const timelineOrderValid = startMs !== null && endMs !== null && startMs <= endMs && (this.lastHandoffStartMs === null || startMs >= this.lastHandoffStartMs);
    const delta = event.delta as string;
    const fingerprint = handoffEventFingerprint(role, source, startMs, endMs, delta);
    if (eventId) {
      const previous = this.handoffEventIds.get(eventId);
      if (previous !== undefined) {
        if (previous !== fingerprint) { this.blockLiaisonDispatch("integrity", "event_identity_conflict", null, null, "A Live transcript event ID was reused with conflicting content; no agent task was sent."); return null; }
        return "duplicate";
      }
      if (this.handoffEventIds.size >= LIVE_HANDOFF_EVENT_IDS) { this.blockLiaisonDispatch("overflow", "event_identity_limit", this.handoffEventIds.size + 1, LIVE_HANDOFF_EVENT_IDS, "The Live transcript identity bound was reached; no agent task was sent."); return null; }
    }
    const entry: HandoffTranscriptDelta = { sequence: this.nextHandoffSequence, role, source, eventId, startMs, endMs, timelineOrderValid, userUtteranceId, delta };
    const retainedBytes = handoffEntryRetainedBytes(entry);
    const renderedReserveBytes = handoffEntryRenderedReserveBytes(entry);
    if (this.handoffTranscript.length >= LIVE_HANDOFF_CONTEXT_EVENTS) {
      this.blockLiaisonDispatch("overflow", "journal_event_limit", this.handoffTranscript.length + 1, LIVE_HANDOFF_CONTEXT_EVENTS, "The Live transcript journal reached its event bound; no partial agent task was sent.");
      return null;
    }
    if (this.handoffRetainedBytes + retainedBytes > LIVE_HANDOFF_JOURNAL_BYTES) {
      this.blockLiaisonDispatch("overflow", "journal_retained_byte_limit", this.handoffRetainedBytes + retainedBytes, LIVE_HANDOFF_JOURNAL_BYTES, "The Live transcript journal reached its retained-memory bound; no partial agent task was sent.");
      return null;
    }
    if (this.handoffRenderedReserveBytes + renderedReserveBytes > LIVE_HANDOFF_RENDERED_BYTES) {
      this.blockLiaisonDispatch("overflow", "rendered_reserve_byte_limit", this.handoffRenderedReserveBytes + renderedReserveBytes, LIVE_HANDOFF_RENDERED_BYTES, "The Live transcript context reached its rendered-body reserve; no partial agent task was sent.");
      return null;
    }
    this.nextHandoffSequence++;
    this.handoffTranscript.push(entry);
    this.handoffRetainedBytes += retainedBytes;
    this.handoffRenderedReserveBytes += renderedReserveBytes;
    if (startMs !== null) this.lastHandoffStartMs = startMs;
    if (eventId) this.handoffEventIds.set(eventId, fingerprint);
    return entry.sequence;
  }

  private blockLiaisonDispatch(reason: "overflow" | "integrity" | "delivery", subreason: LiveDispatchBlockReason, used: number | null, limit: number | null, message: string): void {
    if (this.liaisonDispatchBlocked) return;
    this.liaisonDispatchBlocked = reason;
    this.liaisonDispatchBlock = { reason: subreason, used, limit };
    this.publish({ type: "voice_error", code: reason === "overflow" ? "transcript_context_overflow" : reason === "integrity" ? "transcript_context_integrity" : "transcript_context_delivery_uncommitted", message });
    this.rejectQueuedDelegationsAfterDispatchBlock();
  }

  private rejectQueuedDelegationsAfterDispatchBlock(): void {
    const queued = [
      ...this.pendingDelegations.map((item) => ({ delegationId: item.id, userInputEpoch: item.userInputEpoch })),
      ...this.liaisonReadyQueue.map((item) => ({ delegationId: item.delegationId, userInputEpoch: item.userInputEpoch })),
    ];
    if (queued.length === 0) return;
    this.pendingDelegations.length = 0;
    this.liaisonReadyQueue.length = 0;
    this.clearPendingDelegationTimer();
    this.routingCounts.ignoredDelegations += queued.length;
    this.delegationOutcomes.rejected += queued.length;
    this.liaisonAwaitingNewInput = true;
    for (const item of queued) this.rejectDelegationAfterDispatchBlock(item.delegationId, item.userInputEpoch);
  }

  private rejectDelegationAfterDispatchBlock(delegationId: string, userInputEpoch: number | null): void {
    const subreason = this.liaisonDispatchBlock?.reason ?? "delivery_uncommitted";
    const message = `This client delegation was not dispatched because voice handoff routing is blocked (${subreason}). End and explicitly start a new voice session before retrying.`;
    this.publish({ type: "voice_error", code: "liaison_dispatch_blocked", message });
    if (userInputEpoch === null || this.feedbackUserInputEpochs.has(userInputEpoch)) return;
    this.feedbackUserInputEpochs.add(userInputEpoch);
    while (this.feedbackUserInputEpochs.size > LIVE_FEEDBACK_EPOCHS) {
      const oldest = this.feedbackUserInputEpochs.values().next().value as number | undefined;
      if (oldest === undefined) break;
      this.feedbackUserInputEpochs.delete(oldest);
    }
    this.enqueueAppend("session.thinking.append", delegationId, truncateUtf8(`${message} Do not claim this delegation was sent.`, 400));
  }

  private appendTranscript(delta: string, handoffSequence: number | null): void {
    if (!delta || (this.inputMode === "ptt" && !this.pttHeld && !this.pttAwaitingTrailing)) return;
    this.liaisonAwaitingNewInput = false;
    this.transcriptFragments.push({ sequence: this.nextTranscriptSequence++, text: delta, handoffSequence });
    this.transcriptChars += delta.length;
    while (this.transcriptChars > LIVE_TRANSCRIPT_CHARS && this.transcriptFragments.length > 1) {
      const removed = this.transcriptFragments.shift();
      if (removed) this.transcriptChars -= removed.text.length;
    }
    if (this.inputMode === "continuous") this.armUtterance(LIVE_UTTERANCE_STABLE_MS);
    else if (this.pttAwaitingTrailing) this.armUtterance(LIVE_PTT_TRAILING_MS);
  }

  private armUtterance(delay: number): void {
    if (this.utteranceTimer) this.clock.clearTimeout(this.utteranceTimer);
    this.utteranceTimer = this.clock.setTimeout(() => { this.utteranceTimer = null; this.emitUtterance(); }, delay);
  }

  private continueAssistantCaptionBurst(): string {
    if (this.activeAssistantCaptionBurstId === null) this.activeAssistantCaptionBurstId = this.nextAssistantCaptionBurstId++;
    if (this.assistantCaptionBurstTimer) this.clock.clearTimeout(this.assistantCaptionBurstTimer);
    this.assistantCaptionBurstTimer = this.clock.setTimeout(() => {
      this.assistantCaptionBurstTimer = null;
      this.activeAssistantCaptionBurstId = null;
    }, LIVE_CAPTION_BURST_QUIET_MS);
    return `assistant-${this.activeAssistantCaptionBurstId}`;
  }

  private endAssistantCaptionBurst(): void {
    if (this.assistantCaptionBurstTimer) this.clock.clearTimeout(this.assistantCaptionBurstTimer);
    this.assistantCaptionBurstTimer = null;
    this.activeAssistantCaptionBurstId = null;
  }

  private emitUtterance(): void {
    if (this.state !== "active") return;
    const finishingPtt = this.inputMode === "ptt" && this.pttAwaitingTrailing;
    const completedFragments = this.transcriptFragments;
    const completedCaptionGroupId = this.activeUserUtteranceId === null ? null : `user-${this.activeUserUtteranceId}`;
    const text = completedFragments.map((item) => item.text).join("").trim();
    this.transcriptFragments = []; this.transcriptChars = 0; this.activeUserUtteranceId = null; this.pttAwaitingTrailing = false;
    if (text) {
      this.routingCounts.utterances++;
      if (this.routingMode === "direct") this.publish({ type: "voice_utterance", utteranceId: `voice-utterance-${randomUUID()}`, text, grouping: "bounded_transcript_stability" });
      else {
        const sequences = completedFragments.flatMap((item) => item.handoffSequence === null ? [] : [item.handoffSequence]);
        this.liaisonContext.push({ text, fromSequence: sequences.at(0) ?? null, throughSequence: sequences.at(-1) ?? null });
        while (this.liaisonContext.map((item) => item.text).join("\n").length > LIVE_TRANSCRIPT_CHARS && this.liaisonContext.length > 1) this.liaisonContext.shift();
      }
    }
    if (completedCaptionGroupId !== null) this.publish({ type: "voice_caption_stable", speaker: "user", groupId: completedCaptionGroupId });
    if (this.routingMode === "liaison") { this.pairLiaisonWork(); this.tryEmitLiaisonRequest(); }
    if (finishingPtt) { this.clearPTTHoldBoundaries(); this.publish({ type: "voice_ptt_ready" }); this.armAgentReply(); }
  }

  private pairLiaisonWork(): void {
    if (this.pendingDelegations.length === 0 || this.liaisonContext.length === 0 || this.liaisonDispatchBlocked) return;
    const pending = this.pendingDelegations[0]!;
    if (pending.currentRequestFromSequence !== null && this.transcriptFragments.length > 0) return;
    const contextStart = pending.currentRequestFromSequence === null ? 0 : this.liaisonContext.findIndex((item) => item.throughSequence !== null && item.throughSequence >= pending.currentRequestFromSequence!);
    if (contextStart < 0) return;
    const currentContext = this.liaisonContext.slice(contextStart);
    const text = currentContext.map((item) => item.text).join("\n").trim();
    const sequences = currentContext.flatMap((item) => item.fromSequence === null ? [] : [item.fromSequence]);
    const throughSequences = currentContext.flatMap((item) => item.throughSequence === null ? [] : [item.throughSequence]);
    this.pendingDelegations.shift();
    this.routingCounts.ignoredDelegations += this.pendingDelegations.length;
    this.delegationOutcomes.coalesced += this.pendingDelegations.length;
    this.pendingDelegations.length = 0;
    this.liaisonContext.length = 0;
    if (!text) { this.routingCounts.ignoredDelegations++; return; }
    this.liaisonReadyQueue.push({
      delegationId: pending.id,
      text,
      currentRequestFromSequence: sequences.at(0) ?? null,
      currentRequestThroughSequence: throughSequences.at(-1) ?? null,
      throughSequence: this.handoffTranscript.at(-1)?.sequence ?? this.committedHandoffSequence,
      userInputEpoch: pending.userInputEpoch,
    });
    this.liaisonAwaitingNewInput = true;
  }

  private tryEmitLiaisonRequest(): void {
    if (this.routingMode !== "liaison" || this.state !== "active" || this.liaisonDispatchBlocked || this.liaisonDispatchInFlight || this.pttHeld || this.pttAwaitingTrailing || this.utteranceTimer || this.transcriptFragments.length > 0) return;
    const work = this.liaisonReadyQueue[0];
    if (!work) return;
    const transcript = this.handoffTranscript.filter((entry) => entry.sequence > this.committedHandoffSequence && entry.sequence <= work.throughSequence);
    const content = formatHandoffBody(transcript, work.currentRequestFromSequence, work.currentRequestThroughSequence);
    if (content.length > MAX_RELAY_VOICE_TEXT_CHARS) {
      this.blockLiaisonDispatch("overflow", "wire_character_limit", content.length, MAX_RELAY_VOICE_TEXT_CHARS, "The atomic Live transcript message body exceeded its character wire bound; no partial agent task was sent.");
      return;
    }
    const contentBytes = Buffer.byteLength(content);
    if (contentBytes > MAX_RELAY_VOICE_TEXT_BYTES) {
      this.blockLiaisonDispatch("overflow", "wire_byte_limit", contentBytes, MAX_RELAY_VOICE_TEXT_BYTES, "The atomic Live transcript message body exceeded its UTF-8 wire bound; no partial agent task was sent.");
      return;
    }
    this.liaisonReadyQueue.shift();
    const requestId = `voice-liaison-${randomUUID()}`;
    this.liaisonDispatchInFlight = { requestId, fromSequence: this.committedHandoffSequence, throughSequence: work.throughSequence };
    this.clearPendingDelegationTimer();
    this.liaisonAwaitingNewInput = true; this.routingCounts.liaisonRequests++; this.delegationOutcomes.emitted++; this.markFirst("firstLiaisonRequestOffsetMs");
    this.publish({ type: "voice_liaison_request", delegationId: work.delegationId, requestId, text: content, grouping: "bounded_transcript_stability", transcriptFromSequence: this.committedHandoffSequence, transcriptThroughSequence: work.throughSequence });
  }

  private armPendingDelegationExpiry(): void {
    if (this.pendingDelegations.length === 0) { this.clearPendingDelegationTimer(); return; }
    if (this.pendingDelegationTimer) this.clock.clearTimeout(this.pendingDelegationTimer);
    this.pendingDelegationTimer = this.clock.setTimeout(() => {
      this.pendingDelegationTimer = null;
      if (this.pendingDelegations.length === 0) return;
      if (this.pttHeld || this.pttAwaitingTrailing || this.utteranceTimer || this.transcriptFragments.length > 0) { this.armPendingDelegationExpiry(); return; }
      this.pendingDelegations.shift(); this.routingCounts.ignoredDelegations++; this.delegationOutcomes.expired++; this.liaisonAwaitingNewInput = true;
      this.armPendingDelegationExpiry();
    }, 5_000);
  }

  private clearPendingDelegationTimer(): void {
    if (this.pendingDelegationTimer) this.clock.clearTimeout(this.pendingDelegationTimer);
    this.pendingDelegationTimer = null;
  }

  private cancelCurrentPTTLiaisonWork(): void {
    const pendingBoundary = this.pttHoldStartPendingDelegations ?? this.pendingDelegations.length;
    const readyBoundary = this.pttHoldStartReadyQueue ?? this.liaisonReadyQueue.length;
    const contextBoundary = this.pttHoldStartLiaisonContext ?? this.liaisonContext.length;
    const removedPending = Math.max(0, this.pendingDelegations.length - pendingBoundary);
    const removedReady = Math.max(0, this.liaisonReadyQueue.length - readyBoundary);
    const removed = removedPending + removedReady;
    this.pendingDelegations.length = Math.min(this.pendingDelegations.length, pendingBoundary);
    this.liaisonReadyQueue.length = Math.min(this.liaisonReadyQueue.length, readyBoundary);
    this.liaisonContext.length = Math.min(this.liaisonContext.length, contextBoundary);
    this.routingCounts.ignoredDelegations += removed;
    this.delegationOutcomes.cancelled += removed;
    this.clearPTTHoldBoundaries();
    if (this.pendingDelegations.length > 0) this.armPendingDelegationExpiry();
    else this.clearPendingDelegationTimer();
  }

  private clearPTTHoldBoundaries(): void {
    this.pttHoldStartHandoffSequence = null;
    this.pttHoldStartPendingDelegations = null;
    this.pttHoldStartReadyQueue = null;
    this.pttHoldStartLiaisonContext = null;
  }

  private beginAgentMessage(messageId: string, state: AgentSpeechState): void {
    const offsetMs = this.monotonicOffsetMs();
    this.agentMessageLedger.set(messageId, {
      state, receivedOffsetMs: offsetMs, stateOffsetMs: offsetMs, appendAttempts: [], chunkCount: 0,
      acknowledgedChunks: 0, lastAcknowledgedOffsetMs: null, outputObserved: false, outputObservedOffsetMs: null, correctionNeeded: false,
    });
  }

  private updateAgentMessage(messageId: string, update: Partial<Omit<AgentSpeechLedgerEntry, "appendAttempts" | "receivedOffsetMs" | "stateOffsetMs">>): void {
    const entry = this.agentMessageLedger.get(messageId);
    if (!entry) return;
    if (update.state !== undefined && update.state !== entry.state) entry.stateOffsetMs = this.monotonicOffsetMs();
    Object.assign(entry, update);
  }

  private observeProviderOutputAudio(audio: string): void {
    // GPT Live output audio deltas use the session's default PCM16 format. Fail quiet on any
    // non-canonical/invalid frame: an event counter or opaque payload is never speech evidence.
    const signal = pcm16Rms(audio);
    if (!signal) { this.outputPcmCounts.invalidFrames++; return; }
    if (signal.rms < LIVE_ACTIVITY_RMS) { this.outputPcmCounts.quietFrames++; return; }
    this.outputPcmCounts.activityFrames++;
    this.lastProviderOutputAt = this.clock.now();
    if (this.activeAgentMessageId) {
      this.activeAgentOutputObserved = true;
      this.updateAgentMessage(this.activeAgentMessageId, { outputObserved: true, outputObservedOffsetMs: this.monotonicOffsetMs() });
    }
    if (this.awaitingAgentOutputId) {
      this.updateAgentMessage(this.awaitingAgentOutputId, { state: "output_observed_unattributed", outputObserved: true, outputObservedOffsetMs: this.monotonicOffsetMs() });
      this.awaitingAgentOutputId = null;
    }
    if (this.agentReplyTimer) { this.clock.clearTimeout(this.agentReplyTimer); this.agentReplyTimer = null; }
    this.armAgentReply();
  }

  private armAgentMessageExpiry(): void {
    if (this.agentMessageExpiryTimer) { this.clock.clearTimeout(this.agentMessageExpiryTimer); this.agentMessageExpiryTimer = null; }
    const nextExpiry = this.pendingAgentMessages.reduce((earliest, message) => Math.min(earliest, message.expiresAt), Number.POSITIVE_INFINITY);
    if (!Number.isFinite(nextExpiry) || this.state !== "active") return;
    this.agentMessageExpiryTimer = this.clock.setTimeout(() => {
      this.agentMessageExpiryTimer = null;
      const now = this.clock.now(); let expired = 0;
      for (let index = this.pendingAgentMessages.length - 1; index >= 0; index--) {
        const message = this.pendingAgentMessages[index]!;
        if (message.expiresAt > now) continue;
        this.pendingAgentMessages.splice(index, 1);
        this.updateAgentMessage(message.messageId, { state: "expired" });
        expired++;
      }
      if (expired > 0) this.publish({ type: "voice_error", code: "agent_reply_expired", message: "An unheard agent update expired before speech was attempted; read it in the native agent view." });
      this.armAgentMessageExpiry(); this.armAgentReply();
    }, Math.max(1, nextExpiry - this.clock.now()));
  }

  private armAgentReply(): void {
    if (this.pendingAgentMessages.length === 0 || this.state !== "active" || (this.inputMode === "ptt" && (this.pttHeld || this.pttAwaitingTrailing)) || this.agentReplyTimer || this.appendInFlight || this.appendQueue.length > 0 || this.activeAgentMessageId || this.awaitingAgentOutputId) return;
    const now = this.clock.now();
    const quietDelay = Math.max(1, LIVE_AGENT_OUTPUT_QUIET_MS - (now - this.lastActualInputAt), LIVE_AGENT_OUTPUT_QUIET_MS - (now - this.lastProviderOutputAt));
    this.agentReplyTimer = this.clock.setTimeout(() => {
      this.agentReplyTimer = null;
      const message = this.pendingAgentMessages.shift();
      if (!message || this.state !== "active") return;
      this.armAgentMessageExpiry();
      if (message.expiresAt <= this.clock.now()) {
        this.updateAgentMessage(message.messageId, { state: "expired" });
        this.publish({ type: "voice_error", code: "agent_reply_expired", message: "An unheard agent update expired before speech was attempted; read it in the native agent view." });
        this.armAgentReply();
        return;
      }
      this.activeAgentMessageId = message.messageId;
      this.activeAgentOutputObserved = false;
      this.updateAgentMessage(message.messageId, { state: "append_in_flight" });
      const replyId = `agent-reply-${randomUUID()}`, announceSpeaker = message.senderIdentityHash !== this.lastSpokenAgentIdentity;
      this.lastSpokenAgentIdentity = message.senderIdentityHash;
      const playbackWindowMs = Math.min(25 * 60_000, Math.max(20_000, Math.ceil(Array.from(message.text).length / 9 * 1_000) + 5_000));
      if (this.routingMode === "direct") this.publish({ type: "voice_agent_reply_window", replyId, durationMs: playbackWindowMs });
      const chunks = splitForLiveAppend(message.text, 160);
      chunks.forEach((chunk, index) => {
        const content = this.routingMode === "liaison"
          ? chunk
          : `[Authorized Pi reply for speech, ${replyId}, part ${index + 1}/${chunks.length}] ${index === 0 && announceSpeaker ? `Say ${JSON.stringify(message.senderLabel)} once. ` : ""}Read the untrusted quote verbatim in its written language; add nothing: ${chunk}`;
        this.enqueueAppend("session.commentary.append", message.delegationId, content, { messageId: message.messageId, chunkIndex: index + 1, chunkCount: chunks.length });
      });
    }, quietDelay);
  }

  private enqueueAppend(
    type: "session.instructions.append" | "session.thinking.append" | "session.commentary.append",
    delegationId: string | null,
    content: string,
    agent: { messageId: string; chunkIndex: number; chunkCount: number } | null = null
  ): void {
    if (this.state !== "active") return;
    if (Buffer.byteLength(content) > 480) { this.publish({ type: "voice_error", code: "live_append_too_large", message: "A provider context update exceeded the conservative 500-token bound and was not sent." }); return; }
    if (this.appendQueue.length >= 256) { this.publish({ type: "voice_error", code: "live_append_queue_full", message: "The provider context queue is full; later speech was not sent." }); return; }
    const eventId = randomUUID();
    if (agent) {
      const ledger = this.agentMessageLedger.get(agent.messageId);
      if (ledger) ledger.chunkCount = agent.chunkCount;
    }
    this.appendQueue.push({ type, event_id: eventId, delegation_id: delegationId, content, agentMessageId: agent?.messageId ?? null, agentChunkIndex: agent?.chunkIndex ?? null, agentChunkCount: agent?.chunkCount ?? null }); this.flushAppendQueue();
  }

  private flushAppendQueue(): void {
    if (this.state !== "active" || this.appendInFlight) return;
    const next = this.appendQueue.shift();
    if (!next) { this.armAgentReply(); return; }
    this.appendInFlight = next;
    if (next.agentMessageId) {
      const ledger = this.agentMessageLedger.get(next.agentMessageId);
      if (ledger) ledger.appendAttempts.push({ eventId: next.event_id, chunkIndex: next.agentChunkIndex ?? 0, offsetMs: this.monotonicOffsetMs() });
    }
    this.send({ type: next.type, event_id: next.event_id, delegation_id: next.delegation_id, content: next.content });
    this.appendAckTimer = this.clock.setTimeout(() => {
      if (this.appendInFlight?.event_id !== next.event_id) return;
      if (next.agentMessageId) this.updateAgentMessage(next.agentMessageId, { state: "append_unknown" });
      this.activeAgentMessageId = null; this.activeAgentOutputObserved = false; this.awaitingAgentOutputId = null;
      this.appendInFlight = null; this.appendQueue.length = 0; this.appendAckTimer = null;
      if (this.pendingAgentMessages.length > 0) {
        for (const message of this.pendingAgentMessages) this.updateAgentMessage(message.messageId, { state: "expired" });
        this.pendingAgentMessages.length = 0;
        if (this.agentMessageExpiryTimer) this.clock.clearTimeout(this.agentMessageExpiryTimer);
        this.agentMessageExpiryTimer = null;
      }
      this.publish({ type: "voice_error", code: "live_append_unknown", message: "A provider context update was not acknowledged; it was not retried and later queued speech was stopped." });
    }, 5_000);
  }

  private recountHandoffTranscriptBudgets(): void {
    this.handoffRetainedBytes = this.handoffTranscript.reduce((total, entry) => total + handoffEntryRetainedBytes(entry), 0);
    this.handoffRenderedReserveBytes = this.handoffTranscript.reduce((total, entry) => total + handoffEntryRenderedReserveBytes(entry), 0);
  }

  private clearHandoffTranscript(): void {
    this.transcriptFragments = [];
    this.transcriptChars = 0;
    this.activeUserUtteranceId = null;
    this.liaisonContext.length = 0;
    this.pendingDelegations.length = 0;
    this.liaisonReadyQueue.length = 0;
    this.feedbackUserInputEpochs.clear();
    this.lastAcceptedUserInputEpoch = null;
    this.clearPendingDelegationTimer();
    this.handoffTranscript.length = 0;
    this.handoffEventIds.clear();
    this.handoffRetainedBytes = 0;
    this.handoffRenderedReserveBytes = 0;
    this.lastHandoffStartMs = null;
    this.clearPTTHoldBoundaries();
    this.liaisonDispatchInFlight = null;
    this.liaisonDispatchBlocked = null;
    this.liaisonDispatchBlock = null;
  }

  private armDeadline(): void {
    if (this.timer) this.clock.clearTimeout(this.timer);
    if (this.state !== "active") return;
    const idleDeadline = this.lastActualInputAt + this.idleTimeoutMs;
    const hardDeadline = this.startedAt + LIVE_HARD_MS;
    const deadline = Math.min(idleDeadline, hardDeadline);
    this.timer = this.clock.setTimeout(() => {
      const now = this.clock.now();
      if (now >= hardDeadline) this.close("hard_max");
      else if (now >= idleDeadline) this.close("input_idle");
      else this.armDeadline();
    }, Math.max(1, deadline - this.clock.now()));
  }

  private monotonicOffsetMs(): number {
    const candidate = Math.round(this.clock.now() - this.startedAt);
    this.lastMonotonicOffsetMs = Math.min(LIVE_HARD_MS + 2_000, Math.max(this.lastMonotonicOffsetMs, Number.isFinite(candidate) ? candidate : 0, 0));
    return this.lastMonotonicOffsetMs;
  }

  private markFirst(field: keyof LiveControl["timing"]): void {
    if (this.timing[field] === null) this.timing[field] = this.monotonicOffsetMs();
  }

  private copyRecentText(): LiveRecentTextEvent[] {
    return this.recentTextEvents.map((event) => ({ ...event }));
  }

  private snapshotDiagnostics(state: LiveDiagnostics["state"], includePrimary: boolean, closedOffsetMs: number | null = null): LiveDiagnostics {
    return {
      state,
      arrivalSequence: this.arrivalSequence,
      events: { ...this.eventCounts },
      provider: {
        startup: { ...this.providerStartup },
        otherEventTypes: [...this.otherEventTypes].map(([type, count]) => ({ type, count })),
        otherEventTypeOverflow: this.otherEventTypeOverflow,
        primary: includePrimary && this.primaryReportSequence > 0
          ? { source: "client_reported", eventTypes: this.primaryEventTypes.map((entry) => ({ ...entry })), overflow: this.primaryEventOverflow }
          : null,
      },
      pcm: { ...this.pcmCounts },
      timing: {
        ...this.timing,
        closedOffsetMs,
        lastActualInputOffsetMs: this.lastActualInputObservedOffsetMs,
        inputIdleDeadlineAtMs: this.lastActualInputAt + this.idleTimeoutMs,
        hardDeadlineAtMs: this.startedAt + LIVE_HARD_MS,
      },
      ending: { requested: this.closeRequest ? { ...this.closeRequest } : null, terminal: null },
      routing: {
        ...this.routingCounts,
        inputMode: this.inputMode,
        routingMode: this.routingMode,
        pttHeld: this.pttHeld,
        pttAwaitingTrailing: this.pttAwaitingTrailing,
        pttHolds: this.pttCounts.holds,
        pttReleases: this.pttCounts.releases,
        pttCancels: this.pttCounts.cancels,
        delegationsWhilePttHeld: this.pttCounts.delegationsWhileHeld,
        pendingDelegationAtClose: this.pendingDelegations.length > 0 || this.liaisonReadyQueue.length > 0,
        dispatchBlock: this.liaisonDispatchBlock ? { ...this.liaisonDispatchBlock } : null,
        delegationOutcomes: { ...this.delegationOutcomes },
        agentSpeech: {
          pendingText: this.pendingAgentMessages.length,
          activeText: this.activeAgentMessageId ? 1 : 0,
          identityCount: this.agentMessageLedger.size,
          awaitingOutputObservation: this.awaitingAgentOutputId !== null,
          neverAttempted: [...this.agentMessageLedger.values()].filter((entry) => entry.state === "never_attempted").length,
          appendInFlight: [...this.agentMessageLedger.values()].filter((entry) => entry.state === "append_in_flight").length,
          providerAcceptedSpeechUnconfirmed: [...this.agentMessageLedger.values()].filter((entry) => entry.state === "provider_accepted_speech_unconfirmed").length,
          outputObservedUnattributed: [...this.agentMessageLedger.values()].filter((entry) => entry.state === "output_observed_unattributed").length,
          appendUnknown: [...this.agentMessageLedger.values()].filter((entry) => entry.state === "append_unknown").length,
          expired: [...this.agentMessageLedger.values()].filter((entry) => entry.state === "expired").length,
          superseded: [...this.agentMessageLedger.values()].filter((entry) => entry.state === "superseded").length,
          correctionNeeded: [...this.agentMessageLedger.values()].filter((entry) => entry.correctionNeeded).length,
          outputActivityFrames: this.outputPcmCounts.activityFrames,
          outputQuietFrames: this.outputPcmCounts.quietFrames,
          outputInvalidFrames: this.outputPcmCounts.invalidFrames,
          entries: [...this.agentMessageLedger.entries()].map(([messageId, entry]) => ({
            messageId,
            state: entry.state,
            receivedOffsetMs: entry.receivedOffsetMs,
            stateOffsetMs: entry.stateOffsetMs,
            attemptedAppends: entry.appendAttempts.map((attempt) => ({ ...attempt })),
            chunkCount: entry.chunkCount,
            acknowledgedChunks: entry.acknowledgedChunks,
            lastAcknowledgedOffsetMs: entry.lastAcknowledgedOffsetMs,
            outputObserved: entry.outputObserved,
            outputObservedOffsetMs: entry.outputObservedOffsetMs,
            correctionNeeded: entry.correctionNeeded,
          })),
        },
        journal: {
          events: this.handoffTranscript.length,
          eventLimit: LIVE_HANDOFF_CONTEXT_EVENTS,
          retainedBytes: this.handoffRetainedBytes,
          retainedByteLimit: LIVE_HANDOFF_JOURNAL_BYTES,
          renderedReserveBytes: this.handoffRenderedReserveBytes,
          renderedReserveByteLimit: LIVE_HANDOFF_RENDERED_BYTES,
        },
      },
    };
  }

  private captureEvidence(): { control: LiveDiagnostics; recentText: LiveRecentTextEvent[] } {
    return { control: this.snapshotDiagnostics("closed", true), recentText: this.copyRecentText() };
  }

  private publishState(state: "active" | "closing" | "closed", reason?: string): void {
    this.publish({ type: "voice_state", state, idleDeadline: this.lastActualInputAt + this.idleTimeoutMs, hardDeadline: this.startedAt + LIVE_HARD_MS, ...(reason ? { reason } : {}) });
  }

  private send(value: unknown): void {
    try { this.socket.send(JSON.stringify(value)); }
    catch { this.sidebandLost("Could not write to the Live sideband"); }
  }

  private finish(reason: LiveTerminalCode): void {
    if (this.state === "closed") return;
    const evidence = this.closingEvidence ?? this.captureEvidence();
    const closedOffsetMs = this.monotonicOffsetMs();
    evidence.control.state = "closed";
    evidence.control.arrivalSequence = this.arrivalSequence;
    evidence.control.events = { ...this.eventCounts };
    evidence.control.timing.closedOffsetMs = closedOffsetMs;
    evidence.control.ending.terminal = { code: reason, offsetMs: closedOffsetMs, providerClosed: reason === "provider_closed" };
    this.terminalValue = {
      control: evidence.control,
      recentText: evidence.recentText,
      closure: { reason, providerClosed: reason === "provider_closed" },
    };
    this.closingEvidence = null;
    this.state = "closed";
    if (this.timer) this.clock.clearTimeout(this.timer);
    if (this.closeTimer) this.clock.clearTimeout(this.closeTimer);
    if (this.utteranceTimer) this.clock.clearTimeout(this.utteranceTimer);
    this.endAssistantCaptionBurst();
    if (this.agentReplyTimer) this.clock.clearTimeout(this.agentReplyTimer);
    if (this.agentMessageExpiryTimer) this.clock.clearTimeout(this.agentMessageExpiryTimer);
    if (this.appendAckTimer) this.clock.clearTimeout(this.appendAckTimer);
    if (this.pendingDelegationTimer) this.clock.clearTimeout(this.pendingDelegationTimer);
    this.appendQueue.length = 0; this.appendInFlight = null;
    this.pendingAgentMessages.length = 0; this.agentMessageLedger.clear(); this.activeAgentMessageId = null; this.activeAgentOutputObserved = false; this.awaitingAgentOutputId = null;
    this.pendingDelegations.length = 0; this.liaisonReadyQueue.length = 0; this.recentTextEvents = [];
    this.clearHandoffTranscript();
    this.primaryEventTypes = []; this.primaryEventOverflow = 0; this.primaryReportSequence = 0;
    this.publishState("closed", reason);
    try { this.socket.close(); } catch { /* already closed */ }
    this.resolveClosed();
    this.onClosed();
  }
}

function safeCloseRequestCode(reason: string): LiveCloseRequestCode {
  switch (reason) {
    case "browser_stop": case "input_idle": case "hard_max": case "gateway_stopping":
    case "browser_connection_lost": case "device_revoked": case "native_relay_disconnected": case "native_human_endpoint_lost":
      return reason;
    default: return "other";
  }
}

function clean(value: unknown, max: number): string {
  return typeof value === "string" ? value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, max) : "";
}
