import { randomBytes } from "node:crypto";
import { chmod, lstat, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

const OWNER_TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

async function privateParent(file: string): Promise<void> {
  const dir = dirname(file); await mkdir(dir, { recursive: true, mode: 0o700 }); await chmod(dir, 0o700);
  const info = await stat(dir); if (!info.isDirectory() || (info.mode & 0o777) !== 0o700) throw new Error("owner_auth_permissions");
}

export async function readOwnerToken(file: string): Promise<string> {
  let info;
  try { info = await lstat(file); } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") throw new Error("owner_auth_missing"); throw error; }
  if (!info.isFile() || info.isSymbolicLink()) throw new Error("owner_auth_corrupt");
  const raw = await readFile(file, "utf8"), token = raw.endsWith("\n") ? raw.slice(0, -1) : raw;
  if (!OWNER_TOKEN_RE.test(token) || raw !== `${token}\n`) throw new Error("owner_auth_corrupt");
  await chmod(file, 0o600); const secured = await stat(file); if ((secured.mode & 0o777) !== 0o600) throw new Error("owner_auth_permissions");
  return token;
}

export async function loadOrCreateOwnerToken(file: string): Promise<string> {
  await privateParent(file);
  try { return await readOwnerToken(file); }
  catch (error) {
    if (!(error instanceof Error) || error.message !== "owner_auth_missing") throw error;
    const token = randomBytes(32).toString("base64url");
    try { await writeFile(file, `${token}\n`, { mode: 0o600, flag: "wx" }); }
    catch (writeError) { if ((writeError as NodeJS.ErrnoException).code === "EEXIST") return await readOwnerToken(file); throw writeError; }
    return await readOwnerToken(file);
  }
}
