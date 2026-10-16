import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, rename, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DEVICE_ABSOLUTE_TTL_MS, DEVICE_IDLE_TTL_MS, DeviceAuthStore, DeviceLimitError, MAX_ACTIVE_DEVICES } from "../src/device-auth.ts";

async function setup(now: { value: number }) {
  const dir = await mkdtemp(join(tmpdir(), "pi-voice-devices-")), file = join(dir, "private", "devices.json");
  const store = new DeviceAuthStore({ file, now: () => now.value }); await store.open(); return { dir, file, store };
}

test("device credentials persist hash-only with private atomic storage and exact-origin renewal", async () => {
  const now = { value: 1_000 }, runtime = await setup(now);
  const created = await runtime.store.create("https://voice.example.test", "  Example\n phone  ");
  assert.match(created.credential, /^[A-Za-z0-9_-]{43}$/); assert.match(created.device.id, /^[A-Za-z0-9_-]{22}$/); assert.equal(created.device.name, "Example phone");
  assert.equal(created.device.idleExpiresAt, now.value + DEVICE_IDLE_TTL_MS); assert.equal(created.device.absoluteExpiresAt, now.value + DEVICE_ABSOLUTE_TTL_MS);
  const raw = await readFile(runtime.file, "utf8"); assert.doesNotMatch(raw, new RegExp(created.credential)); assert.match(raw, /"credentialHash":"[a-f0-9]{64}"/);
  assert.equal((await stat(runtime.file)).mode & 0o777, 0o600); assert.equal((await stat(join(runtime.dir, "private"))).mode & 0o777, 0o700);

  now.value += 10_000; const reopened = new DeviceAuthStore({ file: runtime.file, now: () => now.value }); await reopened.open();
  const renewed = await reopened.renew("https://voice.example.test", created.credential); assert.equal(renewed.ok, true); if (renewed.ok) assert.equal(renewed.device.lastUsedAt, now.value);
  const wrong = await reopened.renew("https://other.example.test", created.credential); assert.deepEqual(wrong, { ok: false, reason: "wrong_origin" });
});

test("idle, absolute expiry, revocation, and unknown credentials fail with typed reasons", async () => {
  const now = { value: 5_000 }, runtime = await setup(now), idle = await runtime.store.create("https://voice.example.test", "Idle");
  now.value += DEVICE_IDLE_TTL_MS; assert.deepEqual(await runtime.store.renew(idle.device.origin, idle.credential), { ok: false, reason: "expired_device" });

  now.value = 20_000; const absolute = await runtime.store.create("https://voice.example.test", "Absolute"), createdAt = now.value;
  for (const days of [89, 178, 267, 356]) { now.value = createdAt + days * 24 * 60 * 60_000; assert.equal((await runtime.store.renew(absolute.device.origin, absolute.credential)).ok, true); }
  now.value = createdAt + DEVICE_ABSOLUTE_TTL_MS - 1; assert.equal((await runtime.store.renew(absolute.device.origin, absolute.credential)).ok, true);
  now.value += 1; assert.deepEqual(await runtime.store.renew(absolute.device.origin, absolute.credential), { ok: false, reason: "expired_device" });

  now.value = 30_000; const revoked = await runtime.store.create("https://voice.example.test", "Revoked"); await runtime.store.revoke(revoked.device.id);
  assert.deepEqual(await runtime.store.renew(revoked.device.origin, revoked.credential), { ok: false, reason: "revoked_device" });
  assert.deepEqual(await runtime.store.renew(revoked.device.origin, "x".repeat(43)), { ok: false, reason: "invalid_device" });
});

test("concurrent device creation respects the active cap without silent eviction", async () => {
  const now = { value: 10_000 }, runtime = await setup(now);
  const results = await Promise.allSettled(Array.from({ length: MAX_ACTIVE_DEVICES + 4 }, (_, index) => runtime.store.create("https://voice.example.test", `Device ${index}`)));
  assert.equal(results.filter((result) => result.status === "fulfilled").length, MAX_ACTIVE_DEVICES);
  assert.equal(results.filter((result) => result.status === "rejected" && result.reason instanceof DeviceLimitError).length, 4);
  assert.equal(runtime.store.list().filter((item) => item.status === "active").length, MAX_ACTIVE_DEVICES);
  assert.equal((JSON.parse(await readFile(runtime.file, "utf8")) as any).devices.length, MAX_ACTIVE_DEVICES);
});

test("persistence failures roll back create, renewal, and revocation authorization state", async () => {
  const now = { value: 40_000 }, runtime = await setup(now), created = await runtime.store.create("https://voice.example.test", "Fault device"), before = runtime.store.current(created.device.id)!;
  const privateDir = join(runtime.dir, "private"), backupDir = join(runtime.dir, "backup"); await rename(privateDir, backupDir); await writeFile(privateDir, "blocks-directory-recreation");
  await assert.rejects(runtime.store.create(created.device.origin, "Not persisted")); assert.equal(runtime.store.list().length, 1);
  now.value += 5_000; await assert.rejects(runtime.store.renew(created.device.origin, created.credential)); assert.equal(runtime.store.current(created.device.id)!.lastUsedAt, before.lastUsedAt);
  await assert.rejects(runtime.store.revoke(created.device.id)); assert.equal(runtime.store.current(created.device.id)!.status, "active");
  const reopened = new DeviceAuthStore({ file: join(backupDir, "devices.json"), now: () => now.value }); await reopened.open();
  assert.equal(reopened.current(created.device.id)!.lastUsedAt, before.lastUsedAt); assert.equal(reopened.current(created.device.id)!.status, "active");
});

test("corrupt persistent device state fails closed at startup", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pi-voice-corrupt-")), file = join(dir, "devices.json"); await writeFile(file, "{not-json", { mode: 0o600 });
  await assert.rejects(new DeviceAuthStore({ file }).open(), /device_store_corrupt/);
});
