import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { homedir, hostname, userInfo } from "node:os";
import { CompanionGateway } from "./gateway.ts";
import { PersistentNativeRelay } from "./native-relay.ts";
import { acquireInstanceLock } from "./instance-lock.ts";
import { loadOrCreateOwnerToken, readOwnerToken } from "./owner-auth.ts";

const runtimeDir = process.env.COMPANION_RUNTIME_DIR ?? resolve(homedir(), ".pi-companion");
const discoveryFile = resolve(runtimeDir, "bridge.json"), ownerTokenFile = resolve(runtimeDir, "owner-token");

const ownerCommand = process.argv.includes("--pair") ? "pair" : process.argv.includes("--devices") ? "devices" : process.argv.includes("--revoke") ? "revoke" : null;
if (ownerCommand) {
  const token = await readOwnerToken(ownerTokenFile), raw = JSON.parse(await readFile(discoveryFile, "utf8")) as unknown;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("gateway_discovery_invalid");
  const discovery = raw as Record<string, unknown>;
  if (typeof discovery.url !== "string" || typeof discovery.browserOrigin !== "string" || new URL(discovery.browserOrigin).origin !== discovery.browserOrigin) throw new Error("gateway_discovery_invalid");
  const local = new URL(discovery.url);
  if (local.protocol !== "http:" || !["localhost", "127.0.0.1"].includes(local.hostname) || local.pathname !== "/" || local.search || local.hash) throw new Error("gateway_discovery_invalid");
  const revokeIndex = process.argv.indexOf("--revoke"), deviceId = revokeIndex >= 0 ? process.argv[revokeIndex + 1] : undefined;
  if (ownerCommand === "revoke" && (typeof deviceId !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(deviceId))) throw new Error("invalid_device_id");
  const path = ownerCommand === "pair" ? "/api/browser-pairing" : ownerCommand === "devices" ? "/api/browser-devices" : "/api/browser-devices/revoke";
  const response = await fetch(new URL(path, local), {
    method: ownerCommand === "devices" ? "GET" : "POST", redirect: "error",
    headers: { origin: local.origin, authorization: `Bearer ${token}`, ...(ownerCommand === "revoke" ? { "content-type": "application/json" } : {}) },
    ...(ownerCommand === "revoke" ? { body: JSON.stringify({ deviceId }) } : {}),
  });
  const value = await response.json().catch(() => null) as Record<string, unknown> | null;
  if (!response.ok) throw new Error(`owner_command_failed:${typeof value?.error === "string" ? value.error : response.status}`);
  if (ownerCommand === "pair") {
    if (typeof value?.pairingToken !== "string" || !/^[A-Za-z0-9_-]{32}$/.test(value.pairingToken)) throw new Error("pairing_failed:invalid_response");
    console.log(`Gateway origin: ${discovery.browserOrigin}`);
    console.log(`Pairing code: ${value.pairingToken}`);
    console.log(`Setup page: ${discovery.browserOrigin}/#pair=${encodeURIComponent(value.pairingToken)}`);
  } else console.log(JSON.stringify(value, null, 2));
  process.exit(0);
}

const port = Number(process.env.COMPANION_PORT ?? "43120");
// Acquire process ownership before registering the roster observer or creating persistent owner authorization.
const instanceLock = await acquireInstanceLock(resolve(runtimeDir, "instance.lock"));
let ownerToken: string;
try { ownerToken = await loadOrCreateOwnerToken(ownerTokenFile); } catch (error) { await instanceLock.release(); throw error; }
const relay = new PersistentNativeRelay(process.cwd(), process.env.PI_INTERCOM_SCOPE_ID);
try { await relay.start(); } catch (error) { await instanceLock.release(); throw error; }
const gateway = new CompanionGateway({
  port,
  token: ownerToken,
  discoveryFile,
  deviceStoreFile: resolve(runtimeDir, "devices.json"),
  publicDir: resolve(import.meta.dirname, "../public"),
  ...(process.env.OPENAI_API_KEY ? { openAiKey: process.env.OPENAI_API_KEY } : {}),
  ...(process.env.COMPANION_PUBLIC_ORIGIN ? { publicOrigin: process.env.COMPANION_PUBLIC_ORIGIN } : {}),
  relayClient: relay,
});

try { await gateway.start(); } catch (error) { await relay.stop(); await instanceLock.release(); throw error; }
const sshHost = process.env.COMPANION_SSH_HOST ?? `${userInfo().username}@${hostname()}`;
console.log(`Pi Voice listening on 127.0.0.1:${gateway.port}`);
console.log(`Persistent local-owner authorization is private in ${ownerTokenFile}; its value is never printed or sent to clients.`);
console.log(`Native intercom roster observer is connected; a unique human endpoint exists only during an active voice session.`);
console.log("");
console.log("From the Air, forward the port (substitute the host if this name does not resolve there):");
console.log(`  ssh -N -L ${gateway.port}:127.0.0.1:${gateway.port} ${sshHost}`);
console.log("Native clients use the exact configured origin and a one-use code from `node dist/src/cli.js --pair`.");
console.log(`  ${process.env.COMPANION_PUBLIC_ORIGIN ?? gateway.localUrl}`);
console.log("");
console.log(process.env.OPENAI_API_KEY ? "Voice is enabled; starting it in a native client uses the microphone and paid API time." : "Voice is disabled: OPENAI_API_KEY is not set.");

const stop = async () => {
  await gateway.stop();
  await relay.stop();
  await instanceLock.release();
  process.exit(0);
};
process.once("SIGINT", () => void stop());
process.once("SIGTERM", () => void stop());
