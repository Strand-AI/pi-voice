import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { acquireInstanceLock } from "../src/instance-lock.ts";

test("instance lock prevents a second gateway owner before native registration", async () => {
  const dir = await mkdtemp(join(tmpdir(), "companion-lock-")), path = join(dir, "instance.lock");
  const first = await acquireInstanceLock(path);
  assert.equal((await stat(path)).mode & 0o777, 0o700);
  await assert.rejects(acquireInstanceLock(path), /already running/);
  await first.release();
  const replacement = await acquireInstanceLock(path);
  await replacement.release();
});
