import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { chmod, mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, extname, join, normalize } from "node:path";
import { homedir } from "node:os";
import { isLiveVoice, liveSessionRequest, type LiveRoutingMode } from "./live.ts";
import { LiveControl, type LiveControlEvent, type LiveDiagnostics, type LiveInputMode, type LiveProviderStartupDiagnostic, type LiveRecentTextEvent, type LiveSideband } from "./live-control.ts";
import { RelayState, type RelayAttachment, type RelayClient, type RelayConversationMessage, type RelayStateEvent } from "./relay.ts";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { DEVICE_ABSOLUTE_TTL_MS, DEVICE_IDLE_TTL_MS, DeviceAuthStore, DeviceLimitError, type PublicDevice } from "./device-auth.ts";
import { WebSocketServer, WebSocket } from "ws";

type FetchLike = typeof fetch;
type LiveGatewayEvent = LiveControlEvent & { generation: string };
type VoiceConnectionEvent = { type: "voice_connection"; connectionId: string };
type WsAuth = { sessionId: string; deviceId: string | null; origin: string; connectionId: string };
type LiveSendDiagnostics = { attempts: number; delivered: number; knownFailed: number; unknown: number };
type StoredLiveDiagnostics = { generation: string; active: boolean; control: LiveDiagnostics; sends: LiveSendDiagnostics };
type ProviderClosureReceipt = { generation: string; ownerDeviceId: string; origin: string; closed: 1; providerClosed: 0 | 1; reason: string; expiresAt: number };
type StoredTerminalDiagnostics = StoredLiveDiagnostics & {
  snapshotPhase: "closed";
  closure: { reason: string; providerClosed: boolean };
  closedAt: number;
  expiresAt: number;
  recentText: LiveRecentTextEvent[];
};
const TERMINAL_DIAGNOSTIC_TTL_MS = 30 * 60_000;
type LiveSession = { session?: { id?: string; model?: unknown; delegation?: unknown; store?: unknown; instructions?: unknown; audio?: unknown }; transport?: { type?: string; sdp?: string }; error?: { code?: unknown; type?: unknown; message?: unknown } };

