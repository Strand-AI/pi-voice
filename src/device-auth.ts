import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { chmod, mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export const DEVICE_IDLE_TTL_MS = 90 * 24 * 60 * 60_000;
export const DEVICE_ABSOLUTE_TTL_MS = 365 * 24 * 60 * 60_000;
export const MAX_ACTIVE_DEVICES = 16;
const MAX_DEVICE_RECORDS = 64;

export type DeviceStatus = "active" | "expired" | "revoked";
export type PublicDevice = {
  id: string;
  name: string;
  origin: string;
  status: DeviceStatus;
  createdAt: number;
  lastUsedAt: number;
  idleExpiresAt: number;
  absoluteExpiresAt: number;
  revokedAt?: number;
};

type StoredDevice = {
  id: string;
  name: string;
  origin: string;
  credentialHash: string;
  createdAt: number;
  lastUsedAt: number;
  absoluteExpiresAt: number;
  revokedAt?: number;
};
type StoredState = { schemaVersion: 1; devices: StoredDevice[] };

export class DeviceLimitError extends Error {
  constructor() { super("device_limit_reached"); }
}

function credentialHash(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function validTime(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function validateStoredDevice(value: unknown): value is StoredDevice {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const item = value as Record<string, unknown>;
  const keys = Object.keys(item).sort().join(",");
  const expected = item.revokedAt === undefined
    ? "absoluteExpiresAt,createdAt,credentialHash,id,lastUsedAt,name,origin"
    : "absoluteExpiresAt,createdAt,credentialHash,id,lastUsedAt,name,origin,revokedAt";
  return keys === expected
    && typeof item.id === "string" && /^[A-Za-z0-9_-]{22}$/.test(item.id)
    && typeof item.name === "string" && Array.from(item.name).length >= 1 && Array.from(item.name).length <= 80
    && typeof item.origin === "string" && new URL(item.origin).origin === item.origin
    && typeof item.credentialHash === "string" && /^[a-f0-9]{64}$/.test(item.credentialHash)
    && validTime(item.createdAt) && validTime(item.lastUsedAt) && validTime(item.absoluteExpiresAt)
    && item.lastUsedAt >= item.createdAt && item.lastUsedAt <= item.absoluteExpiresAt && item.absoluteExpiresAt === item.createdAt + DEVICE_ABSOLUTE_TTL_MS
    && (item.revokedAt === undefined || (validTime(item.revokedAt) && item.revokedAt >= item.createdAt));
}

function normalizeName(value: unknown): string {
  if (value === undefined) return "Browser device";
  if (typeof value !== "string") throw new Error("invalid_device_name");
  const name = value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  if (!name || Array.from(name).length > 80) throw new Error("invalid_device_name");
  return name;
}

function exactOrigin(value: string): string {
  const parsed = new URL(value);
  if (parsed.origin !== value || !["http:", "https:"].includes(parsed.protocol)) throw new Error("invalid_origin");
  return parsed.origin;
}

export class DeviceAuthStore {
  private readonly file: string;
  private readonly now: () => number;
  private devices: StoredDevice[] = [];
  private opened = false;
  private mutationTail: Promise<void> = Promise.resolve();

  constructor(options: { file: string; now?: () => number }) {
    this.file = options.file;
    this.now = options.now ?? Date.now;
  }

  async open(): Promise<void> {
    await mkdir(dirname(this.file), { recursive: true, mode: 0o700 });
    await chmod(dirname(this.file), 0o700);
    try {
      const raw = await readFile(this.file, "utf8"), parsed = JSON.parse(raw) as unknown;
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("device_store_corrupt");
      const state = parsed as Record<string, unknown>;
      if (Object.keys(state).sort().join(",") !== "devices,schemaVersion" || state.schemaVersion !== 1 || !Array.isArray(state.devices) || state.devices.length > MAX_DEVICE_RECORDS || !state.devices.every(validateStoredDevice)) throw new Error("device_store_corrupt");
      const ids = new Set<string>(), hashes = new Set<string>();
      for (const device of state.devices) {
        if (ids.has(device.id) || hashes.has(device.credentialHash)) throw new Error("device_store_corrupt");
        ids.add(device.id); hashes.add(device.credentialHash);
      }
      const now = this.now(), activeCount = state.devices.filter((device) => device.revokedAt === undefined && now < device.absoluteExpiresAt && now < device.lastUsedAt + DEVICE_IDLE_TTL_MS).length;
      if (activeCount > MAX_ACTIVE_DEVICES) throw new Error("device_store_corrupt");
      this.devices = state.devices.map((device) => ({ ...device }));
      await chmod(this.file, 0o600);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw new Error("device_store_corrupt");
      this.devices = [];
    }
    this.opened = true;
  }

  async create(originValue: string, nameValue?: unknown): Promise<{ credential: string; device: PublicDevice }> {
    return await this.mutate(async () => {
      const now = this.now(), origin = exactOrigin(originValue), name = normalizeName(nameValue);
      if (this.devices.filter((device) => this.status(device, now) === "active").length >= MAX_ACTIVE_DEVICES) throw new DeviceLimitError();
      const candidate = this.pruned(this.devices.map((device) => ({ ...device })), now), credential = randomBytes(32).toString("base64url");
      const stored: StoredDevice = {
        id: randomBytes(16).toString("base64url"), name, origin, credentialHash: credentialHash(credential),
        createdAt: now, lastUsedAt: now, absoluteExpiresAt: now + DEVICE_ABSOLUTE_TTL_MS,
      };
      candidate.push(stored); await this.persist(candidate); this.devices = candidate;
      return { credential, device: this.publicDevice(stored, now) };
    });
  }

  async renew(originValue: string, credential: string): Promise<{ ok: true; device: PublicDevice } | { ok: false; reason: "invalid_device" | "wrong_origin" | "expired_device" | "revoked_device" }> {
    return await this.mutate(async () => {
      const now = this.now(), origin = exactOrigin(originValue), found = this.findCredential(credential);
      if (!found) return { ok: false, reason: "invalid_device" } as const;
      if (found.origin !== origin) return { ok: false, reason: "wrong_origin" } as const;
      const status = this.status(found, now);
      if (status === "revoked") return { ok: false, reason: "revoked_device" } as const;
      if (status === "expired") return { ok: false, reason: "expired_device" } as const;
      const index = this.devices.indexOf(found), candidate = this.devices.map((device) => ({ ...device })); candidate[index]!.lastUsedAt = now;
      await this.persist(candidate); this.devices = candidate;
      return { ok: true, device: this.publicDevice(candidate[index]!, now) } as const;
    });
  }

  current(deviceId: string): PublicDevice | null {
    this.assertOpen(); const device = this.devices.find((item) => item.id === deviceId);
    return device ? this.publicDevice(device, this.now()) : null;
  }

  active(deviceId: string, origin: string): boolean {
    const device = this.current(deviceId); return device?.status === "active" && device.origin === origin;
  }

  list(): PublicDevice[] {
    this.assertOpen(); const now = this.now();
    return this.devices.map((device) => this.publicDevice(device, now)).sort((a, b) => b.createdAt - a.createdAt);
  }

  async revoke(deviceId: string): Promise<PublicDevice | null> {
    return await this.mutate(async () => {
      const index = this.devices.findIndex((item) => item.id === deviceId); if (index < 0) return null;
      if (this.devices[index]!.revokedAt !== undefined) return this.publicDevice(this.devices[index]!, this.now());
      const candidate = this.devices.map((device) => ({ ...device })); candidate[index]!.revokedAt = this.now();
      await this.persist(candidate); this.devices = candidate;
      return this.publicDevice(candidate[index]!, this.now());
    });
  }

  private status(device: StoredDevice, now: number): DeviceStatus {
    if (device.revokedAt !== undefined) return "revoked";
    if (now >= device.absoluteExpiresAt || now >= device.lastUsedAt + DEVICE_IDLE_TTL_MS) return "expired";
    return "active";
  }

  private publicDevice(device: StoredDevice, now: number): PublicDevice {
    return {
      id: device.id, name: device.name, origin: device.origin, status: this.status(device, now),
      createdAt: device.createdAt, lastUsedAt: device.lastUsedAt,
      idleExpiresAt: Math.min(device.absoluteExpiresAt, device.lastUsedAt + DEVICE_IDLE_TTL_MS), absoluteExpiresAt: device.absoluteExpiresAt,
      ...(device.revokedAt !== undefined ? { revokedAt: device.revokedAt } : {}),
    };
  }

  private findCredential(credential: string): StoredDevice | null {
    if (!/^[A-Za-z0-9_-]{43}$/.test(credential)) return null;
    const wanted = Buffer.from(credentialHash(credential), "hex");
    let match: StoredDevice | null = null;
    for (const device of this.devices) {
      const candidate = Buffer.from(device.credentialHash, "hex");
      if (candidate.length === wanted.length && timingSafeEqual(candidate, wanted)) match = device;
    }
    return match;
  }

  private pruned(devices: StoredDevice[], now: number): StoredDevice[] {
    if (devices.length < MAX_DEVICE_RECORDS) return devices;
    const removable = devices.filter((device) => this.status(device, now) !== "active").sort((a, b) => (a.revokedAt ?? a.absoluteExpiresAt) - (b.revokedAt ?? b.absoluteExpiresAt));
    const remove = new Set(removable.slice(0, Math.max(0, devices.length - MAX_DEVICE_RECORDS + 1)).map((item) => item.id));
    const retained = devices.filter((device) => !remove.has(device.id));
    if (retained.length >= MAX_DEVICE_RECORDS) throw new DeviceLimitError();
    return retained;
  }

  private async mutate<T>(operation: () => Promise<T>): Promise<T> {
    this.assertOpen();
    let release!: () => void; const previous = this.mutationTail;
    this.mutationTail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try { return await operation(); } finally { release(); }
  }

  private assertOpen(): void { if (!this.opened) throw new Error("device_store_not_open"); }

  private async persist(devices: StoredDevice[]): Promise<void> {
    const state: StoredState = { schemaVersion: 1, devices };
    const temp = `${this.file}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
    try {
      await writeFile(temp, `${JSON.stringify(state)}\n`, { mode: 0o600, flag: "wx" });
      await chmod(temp, 0o600); await rename(temp, this.file); await chmod(this.file, 0o600);
      const info = await stat(this.file); if ((info.mode & 0o777) !== 0o600) throw new Error("device_store_permissions");
    } catch (error) { await rm(temp, { force: true }).catch(() => undefined); throw error; }
  }
}
