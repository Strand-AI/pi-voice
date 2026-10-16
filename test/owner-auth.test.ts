import assert from "node:assert/strict";
import test from "node:test";
import { chmod, mkdtemp, readFile, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { CompanionGateway } from "../src/gateway.ts";
import { loadOrCreateOwnerToken, readOwnerToken } from "../src/owner-auth.ts";

const execFileAsync = promisify(execFile);

test("local-owner authorization is persistent, private, and never rotates after initial creation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pi-voice-owner-")), file = join(dir, "private", "owner-token");
  const first = await loadOrCreateOwnerToken(file); assert.match(first, /^[A-Za-z0-9_-]{43}$/);
  assert.equal((await stat(join(dir, "private"))).mode & 0o777, 0o700); assert.equal((await stat(file)).mode & 0o777, 0o600);
  await chmod(file, 0o644); const second = await loadOrCreateOwnerToken(file); assert.equal(second, first); assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.equal(await readFile(file, "utf8"), `${first}\n`);
});

test("missing reads and corrupt or symlinked owner authorization fail closed without regeneration", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pi-voice-owner-bad-")), missing = join(dir, "missing"), corrupt = join(dir, "corrupt"), target = join(dir, "target"), linked = join(dir, "linked");
  await assert.rejects(readOwnerToken(missing), /owner_auth_missing/);
  await writeFile(corrupt, "not-a-token\n", { mode: 0o600 }); await assert.rejects(loadOrCreateOwnerToken(corrupt), /owner_auth_corrupt/); assert.equal(await readFile(corrupt, "utf8"), "not-a-token\n");
  await writeFile(target, `${"a".repeat(43)}\n`, { mode: 0o600 }); await symlink(target, linked); await assert.rejects(loadOrCreateOwnerToken(linked), /owner_auth_corrupt/); assert.equal(await readFile(target, "utf8"), `${"a".repeat(43)}\n`);
});

test("owner CLI mints native pairing details without exposing the root credential", async () => {
  const runtimeDir = await mkdtemp(join(tmpdir(), "pi-voice-owner-cli-")), ownerFile = join(runtimeDir, "owner-token"), token = await loadOrCreateOwnerToken(ownerFile);
  const gateway = new CompanionGateway({ port: 0, token, discoveryFile: join(runtimeDir, "bridge.json"), deviceStoreFile: join(runtimeDir, "devices.json"), publicDir: resolve(process.env.PI_VOICE_TEST_PUBLIC_DIR ?? "dist/public") });
  await gateway.start();
  try {
    const { stdout, stderr } = await execFileAsync(process.execPath, [resolve(process.env.PI_VOICE_TEST_OUT_DIR ?? ".test-dist", "src/cli.js"), "--pair"], { env: { ...process.env, COMPANION_RUNTIME_DIR: runtimeDir } });
    assert.equal(stderr, ""); assert.doesNotMatch(stdout, new RegExp(token));
    const lines = stdout.trim().split("\n"), expectedOrigin = `http://localhost:${gateway.port}`;
    assert.equal(lines[0], `Gateway origin: ${expectedOrigin}`);
    assert.match(lines[1] ?? "", /^Pairing code: [A-Za-z0-9_-]{32}$/);
    assert.match(lines[2] ?? "", new RegExp(`^Setup page: http://localhost:${gateway.port}/#pair=[A-Za-z0-9_-]{32}$`));
    const pairingToken = lines[1]?.slice("Pairing code: ".length);
    const redeemed = await fetch(`${expectedOrigin}/api/browser-session/pair`, { method: "POST", headers: { origin: expectedOrigin, "content-type": "application/json" }, body: JSON.stringify({ pairingToken, deviceName: "CLI native client" }) }); assert.equal(redeemed.status, 201);
  } finally { await gateway.stop(); }
});

test("CLI and native-pairing page contain no root bearer URL or logging path", async () => {
  const [cli, pairing] = await Promise.all([readFile("src/cli.ts", "utf8"), readFile("public/pairing.ts", "utf8")]);
  assert.doesNotMatch(cli, /#token|browserUrl|console\.log\([^\n]*\$\{ownerToken\}/);
  assert.doesNotMatch(pairing, /fragment\.get\("token"\)|companion-auth|fetch\(/);
  assert.match(cli, /--pair/); assert.match(cli, /readOwnerToken\(ownerTokenFile\)/); assert.match(cli, /token: ownerToken/);
});