function providerStartupDiagnostic(session: unknown, requestedInstructionHash: string, source: LiveProviderStartupDiagnostic["source"] = "creation_response"): LiveProviderStartupDiagnostic {
  const value = session && typeof session === "object" && !Array.isArray(session) ? session as Record<string, unknown> : {};
  const delegation = value.delegation && typeof value.delegation === "object" && !Array.isArray(value.delegation) ? value.delegation as Record<string, unknown> : {};
  const audio = value.audio && typeof value.audio === "object" && !Array.isArray(value.audio) ? value.audio as Record<string, unknown> : {};
  const output = audio.output && typeof audio.output === "object" && !Array.isArray(audio.output) ? audio.output as Record<string, unknown> : {};
  const boundedName = (input: unknown) => typeof input === "string" && /^[A-Za-z0-9._-]{1,80}$/.test(input) ? input : null;
  return {
    source,
    model: boundedName(value.model),
    delegationType: delegation.type === "client" || delegation.type === "responses" ? delegation.type : null,
    store: typeof value.store === "boolean" ? value.store : null,
    voice: boundedName(output.voice),
    instructionsMatched: typeof value.instructions === "string" ? createHash("sha256").update(value.instructions).digest("hex") === requestedInstructionHash : null,
  };
}
export function greetingForAgent(name: unknown): string {
  if (typeof name !== "string") return "Hello there.";
  const normalized = name.normalize("NFC").trim();
  if (!normalized || Array.from(normalized).length > 48 || Buffer.byteLength(normalized) > 96
    || !/^[\p{L}\p{M}\p{N} ._'’\-]+$/u.test(normalized)
    || /\s{2,}/u.test(normalized)) return "Hello there.";
  return `Hello there. You're connected to ${normalized}.`;
}

type SidebandConnection = LiveSideband & {
  on(event: "message", listener: (data: Buffer | string) => void): unknown;
  on(event: "close", listener: () => void): unknown;
  on(event: "error", listener: (error: Error) => void): unknown;
};

export type GatewayOptions = {
  port?: number;
  discoveryFile?: string;
  publicDir: string;
  token?: string;
  openAiKey?: string;
  fetchImpl?: FetchLike;
  /** Exact externally served browser origin, such as private Tailscale Serve HTTPS. */
  publicOrigin?: string;
  relayClient?: RelayClient;
  sidebandFactory?: (sessionId: string, openAiKey: string) => Promise<SidebandConnection>;
  focusLeaseFile?: string;
  browserSessionTtlMs?: number;
  maxBrowserSessions?: number;
  browserPairingTtlMs?: number;
  maxBrowserPairings?: number;
  deviceStoreFile?: string;
  wsHeartbeatPingMs?: number;
  wsHeartbeatPongDeadlineMs?: number;
  /** Test seam; production retention is fixed to at most 30 minutes. */
  terminalDiagnosticTtlMs?: number;
  /** Test seam; production closure receipts always expire within 30 minutes. */
  closureReceiptTtlMs?: number;
  now?: () => number;
};

export class CompanionGateway {
  private readonly token: string;
  private readonly discoveryInstanceId = randomBytes(16).toString("base64url");
  private readonly options: GatewayOptions;
  private readonly http = createServer((req, res) => void this.handleHttp(req, res));
  private readonly ws = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
  private readonly relay: RelayState | null;
  private liveControl: LiveControl | null = null;
  private liveTarget: { id: string; endpointEpoch: string } | null = null;
  private liveReply: { messageId: string; senderId: string; senderEpoch: string } | null = null;
  private liveGeneration: string | null = null;
  private liveRoutingMode: LiveRoutingMode | null = null;
  private liveOwnerDeviceId: string | null = null;
  private liveOwnerOrigin: string | null = null;
  private liveOwnerConnectionId: string | null = null;
  private readonly liaisonReplies = new Map<string, { generation: string; delegationId: string }>();
  private liveSendDiagnostics: LiveSendDiagnostics = { attempts: 0, delivered: 0, knownFailed: 0, unknown: 0 };
  private lastLiveDiagnostics: StoredTerminalDiagnostics | null = null;
  private terminalDiagnosticExpiryTimer: NodeJS.Timeout | null = null;
  private readonly closureReceipts = new Map<string, ProviderClosureReceipt>();
  private readonly closureReceiptTimers = new Map<string, NodeJS.Timeout>();
  private liveStarting = false;
  private liveStartingOwnerDeviceId: string | null = null;
  private liveStartingConnectionId: string | null = null;
  private liveStartingRevoked = false;
  private liveStartingConnectionLost = false;
  private focusLeaseRevision = 0;
  private readonly browserSessions = new Map<string, { expiresAt: number; deviceId: string | null; origin: string }>();
  private readonly browserPairings = new Map<string, number>();
  private readonly deviceStore: DeviceAuthStore;
  private readonly wsAuth = new WeakMap<WebSocket, WsAuth>();
  private readonly wsHeartbeat = new WeakMap<WebSocket, { pingTimer: NodeJS.Timeout; pongDeadline: NodeJS.Timeout | null }>();
  private portValue = 0;

  constructor(options: GatewayOptions) {
    this.options = options;
    this.token = options.token ?? randomBytes(32).toString("base64url");
    if (!/^[A-Za-z0-9_-]{43}$/.test(this.token)) throw new Error("invalid_owner_token");
    this.deviceStore = new DeviceAuthStore({ file: options.deviceStoreFile ?? join(homedir(), ".pi-companion", "devices.json"), ...(options.now ? { now: options.now } : {}) });
    this.relay = options.relayClient ? new RelayState({ client: options.relayClient, publish: (event) => {
      this.broadcast(event);
      if (event.type === "relay_message" && event.entry.direction === "inbound") this.forwardIncomingToLive(event.entry);
      if (event.type === "relay_connection" && !event.connected && this.liveControl?.active) {
        const generation = this.liveGeneration; if (generation) void this.deactivateHuman(generation);
        this.liveControl.close("native_relay_disconnected");
      }
    } }) : null;
    options.relayClient?.on("human_disconnected", () => { if (this.liveControl?.active) this.liveControl.close("native_human_endpoint_lost"); });
    this.http.on("upgrade", (req, socket, head) => {
      const auth = this.validBrowserRequest(req, true) ? this.wsAuthorization(req) : null;
      if (!auth) {
        socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      this.ws.handleUpgrade(req, socket, head, (client) => {
        this.wsAuth.set(client, { ...auth, connectionId: randomBytes(16).toString("base64url") }); this.ws.emit("connection", client, req);
      });
    });
    this.ws.on("connection", (client) => {
      const auth = this.wsAuth.get(client); if (!auth) return client.terminate();
      const session = this.browserSessions.get(auth.sessionId), delay = Math.max(1, (session?.expiresAt ?? 0) - (this.options.now ?? Date.now)());
      const sessionTimer = setTimeout(() => client.close(4001, "session_expired"), delay);
      const heartbeat = { pingTimer: setInterval(() => {
        if (client.readyState !== WebSocket.OPEN || heartbeat.pongDeadline) return;
        client.ping(); heartbeat.pongDeadline = setTimeout(() => client.terminate(), Math.max(1, this.options.wsHeartbeatPongDeadlineMs ?? 10_000)); heartbeat.pongDeadline.unref?.();
      }, Math.max(1, this.options.wsHeartbeatPingMs ?? 5_000)), pongDeadline: null as NodeJS.Timeout | null };
      heartbeat.pingTimer.unref?.(); this.wsHeartbeat.set(client, heartbeat);
      client.on("pong", () => { if (heartbeat.pongDeadline) clearTimeout(heartbeat.pongDeadline); heartbeat.pongDeadline = null; });
      client.once("close", () => {
        clearTimeout(sessionTimer); clearInterval(heartbeat.pingTimer); if (heartbeat.pongDeadline) clearTimeout(heartbeat.pongDeadline); this.handleLiveConnectionLost(auth.connectionId);
      });
      this.sendWs(client, { type: "voice_connection", connectionId: auth.connectionId });
      if (this.relay) this.sendWs(client, { type: "relay_snapshot", snapshot: this.relay.snapshot() });
    });
  }

  get port(): number { return this.portValue; }
  get localUrl(): string { return `http://localhost:${this.port}/`; }

  async start(): Promise<void> {
    await this.deviceStore.open();
    await new Promise<void>((resolve, reject) => {
      this.http.once("error", reject);
      this.http.listen(this.options.port ?? 43120, "127.0.0.1", () => resolve());
    });
    const address = this.http.address();
    if (!address || typeof address === "string") throw new Error("HTTP listener did not expose a TCP port");
    this.portValue = address.port;
    if (this.options.discoveryFile) await this.writeDiscovery(this.options.discoveryFile);
    if (this.relay) await this.relay.refreshRoster();
  }

  private async writeDiscovery(file: string): Promise<void> {
    await mkdir(dirname(file), { recursive: true, mode: 0o700 });
    await chmod(dirname(file), 0o700);
    const temp = `${file}.${process.pid}.tmp`;
    await writeFile(temp, `${JSON.stringify({ url: this.localUrl, browserOrigin: this.options.publicOrigin ? new URL(this.options.publicOrigin).origin : new URL(this.localUrl).origin, instanceId: this.discoveryInstanceId })}\n`, { mode: 0o600, flag: "w" });
    await chmod(temp, 0o600);
    await rename(temp, file);
  }

  private async removeDiscovery(file: string): Promise<void> {
    // Only remove the file if it still names this gateway; a newer gateway may have replaced it.
    try {
      const current = JSON.parse(await readFile(file, "utf8")) as { instanceId?: unknown };
      if (current.instanceId === this.discoveryInstanceId) await rm(file, { force: true });
    } catch { /* already gone or unreadable */ }
  }

  async stop(): Promise<void> {
    const live = this.liveControl, generation = this.liveGeneration;
    if (generation) await this.deactivateHuman(generation);
    live?.close("gateway_stopping");
    if (live?.occupied) await live.waitClosed();
    for (const client of this.ws.clients) client.close(1001, "gateway stopping");
    await new Promise<void>((resolve) => this.http.close(() => resolve()));
    if (this.options.discoveryFile) await this.removeDiscovery(this.options.discoveryFile);
    this.browserSessions.clear(); this.browserPairings.clear();
    this.clearTerminalDiagnostics();
    for (const generation of [...this.closureReceipts.keys()]) this.removeClosureReceipt(generation);
    await this.clearFocusLease();
  }

  private constantEqual(actual: string | undefined, expected: string): boolean {
    if (!actual) return false;
    const a = Buffer.from(actual);
    const b = Buffer.from(expected);
    return a.length === b.length && timingSafeEqual(a, b);
  }

  private validBrowserRequest(req: IncomingMessage, requireOrigin = false): boolean {
    const host = req.headers.host;
    const pairs = [
      { host: `localhost:${this.port}`, origin: `http://localhost:${this.port}` },
      { host: `127.0.0.1:${this.port}`, origin: `http://127.0.0.1:${this.port}` },
      ...(this.options.publicOrigin ? [{ host: new URL(this.options.publicOrigin).host, origin: new URL(this.options.publicOrigin).origin }] : []),
    ];
    const pair = pairs.find((candidate) => candidate.host === host);
    if (!pair) return false;
    const origin = req.headers.origin;
    return requireOrigin ? origin === pair.origin : origin === undefined || origin === pair.origin;
  }

  private requestOrigin(req: IncomingMessage): string { return typeof req.headers.origin === "string" ? new URL(req.headers.origin).origin : ""; }

  private localOwnerRequest(req: IncomingMessage): boolean {
    const origin = this.requestOrigin(req), host = req.headers.host;
    return (host === `localhost:${this.port}` && origin === `http://localhost:${this.port}`)
      || (host === `127.0.0.1:${this.port}` && origin === `http://127.0.0.1:${this.port}`);
  }

  private authorizedBearer(req: IncomingMessage): boolean {
    const value = req.headers.authorization;
    return this.localOwnerRequest(req) && value?.startsWith("Bearer ") === true && this.constantEqual(value.slice(7), this.token);
  }

  private cookieValue(req: IncomingMessage, names: string[]): string | null {
    const values = (req.headers.cookie ?? "").split(";").map((part) => part.trim().split("=", 2)).filter(([name, value]) => names.includes(name ?? "") && value);
    return values.length === 1 ? values[0]![1]! : null;
  }

  private cookieSession(req: IncomingMessage): { sessionId: string; deviceId: string | null; origin: string } | null {
    const sessionId = this.cookieValue(req, ["__Host-pi_voice_session", "pi_voice_session"]); if (!sessionId) return null;
    const session = this.browserSessions.get(sessionId), now = (this.options.now ?? Date.now)(), origin = this.requestOrigin(req);
    if (!session || session.expiresAt <= now || session.origin !== origin || (session.deviceId && !this.deviceStore.active(session.deviceId, origin))) {
      if (session) this.browserSessions.delete(sessionId); return null;
    }
    return { sessionId, deviceId: session.deviceId, origin };
  }

  private authorization(req: IncomingMessage): { owner: true } | { sessionId: string; deviceId: string | null; origin: string } | null {
    return this.authorizedBearer(req) ? { owner: true } : this.cookieSession(req);
  }

  private authorizationActive(auth: { owner: true } | { sessionId: string; deviceId: string | null; origin: string }): boolean {
    if ("owner" in auth) return true;
    const session = this.browserSessions.get(auth.sessionId), now = (this.options.now ?? Date.now)();
    return Boolean(session && session.expiresAt > now && session.origin === auth.origin && session.deviceId === auth.deviceId && (!auth.deviceId || this.deviceStore.active(auth.deviceId, auth.origin)));
  }

  private wsAuthorization(req: IncomingMessage): Omit<WsAuth, "connectionId"> | null { return this.cookieSession(req); }

  private liveConnection(auth: { owner: true } | { sessionId: string; deviceId: string | null; origin: string }, connectionId: unknown): string | null {
    if ("owner" in auth) return null;
    if (typeof connectionId !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(connectionId)) return null;
    for (const client of this.ws.clients) {
      const candidate = this.wsAuth.get(client);
      if (client.readyState === WebSocket.OPEN && candidate?.connectionId === connectionId && candidate.sessionId === auth.sessionId && candidate.deviceId === auth.deviceId && candidate.origin === auth.origin) return connectionId;
    }
    return null;
  }

  private liveConnectionActive(connectionId: string | null): boolean {
    if (!connectionId) return true; // Local owner test/administration has no browser-device WebSocket.
    for (const client of this.ws.clients) if (client.readyState === WebSocket.OPEN && this.wsAuth.get(client)?.connectionId === connectionId) return true;
    return false;
  }

  private handleLiveConnectionLost(connectionId: string): void {
    if (this.liveStarting && this.liveStartingConnectionId === connectionId) this.liveStartingConnectionLost = true;
    const control = this.liveControl, generation = this.liveGeneration;
    if (!control?.active || !generation || this.liveOwnerConnectionId !== connectionId) return;
    void this.deactivateHuman(generation); control.close("browser_connection_lost");
  }

  private createBrowserPairing(res: ServerResponse): void {
    const now = (this.options.now ?? Date.now)(), ttl = Math.max(1, this.options.browserPairingTtlMs ?? 5 * 60_000), max = Math.max(1, this.options.maxBrowserPairings ?? 8);
    for (const [token, expiresAt] of this.browserPairings) if (expiresAt <= now) this.browserPairings.delete(token);
    while (this.browserPairings.size >= max) this.browserPairings.delete(this.browserPairings.keys().next().value as string);
    const pairingToken = randomBytes(24).toString("base64url"), expiresAt = now + ttl; this.browserPairings.set(pairingToken, expiresAt);
    res.setHeader("cache-control", "no-store"); this.json(res, 201, { pairingToken, expiresAt });
  }

  private policy(): { idleTtlMs: number; absoluteTtlMs: number } { return { idleTtlMs: DEVICE_IDLE_TTL_MS, absoluteTtlMs: DEVICE_ABSOLUTE_TTL_MS }; }

  private secureCookie(req: IncomingMessage): boolean {
    const publicUrl = this.options.publicOrigin ? new URL(this.options.publicOrigin) : null;
    return publicUrl?.protocol === "https:" && req.headers.host === publicUrl.host && this.requestOrigin(req) === publicUrl.origin;
  }

  private deviceCookieAllowed(req: IncomingMessage): boolean { return this.secureCookie(req) || this.localOwnerRequest(req); }

  private issueBrowserSession(req: IncomingMessage, res: ServerResponse, device: PublicDevice | null, credential?: string): void {
    const now = (this.options.now ?? Date.now)(), ttl = Math.max(1, Math.min(this.options.browserSessionTtlMs ?? 60 * 60_000, 60 * 60_000)), max = Math.max(1, this.options.maxBrowserSessions ?? 32), origin = this.requestOrigin(req);
    for (const [id, session] of this.browserSessions) if (session.expiresAt <= now) this.browserSessions.delete(id);
    while (this.browserSessions.size >= max) this.browserSessions.delete(this.browserSessions.keys().next().value as string);
    const sessionId = randomBytes(32).toString("base64url"), sessionExpiresAt = device ? Math.min(now + ttl, device.idleExpiresAt, device.absoluteExpiresAt) : now + ttl;
    this.browserSessions.set(sessionId, { expiresAt: sessionExpiresAt, deviceId: device?.id ?? null, origin });
    const secure = this.secureCookie(req), prefix = secure ? "__Host-" : "";
    const cookies = [`${prefix}pi_voice_session=${sessionId}; Path=/; HttpOnly; SameSite=Strict${secure ? "; Secure" : ""}`];
    if (device && credential) {
      const maxAge = Math.max(0, Math.floor((device.absoluteExpiresAt - now) / 1000));
      cookies.unshift(`${prefix}pi_voice_device=${credential}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAge}${secure ? "; Secure" : ""}`);
    }
    res.setHeader("set-cookie", cookies); res.setHeader("cache-control", "no-store");
    this.json(res, 201, { authenticated: true, sessionExpiresAt, ...(device ? { device, policy: this.policy() } : {}) });
  }

  private clearAuthCookies(req: IncomingMessage, res: ServerResponse): void {
    const prefix = this.secureCookie(req) ? "__Host-" : "", secure = this.secureCookie(req) ? "; Secure" : "";
    res.setHeader("set-cookie", [`${prefix}pi_voice_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0${secure}`, `${prefix}pi_voice_device=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0${secure}`]);
  }

  private async redeemBrowserPairing(req: IncomingMessage, res: ServerResponse, body: Record<string, unknown>): Promise<void> {
    const token = body.pairingToken, now = (this.options.now ?? Date.now)();
    if (typeof token !== "string" || !/^[A-Za-z0-9_-]{32}$/.test(token)) return this.json(res, 401, { error: "invalid_or_expired_pairing" });
    const expiresAt = this.browserPairings.get(token);
    if (!expiresAt || expiresAt <= now) { this.browserPairings.delete(token); return this.json(res, 401, { error: "invalid_or_expired_pairing" }); }
    this.browserPairings.delete(token);
    if (!this.deviceCookieAllowed(req)) return this.json(res, 400, { error: "insecure_device_origin" });
    try { const created = await this.deviceStore.create(this.requestOrigin(req), body.deviceName); this.issueBrowserSession(req, res, created.device, created.credential); }
    catch (error) { if (error instanceof DeviceLimitError) return this.json(res, 409, { error: "device_limit_reached" }); if (error instanceof Error && error.message === "invalid_device_name") return this.json(res, 400, { error: "invalid_request" }); throw error; }
  }

  private async renewBrowserSession(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (!this.deviceCookieAllowed(req)) return this.json(res, 400, { error: "insecure_device_origin" });
    const credential = this.cookieValue(req, ["__Host-pi_voice_device", "pi_voice_device"]);
    if (!credential) { this.clearAuthCookies(req, res); return this.json(res, 401, { error: "invalid_device" }); }
    const renewed = await this.deviceStore.renew(this.requestOrigin(req), credential);
    if (!renewed.ok) { if (renewed.reason !== "wrong_origin") this.clearAuthCookies(req, res); return this.json(res, 401, { error: renewed.reason }); }
    this.issueBrowserSession(req, res, renewed.device);
  }

  private async revokeBrowserDevice(res: ServerResponse, body: Record<string, unknown>): Promise<void> {
    if (typeof body.deviceId !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(body.deviceId)) return this.json(res, 400, { error: "invalid_request" });
    const device = await this.deviceStore.revoke(body.deviceId); if (!device) return this.json(res, 404, { error: "device_not_found" });
    for (const [sessionId, session] of this.browserSessions) if (session.deviceId === device.id) this.browserSessions.delete(sessionId);
    for (const client of this.ws.clients) {
      const auth = this.wsAuth.get(client); if (auth && "deviceId" in auth && auth.deviceId === device.id) client.close(4003, "device_revoked");
    }
    if (this.liveStartingOwnerDeviceId === device.id) this.liveStartingRevoked = true;
    if (this.liveOwnerDeviceId === device.id && this.liveControl?.active) this.liveControl.close("device_revoked");
    this.json(res, 200, { device });
  }

  private async handleHttp(req: IncomingMessage, res: ServerResponse): Promise<void> {
    try {
      if (!this.validBrowserRequest(req)) return this.json(res, 403, { error: "invalid_host_or_origin" });
      const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
      if (url.pathname.startsWith("/api/") && !this.validBrowserRequest(req, true)) return this.json(res, 403, { error: "invalid_origin" });
      if (req.method === "POST" && url.pathname === "/api/browser-pairing") {
        if (!this.authorizedBearer(req)) return this.json(res, 401, { error: "unauthorized" });
        return this.createBrowserPairing(res);
      }
      if (req.method === "POST" && url.pathname === "/api/browser-session/pair") return await this.redeemBrowserPairing(req, res, await this.readJson(req, 4 * 1024));
      if (req.method === "POST" && url.pathname === "/api/browser-session/renew") return await this.renewBrowserSession(req, res);
      if (req.method === "GET" && url.pathname === "/api/browser-devices") {
        if (!this.authorizedBearer(req)) return this.json(res, 401, { error: "unauthorized" }); return this.json(res, 200, { devices: this.deviceStore.list(), policy: this.policy() });
      }
      if (req.method === "POST" && url.pathname === "/api/browser-devices/revoke") {
        if (!this.authorizedBearer(req)) return this.json(res, 401, { error: "unauthorized" }); return await this.revokeBrowserDevice(res, await this.readJson(req, 4 * 1024));
      }
      const auth = this.authorization(req);
      if (url.pathname.startsWith("/api/") && !auth) return this.json(res, 401, { error: "unauthorized" });
      if (req.method === "GET" && url.pathname === "/api/browser-device") {
        if (!auth || "owner" in auth || !auth.deviceId) return this.json(res, 409, { error: "local_owner_has_no_device" });
        const device = this.deviceStore.current(auth.deviceId); return device?.status === "active" ? this.json(res, 200, { device, policy: this.policy() }) : this.json(res, 401, { error: device?.status === "revoked" ? "revoked_device" : "expired_device" });
      }

      if (req.method === "GET" && url.pathname === "/api/relay") return this.relay ? this.json(res, 200, this.relay.snapshot()) : this.json(res, 503, { error: "relay_not_configured" });
      if (req.method === "GET" && url.pathname === "/api/live/diagnostics/recent-text") {
        if (!this.authorizedBearer(req)) return this.json(res, 401, { error: "unauthorized" });
        const control = this.liveControl, generation = this.liveGeneration, lastClosed = this.terminalDiagnostics();
        const terminalText = lastClosed ? { generation: lastClosed.generation, snapshotPhase: lastClosed.snapshotPhase, closure: { ...lastClosed.closure }, closedAt: lastClosed.closedAt, expiresAt: lastClosed.expiresAt, events: lastClosed.recentText.map((event) => ({ ...event })) } : null;
        return this.json(res, 200, {
          current: control?.active && generation ? { generation, snapshotPhase: "active", events: control.recentText } : terminalText,
          lastClosed: terminalText,
        });
      }
      if (req.method === "GET" && url.pathname === "/api/live/diagnostics") return this.json(res, 200, this.liveDiagnostics());
      if (req.method === "POST" && url.pathname === "/api/live/diagnostics/provider-event-types") return await this.reportProviderEventTypes(req, res, auth!);
      if (req.method === "POST" && url.pathname === "/api/focus-lease") return await this.updateFocusLease(req, res);
      if (req.method === "POST" && url.pathname === "/api/relay/send") return await this.sendRelayMessage(req, res);
      if (req.method === "POST" && url.pathname === "/api/live/session") return await this.createLiveSession(req, res, auth!);
      if (req.method === "POST" && url.pathname === "/api/live/media-ready") return await this.setLiveMediaReady(req, res, auth!);
      if (req.method === "POST" && url.pathname === "/api/live/closure-receipt") return await this.getLiveClosureReceipt(req, res, auth!);
      if (req.method === "POST" && url.pathname === "/api/live/close") return await this.closeLiveSession(req, res);
      if (req.method === "POST" && url.pathname === "/api/live/ptt") return await this.setPushToTalk(req, res);
      if (req.method === "POST" && url.pathname === "/api/live/reply-context") return await this.setLiveReplyContext(req, res);
      if (req.method === "POST" && url.pathname === "/api/live/focus") return await this.setLiveFocus(req, res);
      if (req.method === "GET" || req.method === "HEAD") return await this.serveStatic(url.pathname, res, req.method === "HEAD");
      this.json(res, 404, { error: "not_found" });
    } catch (error) {
      this.json(res, 500, { error: "internal_error", message: error instanceof Error ? error.message : String(error) });
    }
  }

  private async readJson(req: IncomingMessage, limit = 64 * 1024): Promise<Record<string, unknown>> {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of req) {
      const b = Buffer.from(chunk);
      size += b.length;
      if (size > limit) throw new Error("request_too_large");
      chunks.push(b);
    }
    const value: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_json_object");
    return value as Record<string, unknown>;
  }

  private async sendRelayMessage(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (!this.relay) return this.json(res, 503, { error: "relay_not_configured" });
    const body = await this.readJson(req, 768 * 1024);
    const { targetId, targetEpoch, text, attachments, messageId, reply } = body;
    if (typeof targetId !== "string" || typeof targetEpoch !== "string" || typeof text !== "string" || typeof messageId !== "string"
      || (attachments !== undefined && !Array.isArray(attachments))
      || (reply !== undefined && (!reply || typeof reply !== "object" || Array.isArray(reply)))) {
      return this.json(res, 400, { error: "invalid_request" });
    }
    const replyValue = reply as Record<string, unknown> | undefined;
    if (replyValue && (typeof replyValue.messageId !== "string" || typeof replyValue.senderId !== "string" || typeof replyValue.senderEpoch !== "string")) return this.json(res, 400, { error: "invalid_reply_target" });
    const relayAttachments: RelayAttachment[] | undefined = attachments?.flatMap((value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return [];
      const item = value as Record<string, unknown>;
      return (item.type === "file" || item.type === "snippet" || item.type === "context") && typeof item.name === "string" && typeof item.content === "string" && (item.language === undefined || typeof item.language === "string")
        ? [{ type: item.type, name: item.name, content: item.content, ...(typeof item.language === "string" ? { language: item.language } : {}) }]
        : [];
    });
    if (attachments && relayAttachments?.length !== attachments.length) return this.json(res, 400, { error: "invalid_attachments" });
    try {
      const entry = await this.relay.send({
        targetId, targetEpoch, text,
        ...(relayAttachments?.length ? { attachments: relayAttachments } : {}),
        ...(replyValue ? { reply: { messageId: replyValue.messageId as string, senderId: replyValue.senderId as string, senderEpoch: replyValue.senderEpoch as string } } : {}),
        messageId, source: "human",
      });
      this.json(res, 201, { message: entry });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = /stale_relay_target|reply_target_mismatch/.test(message) ? 409 : /out_of_bounds|invalid/.test(message) ? 400 : 502;
      this.json(res, status, { error: message.split(":", 1)[0], message: message.slice(0, 300) });
    }
  }

  private clearLiveStarting(): void { this.liveStarting = false; this.liveStartingOwnerDeviceId = null; this.liveStartingConnectionId = null; this.liveStartingRevoked = false; this.liveStartingConnectionLost = false; }

  private async createLiveSession(req: IncomingMessage, res: ServerResponse, auth: { owner: true } | { sessionId: string; deviceId: string | null; origin: string }): Promise<void> {
    if (!this.options.openAiKey) return this.json(res, 503, { error: "voice_not_configured" });
    if (!this.relay) return this.json(res, 503, { error: "relay_not_configured" });
    if (this.liveStarting || this.liveControl?.occupied) return this.json(res, 409, { error: "voice_already_active" });
    const body = await this.readJson(req, 256 * 1024);
    if (typeof body.sdp !== "string" || body.sdp.length < 10 || body.sdp.length > 200_000) return this.json(res, 400, { error: "invalid_sdp" });
    if (typeof body.targetId !== "string" || typeof body.targetEpoch !== "string" || !isLiveVoice(body.voice) || (body.inputMode !== "continuous" && body.inputMode !== "ptt") || (body.routingMode !== "direct" && body.routingMode !== "liaison")) return this.json(res, 400, { error: "invalid_request" });
    if (body.idleTimeoutMinutes !== undefined && (!Number.isSafeInteger(body.idleTimeoutMinutes) || Number(body.idleTimeoutMinutes) < 1 || Number(body.idleTimeoutMinutes) > 30)) return this.json(res, 400, { error: "invalid_idle_timeout" });
    if (!this.authorizationActive(auth)) return this.json(res, 401, { error: "revoked_device" });
    const ownerConnectionId = this.liveConnection(auth, body.connectionId);
    if (!("owner" in auth) && !ownerConnectionId) return this.json(res, 409, { error: "stale_voice_connection" });
    // Atomic claim: no await may occur between this second check and assignment.
    if (this.liveStarting || this.liveControl?.occupied) return this.json(res, 409, { error: "voice_already_active" });
    this.liveStarting = true; this.liveStartingOwnerDeviceId = "owner" in auth ? null : auth.deviceId; this.liveStartingConnectionId = ownerConnectionId; this.liveStartingRevoked = false; this.liveStartingConnectionLost = false;
    let target = this.relay.target(body.targetId, body.targetEpoch);
    if (!target) { this.clearLiveStarting(); return this.json(res, 409, { error: "stale_relay_target" }); }
    const generation = randomBytes(16).toString("base64url");
    try {
      await this.relay.activateHuman(generation);
      await this.relay.refreshRoster();
      target = this.relay.target(body.targetId, body.targetEpoch);
      if (!target) { await this.deactivateHuman(generation); this.clearLiveStarting(); return this.json(res, 409, { error: "stale_relay_target" }); }
      if (this.liveStartingRevoked || !this.authorizationActive(auth)) { await this.deactivateHuman(generation); this.clearLiveStarting(); return this.json(res, 401, { error: "revoked_device" }); }
      if (this.liveStartingConnectionLost || !this.liveConnectionActive(ownerConnectionId)) { await this.deactivateHuman(generation); this.clearLiveStarting(); return this.json(res, 409, { error: "voice_connection_lost" }); }
    } catch (error) {
      await this.deactivateHuman(generation); this.clearLiveStarting();
      return this.json(res, 503, { error: "voice_human_endpoint_failed", message: error instanceof Error ? error.message.slice(0, 300) : "unknown" });
    }
    let upstream: Response, rawPayload: unknown;
    const providerRequest = liveSessionRequest(target.name ?? target.id, body.sdp, body.voice, body.routingMode as LiveRoutingMode);
    const requestedInstructionHash = createHash("sha256").update(providerRequest.session.instructions).digest("hex");
    const upstreamAbort = new AbortController();
    const upstreamTimeout = setTimeout(() => upstreamAbort.abort(new Error("Live session creation timed out")), 15_000);
    try {
      upstream = await (this.options.fetchImpl ?? fetch)("https://api.openai.com/v1/live/sessions", {
        method: "POST",
        headers: { authorization: `Bearer ${this.options.openAiKey}`, "content-type": "application/json" },
        body: JSON.stringify(providerRequest),
        signal: upstreamAbort.signal,
      });
      rawPayload = await upstream.json().catch((error) => { if (upstreamAbort.signal.aborted) throw error; return {}; });
    } catch (error) {
      await this.deactivateHuman(generation); this.clearLiveStarting();
      return this.json(res, 502, { error: "live_session_failed", message: error instanceof Error ? error.message.slice(0, 300) : "network_error" });
    } finally {
      clearTimeout(upstreamTimeout);
    }
    const payload: LiveSession = rawPayload && typeof rawPayload === "object" && !Array.isArray(rawPayload) ? rawPayload as LiveSession : {};
    if (!upstream.ok || payload.transport?.type !== "webrtc" || typeof payload.transport.sdp !== "string") {
      // Surface only selected bounded diagnostics. Never return the SDP, key, request body, or raw upstream payload.
      const clean = (value: unknown, max = 300) => typeof value === "string"
        ? value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, max)
        : "";
      const upstreamError: Record<string, string | number> = { status: upstream.status };
      const requestId = clean(upstream.headers.get("x-request-id"), 200);
      const type = clean(payload.error?.type);
      const code = clean(payload.error?.code);
      const message = clean(payload.error?.message);
      if (requestId) upstreamError.requestId = requestId;
      if (type) upstreamError.type = type;
      if (code) upstreamError.code = code;
      if (message) upstreamError.message = message;
      await this.deactivateHuman(generation); this.clearLiveStarting();
      return this.json(res, 502, { error: "live_session_failed", upstream: upstreamError });
    }
    if (typeof payload.session?.id !== "string") {
      await this.deactivateHuman(generation); this.clearLiveStarting();
      return this.json(res, 502, { error: "live_session_missing_id" });
    }
    try {
      const sideband = await (this.options.sidebandFactory ?? openSideband)(payload.session.id, this.options.openAiKey);
      if (this.liveStartingRevoked || !this.authorizationActive(auth)) {
        sideband.startReading?.(); sideband.send(JSON.stringify({ type: "session.close" })); sideband.close(); await this.deactivateHuman(generation);
        return this.json(res, 401, { error: "revoked_device", cleanup: "sideband_close_sent" });
      }
      if (this.liveStartingConnectionLost || !this.liveConnectionActive(ownerConnectionId)) {
        sideband.startReading?.(); sideband.send(JSON.stringify({ type: "session.close" })); sideband.close(); await this.deactivateHuman(generation);
        return this.json(res, 409, { error: "voice_connection_lost", cleanup: "sideband_close_sent" });
      }
      this.liveTarget = { id: target.id, endpointEpoch: target.endpointEpoch };
      this.liveReply = null; this.liveRoutingMode = body.routingMode as LiveRoutingMode; this.liveOwnerDeviceId = "owner" in auth ? null : auth.deviceId; this.liveOwnerOrigin = "owner" in auth ? null : auth.origin; this.liveOwnerConnectionId = ownerConnectionId; this.liaisonReplies.clear();
      this.liveGeneration = generation;
      this.liveSendDiagnostics = { attempts: 0, delivered: 0, knownFailed: 0, unknown: 0 };
      const receiptOwnerDeviceId = this.liveOwnerDeviceId, receiptOrigin = this.liveOwnerOrigin;
      let control!: LiveControl;
      control = new LiveControl({ socket: sideband, inputMode: body.inputMode as LiveInputMode, routingMode: body.routingMode as LiveRoutingMode, idleTimeoutMs: Number(body.idleTimeoutMinutes ?? 5) * 60_000, greeting: greetingForAgent(target.name), providerStartup: providerStartupDiagnostic(payload.session, requestedInstructionHash), resolveProviderStartup: (session) => providerStartupDiagnostic(session, requestedInstructionHash, "sideband_session_started"), publish: (event) => {
        this.broadcast({ ...event, generation });
        if (event.type === "voice_utterance") void this.routeVoiceUtterance(event, generation);
        if (event.type === "voice_liaison_request") void this.routeLiaisonRequest(event, generation);
      }, onClosed: () => {
        if (this.liveControl === control) {
          const terminal = control.takeTerminalSnapshot();
          if (terminal) {
            if (receiptOwnerDeviceId && receiptOrigin) this.storeClosureReceipt(generation, receiptOwnerDeviceId, receiptOrigin, terminal.closure);
            const closedAt = (this.options.now ?? Date.now)();
            const ttl = Math.max(1, Math.min(this.options.terminalDiagnosticTtlMs ?? TERMINAL_DIAGNOSTIC_TTL_MS, TERMINAL_DIAGNOSTIC_TTL_MS));
            const stored: StoredTerminalDiagnostics = {
              generation,
              active: false,
              snapshotPhase: "closed",
              closure: { ...terminal.closure },
              closedAt,
              expiresAt: closedAt + ttl,
              control: terminal.control,
              sends: { ...this.liveSendDiagnostics },
              recentText: terminal.recentText,
            };
            this.storeTerminalDiagnostics(stored, ttl);
          }
          this.liveControl = null; this.liveTarget = null; this.liveReply = null; this.liveGeneration = null; this.liveRoutingMode = null; this.liveOwnerDeviceId = null; this.liveOwnerOrigin = null; this.liveOwnerConnectionId = null; this.liaisonReplies.clear(); void this.deactivateHuman(generation); void this.clearFocusLease();
        }
      } });
      this.liveControl = control;
      sideband.on("message", (data) => control.receive(data.toString()));
      sideband.on("close", () => control.sidebandLost());
      sideband.on("error", (error) => control.sidebandLost(error.message));
      sideband.startReading?.();
      this.json(res, 200, { sessionId: payload.session.id, generation, sdp: payload.transport.sdp, voice: body.voice, inputMode: body.inputMode, routingMode: body.routingMode, ...control.deadlines });
    } catch (error) {
      // The documented close command requires a sideband. Retry one bounded attach solely to close;
      // if both attaches fail, no documented REST close exists and provider cleanup cannot be guaranteed.
      await this.closeOrphanedLiveSession(payload.session.id); await this.deactivateHuman(generation);
      this.json(res, 502, { error: "live_sideband_failed", message: error instanceof Error ? error.message.slice(0, 300) : "unknown", cleanup: "best_effort_sideband_close" });
    } finally {
      this.clearLiveStarting();
    }
  }

  private async reportProviderEventTypes(req: IncomingMessage, res: ServerResponse, auth: { owner: true } | { sessionId: string; deviceId: string | null; origin: string }): Promise<void> {
    const body = await this.readJson(req, 8 * 1024), control = this.liveControl, generation = this.liveGeneration;
    const observations = body.observations;
    const validObservations = Array.isArray(observations) && observations.length <= 32 && observations.every((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) return false;
      const value = entry as Record<string, unknown>;
      return typeof value.type === "string" && /^[A-Za-z0-9._-]{1,80}$/.test(value.type)
        && Number.isSafeInteger(value.count) && Number(value.count) > 0;
    });
    const uniqueTypes = validObservations ? new Set((observations as Array<{ type: string }>).map((entry) => entry.type)).size === observations.length : false;
    const connectionId = this.liveConnection(auth, body.connectionId);
    if (!control?.active || !generation || body.generation !== generation || !connectionId || connectionId !== this.liveOwnerConnectionId
      || !Number.isSafeInteger(body.sequence) || Number(body.sequence) <= 0 || !Number.isSafeInteger(body.overflow) || Number(body.overflow) < 0
      || !validObservations || !uniqueTypes) return this.json(res, 409, { error: "stale_or_invalid_provider_event_report" });
    const boundedObservations = (observations as Array<{ type: string; count: number }>).map((entry) => ({ type: entry.type, count: entry.count }));
    const outcome = control.recordPrimaryEventTypes(Number(body.sequence), boundedObservations, Number(body.overflow));
    if (outcome === "rate_limited") return this.json(res, 429, { error: "provider_event_report_rate_limited" });
    if (outcome === "stale") return this.json(res, 409, { error: "stale_or_invalid_provider_event_report" });
    this.json(res, 200, { accepted: true });
  }

  private focusLeasePath(): string { return this.options.focusLeaseFile ?? join(homedir(), ".pi-companion", "voice-focus.json"); }

  private async updateFocusLease(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await this.readJson(req), revision = ++this.focusLeaseRevision;
    if (body.active === false) { await this.clearFocusLease(revision); return this.json(res, 200, { active: false }); }
    const control = this.liveControl, target = this.liveTarget, generation = this.liveGeneration;
    if (body.active !== true || !control?.active || !target || typeof body.generation !== "string" || body.generation !== generation || body.targetId !== target.id || body.targetEpoch !== target.endpointEpoch || !this.relay?.target(target.id, target.endpointEpoch)) {
      await this.clearFocusLease(revision); return this.json(res, 409, { error: "stale_focus_lease" });
    }
    const now = Date.now(), file = this.focusLeasePath(), dir = dirname(file), temp = `${file}.${process.pid}.${randomBytes(8).toString("hex")}.tmp`;
    await mkdir(dir, { recursive: true, mode: 0o700 }); await chmod(dir, 0o700);
    const payload = { schemaVersion: 1, generation, agentId: target.id, endpointEpoch: target.endpointEpoch, updatedAt: now, expiresAt: now + 15_000 };
    try {
      await writeFile(temp, `${JSON.stringify(payload)}\n`, { mode: 0o600, flag: "wx" }); await chmod(temp, 0o600);
      if (revision !== this.focusLeaseRevision || this.liveGeneration !== generation) { await rm(temp, { force: true }); return this.json(res, 409, { error: "stale_focus_lease" }); }
      await rename(temp, file); this.json(res, 200, { active: true, expiresAt: payload.expiresAt });
    } catch (error) { await rm(temp, { force: true }); throw error; }
  }

  private async clearFocusLease(revision = ++this.focusLeaseRevision): Promise<void> {
    if (revision !== this.focusLeaseRevision) return;
    await rm(this.focusLeasePath(), { force: true });
  }

  private async deactivateHuman(generation: string): Promise<void> {
    try { await this.relay?.deactivateHuman(generation); }
    catch (error) { this.broadcast({ type: "relay_error", code: "voice_human_disconnect_failed", message: error instanceof Error ? error.message.slice(0, 300) : "unknown" }); }
  }

  private removeClosureReceipt(generation: string, expected?: ProviderClosureReceipt): void {
    const current = this.closureReceipts.get(generation);
    if (!current || (expected && current !== expected)) return;
    const timer = this.closureReceiptTimers.get(generation); if (timer) clearTimeout(timer);
    this.closureReceiptTimers.delete(generation); this.closureReceipts.delete(generation);
  }

  private storeClosureReceipt(generation: string, ownerDeviceId: string, origin: string, closure: { reason: string; providerClosed: boolean }): void {
    this.removeClosureReceipt(generation);
    while (this.closureReceipts.size >= 32) this.removeClosureReceipt(this.closureReceipts.keys().next().value as string);
    const now = (this.options.now ?? Date.now)();
    const ttl = Math.max(1, Math.min(this.options.closureReceiptTtlMs ?? TERMINAL_DIAGNOSTIC_TTL_MS, TERMINAL_DIAGNOSTIC_TTL_MS));
    const receipt: ProviderClosureReceipt = { generation, ownerDeviceId, origin, closed: 1, providerClosed: closure.providerClosed ? 1 : 0, reason: closure.reason.slice(0, 80), expiresAt: now + ttl };
    this.closureReceipts.set(generation, receipt);
    const timer = setTimeout(() => this.removeClosureReceipt(generation, receipt), ttl); timer.unref?.(); this.closureReceiptTimers.set(generation, timer);
  }

  private currentClosureReceipt(generation: string): ProviderClosureReceipt | null {
    const receipt = this.closureReceipts.get(generation);
    if (!receipt) return null;
    if ((this.options.now ?? Date.now)() >= receipt.expiresAt) { this.removeClosureReceipt(generation, receipt); return null; }
    return receipt;
  }

  private clearTerminalDiagnostics(expected?: StoredTerminalDiagnostics): void {
    if (expected && this.lastLiveDiagnostics !== expected) return;
    if (this.terminalDiagnosticExpiryTimer) clearTimeout(this.terminalDiagnosticExpiryTimer);
    this.terminalDiagnosticExpiryTimer = null;
    this.lastLiveDiagnostics = null;
  }

  private storeTerminalDiagnostics(terminal: StoredTerminalDiagnostics, ttlMs: number): void {
    this.clearTerminalDiagnostics();
    this.lastLiveDiagnostics = terminal;
    this.terminalDiagnosticExpiryTimer = setTimeout(() => this.clearTerminalDiagnostics(terminal), ttlMs);
    this.terminalDiagnosticExpiryTimer.unref?.();
  }

  private terminalDiagnostics(): StoredTerminalDiagnostics | null {
    const terminal = this.lastLiveDiagnostics;
    if (!terminal) return null;
    if ((this.options.now ?? Date.now)() >= terminal.expiresAt) {
      this.clearTerminalDiagnostics(terminal);
      return null;
    }
    return terminal;
  }

  private publicTerminalDiagnostics(terminal: StoredTerminalDiagnostics | null): Omit<StoredTerminalDiagnostics, "recentText"> | null {
    if (!terminal) return null;
    const { recentText: _recentText, ...safe } = terminal;
    return structuredClone(safe);
  }

  private liveDiagnostics(): { current: StoredLiveDiagnostics | Omit<StoredTerminalDiagnostics, "recentText"> | null; lastClosed: Omit<StoredTerminalDiagnostics, "recentText"> | null } {
    const lastClosed = this.publicTerminalDiagnostics(this.terminalDiagnostics());
    if (this.liveControl && this.liveGeneration) {
      return {
        current: { generation: this.liveGeneration, active: this.liveControl.active, control: this.liveControl.diagnostics, sends: { ...this.liveSendDiagnostics } },
        lastClosed,
      };
    }
    return { current: lastClosed, lastClosed };
  }

  private async closeOrphanedLiveSession(sessionId: string): Promise<void> {
    if (!this.options.openAiKey) return;
    try {
      const sideband = await (this.options.sidebandFactory ?? openSideband)(sessionId, this.options.openAiKey);
      sideband.startReading?.();
      sideband.send(JSON.stringify({ type: "session.close", event_id: randomBytes(12).toString("base64url") }));
      setTimeout(() => sideband.close(), 2_000).unref?.();
    } catch { /* attach is the only documented close path; caller reports best-effort status */ }
  }

  private async closeLiveSession(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await this.readJson(req), control = this.liveControl;
    if (!control?.active || typeof body.generation !== "string" || body.generation !== this.liveGeneration) return this.json(res, 409, { error: "stale_voice_generation" });
    if (this.liveControl !== control || body.generation !== this.liveGeneration) return this.json(res, 409, { error: "stale_voice_generation" });
    await this.deactivateHuman(body.generation); control.close("browser_stop"); this.json(res, 202, { closing: true });
  }

  private async getLiveClosureReceipt(req: IncomingMessage, res: ServerResponse, auth: { owner: true } | { sessionId: string; deviceId: string | null; origin: string }): Promise<void> {
    const body = await this.readJson(req);
    if ("owner" in auth || !auth.deviceId || typeof body.generation !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(body.generation) || !this.authorizationActive(auth)) {
      return this.json(res, 404, { error: "closure_unconfirmed" });
    }
    const generation = body.generation;
    if (this.liveGeneration === generation && this.liveControl?.occupied && this.liveOwnerDeviceId === auth.deviceId && this.liveOwnerOrigin === auth.origin) {
      return this.json(res, 200, { closed: 0, providerClosed: 0 });
    }
    const receipt = this.currentClosureReceipt(generation);
    if (!receipt || receipt.ownerDeviceId !== auth.deviceId || receipt.origin !== auth.origin) return this.json(res, 404, { error: "closure_unconfirmed" });
    this.json(res, 200, { closed: receipt.closed, providerClosed: receipt.providerClosed });
  }

  private async setLiveMediaReady(req: IncomingMessage, res: ServerResponse, auth: { owner: true } | { sessionId: string; deviceId: string | null; origin: string }): Promise<void> {
    const body = await this.readJson(req), control = this.liveControl;
    const exactConnection = this.liveConnection(auth, body.connectionId);
    if (!control?.active || typeof body.generation !== "string" || body.generation !== this.liveGeneration ||
        !exactConnection || exactConnection !== this.liveOwnerConnectionId) {
      return this.json(res, 409, { error: "stale_voice_generation_or_connection" });
    }
    // All authority checks precede the one-shot mutation, with no await between
    // validation and enqueueing.
    const enqueued = control.enqueueGreeting();
    this.json(res, 202, { accepted: 1, enqueued });
  }

  private async setPushToTalk(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await this.readJson(req), control = this.liveControl;
    if (!control?.active || typeof body.generation !== "string" || body.generation !== this.liveGeneration || typeof body.held !== "boolean" || typeof body.commandSequence !== "number" || !Number.isSafeInteger(body.commandSequence) || body.commandSequence <= 0 || (body.cancel !== undefined && typeof body.cancel !== "boolean")) return this.json(res, 409, { error: "stale_voice_generation_or_invalid_ptt" });
    if (this.liveControl !== control || body.generation !== this.liveGeneration || !control.setPushToTalkHeld(body.held, body.cancel === true, body.commandSequence)) return this.json(res, 409, { error: "stale_or_inactive_ptt_command" });
    this.json(res, 200, { held: body.held, cancelled: body.cancel === true, commandSequence: body.commandSequence });
  }

  private async setLiveFocus(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await this.readJson(req), control = this.liveControl;
    if (!this.relay || !control?.active || !this.liveTarget || typeof body.generation !== "string" || body.generation !== this.liveGeneration || typeof body.targetId !== "string" || typeof body.targetEpoch !== "string") return this.json(res, 409, { error: "voice_not_active_or_invalid" });
    const target = this.relay.target(body.targetId, body.targetEpoch);
    if (!target || this.liveControl !== control || !control.active) return this.json(res, 409, { error: "stale_voice_target" });
    if (body.generation !== this.liveGeneration) return this.json(res, 409, { error: "stale_voice_generation" });
    if (target.id !== this.liveTarget.id || target.endpointEpoch !== this.liveTarget.endpointEpoch) return this.json(res, 409, { error: "voice_focus_change_requires_restart" });
    this.json(res, 200, { target: this.liveTarget, unchanged: true });
  }

  private async setLiveReplyContext(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await this.readJson(req), control = this.liveControl;
    if (!this.relay || !control?.active || !this.liveTarget || typeof body.generation !== "string" || body.generation !== this.liveGeneration) return this.json(res, 409, { error: "voice_not_active" });
    if (body.clear === true) { if (this.liveControl !== control || !control.active) return this.json(res, 409, { error: "voice_not_active" }); this.liveReply = null; return this.json(res, 200, { reply: null }); }
    if (typeof body.messageId !== "string" || typeof body.senderId !== "string" || typeof body.senderEpoch !== "string") return this.json(res, 400, { error: "invalid_request" });
    if (body.senderId !== this.liveTarget.id || body.senderEpoch !== this.liveTarget.endpointEpoch) return this.json(res, 409, { error: "reply_target_not_focused" });
    const reply = this.relay.replyTarget(body.messageId, body.senderId, body.senderEpoch);
    if (!reply || this.liveControl !== control || !control.active) return this.json(res, 409, { error: "stale_reply_context" });
    this.liveReply = reply; this.json(res, 200, { reply });
  }

  private async routeVoiceUtterance(event: Extract<LiveControlEvent, { type: "voice_utterance" }>, generation: string): Promise<void> {
    const relay = this.relay, control = this.liveControl, target = this.liveTarget;
    if (!relay || !target || !control?.active || this.liveGeneration !== generation) return;
    const pinned = { ...target }, reply = this.liveReply ? { ...this.liveReply } : null;
    if (reply) this.liveReply = null; // one utterance atomically claims the explicit reply tuple
    const sendDiagnostics = this.liveSendDiagnostics; sendDiagnostics.attempts++;
    try {
      const targetSession = relay.target(pinned.id, pinned.endpointEpoch);
      if (!targetSession) throw new Error("stale_voice_target");
      await relay.send({ targetId: pinned.id, targetEpoch: pinned.endpointEpoch, text: event.text, source: "voice", messageId: event.utteranceId, ...(reply ? { reply } : {}) });
      sendDiagnostics.delivered++;
      if (this.liveControl === control && this.liveGeneration === generation) control.appendStatus(`Delivered voice utterance ${event.utteranceId} to ${targetSession.name ?? targetSession.id}. Waiting for the Pi agent's native reply.`);
    } catch (error) {
      const code = error instanceof Error ? error.message.split(":", 1)[0] ?? "relay_send_failed" : "relay_send_failed";
      if (code === "relay_delivery_unknown") sendDiagnostics.unknown++; else sendDiagnostics.knownFailed++;
      if (reply && knownNoDelivery(code) && this.liveControl === control && this.liveGeneration === generation && !this.liveReply) this.liveReply = reply;
      if (this.liveControl === control && this.liveGeneration === generation) control.appendStatus(code === "relay_delivery_unknown" ? `Delivery outcome UNKNOWN for voice utterance ${event.utteranceId}; do not retry automatically.` : `Voice utterance ${event.utteranceId} was not delivered (${code}).`);
    }
  }

  private async routeLiaisonRequest(event: Extract<LiveControlEvent, { type: "voice_liaison_request" }>, generation: string): Promise<void> {
    const relay = this.relay, control = this.liveControl, target = this.liveTarget;
    if (!relay || !target || !control?.active || this.liveGeneration !== generation || this.liveRoutingMode !== "liaison") return;
    const pinned = { ...target }, sendDiagnostics = this.liveSendDiagnostics; sendDiagnostics.attempts++;
    this.liaisonReplies.set(event.requestId, { generation, delegationId: event.delegationId });
    while (this.liaisonReplies.size > 256) this.liaisonReplies.delete(this.liaisonReplies.keys().next().value as string);
    try {
      const targetSession = relay.target(pinned.id, pinned.endpointEpoch); if (!targetSession) throw new Error("stale_voice_target");
      await relay.send({ targetId: pinned.id, targetEpoch: pinned.endpointEpoch, text: event.text, source: "voice", messageId: event.requestId, expectsReply: true });
      sendDiagnostics.delivered++;
      if (this.liveControl === control && this.liveGeneration === generation && this.liveTarget?.id === pinned.id && this.liveTarget.endpointEpoch === pinned.endpointEpoch) {
        control.resolveLiaisonDispatch(event.requestId, event.transcriptFromSequence, event.transcriptThroughSequence, true);
        control.recordDeliveryDiagnostic("sent"); control.appendDelegationStatus(event.delegationId, "Sent.", true);
      }
    } catch (error) {
      const code = error instanceof Error ? error.message.split(":", 1)[0] ?? "relay_send_failed" : "relay_send_failed";
      if (code === "relay_delivery_unknown") sendDiagnostics.unknown++; else { sendDiagnostics.knownFailed++; this.liaisonReplies.delete(event.requestId); }
      if (this.liveControl === control && this.liveGeneration === generation && this.liveTarget?.id === pinned.id && this.liveTarget.endpointEpoch === pinned.endpointEpoch) {
        control.resolveLiaisonDispatch(event.requestId, event.transcriptFromSequence, event.transcriptThroughSequence, false);
        control.recordDeliveryDiagnostic(code === "relay_delivery_unknown" ? "unknown" : `failed:${code}`); control.appendDelegationStatus(event.delegationId, code === "relay_delivery_unknown" ? "The delivery outcome is unknown. Do not retry or claim failure; tell the user the outcome must be checked." : `The request was not delivered (${code}).`, true);
      }
    }
  }

  private forwardIncomingToLive(entry: RelayConversationMessage): void {
    if (!this.liveTarget || entry.from.id !== this.liveTarget.id || entry.from.endpointEpoch !== this.liveTarget.endpointEpoch) return;
    const sender = entry.from.name ?? entry.from.id, control = this.liveControl;
    if (!control) return;
    if (this.liveRoutingMode === "liaison") {
      const matched = entry.message.replyTo ? this.liaisonReplies.get(entry.message.replyTo) : undefined;
      control.appendIncomingAgentMessage(entry.message.id, `${entry.from.id}\u0000${entry.from.endpointEpoch}`, sender, entry.message.content.text, matched?.generation === this.liveGeneration ? matched.delegationId : null, entry.message.supersedes ?? null);
      return;
    }
    control.appendIncomingAgentMessage(entry.message.id, `${entry.from.id}\u0000${entry.from.endpointEpoch}`, sender, entry.message.content.text, null, entry.message.supersedes ?? null);
  }

  private async serveStatic(pathname: string, res: ServerResponse, head: boolean): Promise<void> {
    const relative = pathname === "/" ? "index.html" : normalize(pathname).replace(/^[/\\]+/, "");
    if (relative.includes("..")) return this.json(res, 404, { error: "not_found" });
    const file = join(this.options.publicDir, relative);
    try {
      const info = await stat(file);
      if (!info.isFile() || info.size > 2 * 1024 * 1024) throw new Error("not_file");
      const bytes = await readFile(file);
      const mime = ({ ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8" } as Record<string, string>)[extname(file)] ?? "application/octet-stream";
      res.writeHead(200, {
        "content-type": mime,
        "content-length": bytes.length,
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
        "content-security-policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; media-src blob:; connect-src 'self' ws: wss:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
      });
      res.end(head ? undefined : bytes);
    } catch {
      this.json(res, 404, { error: "not_found" });
    }
  }

  private sendWs(client: WebSocket, event: RelayStateEvent | LiveControlEvent | LiveGatewayEvent | VoiceConnectionEvent): void {
    if (client.readyState !== WebSocket.OPEN) return;
    const auth = this.wsAuth.get(client);
    if (!auth) return client.close(4001, "unauthorized");
    if ("sessionId" in auth) {
      const session = this.browserSessions.get(auth.sessionId), now = (this.options.now ?? Date.now)();
      if (!session || session.expiresAt <= now) return client.close(4001, "session_expired");
      if (auth.deviceId) {
        const device = this.deviceStore.current(auth.deviceId);
        if (!device || device.status !== "active" || device.origin !== auth.origin) return client.close(device?.status === "revoked" ? 4003 : 4001, device?.status === "revoked" ? "device_revoked" : "device_expired");
      }
    }
    if (client.bufferedAmount > 512 * 1024) return client.close(1013, "backpressure");
    client.send(JSON.stringify(event));
  }

  private broadcast(event: RelayStateEvent | LiveControlEvent | LiveGatewayEvent): void { for (const client of this.ws.clients) this.sendWs(client, event); }
  private json(res: ServerResponse, status: number, value: unknown): void {
    const body = Buffer.from(JSON.stringify(value));
    res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": body.length, "cache-control": "no-store", "x-content-type-options": "nosniff" });
    res.end(body);
  }
}

async function openSideband(sessionId: string, openAiKey: string): Promise<SidebandConnection> {
  const socket = new WebSocket(`wss://api.openai.com/v1/live/sessions/${encodeURIComponent(sessionId)}/attach`, {
    headers: { authorization: `Bearer ${openAiKey}` },
  }) as SidebandConnection & WebSocket;
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => { socket.close(); reject(new Error("Live sideband attach timed out")); }, 10_000);
    socket.once("open", () => {
      // Remain paused across both await boundaries. The caller explicitly resumes
      // only after message, close, and error handlers are all installed.
      socket.pause(); clearTimeout(timeout); resolve();
    });
    socket.once("error", (error) => { clearTimeout(timeout); reject(error); });
  });
  socket.startReading = () => socket.resume();
  return socket;
}

function knownNoDelivery(code: string): boolean {
  return ["relay_delivery_failed", "stale_voice_target", "stale_relay_target", "reply_target_mismatch", "message_text_out_of_bounds"].includes(code);
}
