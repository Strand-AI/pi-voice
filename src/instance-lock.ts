import { chmod, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { randomBytes } from "node:crypto";

export type InstanceLock = { release(): Promise<void> };

function pidAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
}

/** Atomic process ownership acquired before registering the stable native endpoint. */
export async function acquireInstanceLock(path: string): Promise<InstanceLock> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 }); await chmod(dirname(path), 0o700);
  const token = randomBytes(18).toString("base64url");
  try {
      await mkdir(path, { mode: 0o700 });
      await writeFile(`${path}/owner.json`, `${JSON.stringify({ pid: process.pid, token, startedAt: Date.now() })}\n`, { mode: 0o600, flag: "wx" });
      return { release: async () => {
        try {
          const owner = JSON.parse(await readFile(`${path}/owner.json`, "utf8")) as { token?: unknown };
          if (owner.token === token) await rm(path, { recursive: true, force: true });
        } catch { /* replacement or already removed */ }
      } };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    let owner: { pid?: unknown };
    try { owner = JSON.parse(await readFile(`${path}/owner.json`, "utf8")) as { pid?: unknown }; }
    catch { throw new Error(`Companion instance lock exists but is unreadable: ${path}`); }
    if (typeof owner.pid !== "number" || !Number.isSafeInteger(owner.pid) || owner.pid <= 0) throw new Error(`Companion instance lock has an invalid owner: ${path}`);
    if (pidAlive(owner.pid)) throw new Error(`Pi Companion is already running as PID ${owner.pid}`);
    throw new Error(`Pi Companion lock belongs to exited PID ${owner.pid}; verify no gateway is running, then remove ${path}`);
  }
}
