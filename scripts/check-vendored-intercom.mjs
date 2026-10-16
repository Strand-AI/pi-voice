import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const relativeArchive = "vendor/pi-intercom/pi-intercom-0.17.3.tgz";
const archivePath = path.join(root, relativeArchive);
const expectedSha256 = "ffe3d8921aea5edccb80e48285d1f713042ec80c7141e6e7b330055630555616";
const expectedIntegrity = "sha512-IZHpKNG7YoI3ufYDGwzcHy7Gup4mTQr/wmkRgvNbG4UWHBC29fsnJC+tqxhzg96RvcQ5MnTRU3Z7XsZD2mH/ig==";
const spec = `file:${relativeArchive}`;
const manifest = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
const lock = JSON.parse(readFileSync(path.join(root, "package-lock.json"), "utf8"));

assert.equal(manifest.dependencies["pi-intercom"], spec);
assert.equal(lock.packages[""].dependencies["pi-intercom"], spec);
assert.equal(lock.packages["node_modules/pi-intercom"].resolved, spec);
assert.equal(lock.packages["node_modules/pi-intercom"].integrity, expectedIntegrity);

const archive = readFileSync(archivePath);
assert.equal(createHash("sha256").update(archive).digest("hex"), expectedSha256);
assert.equal(`sha512-${createHash("sha512").update(archive).digest("base64")}`, expectedIntegrity);
for (const required of ["package/LICENSE", "package/package.json", "package/dist/client.js", "package/dist/client.d.ts", "package/dist/types.js", "package/dist/types.d.ts"]) {
  const result = spawnSync("tar", ["-tzf", archivePath, required], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr || `missing ${required}`);
}
const packageManifest = JSON.parse(spawnSync("tar", ["-xOf", archivePath, "package/package.json"], { encoding: "utf8" }).stdout);
for (const name of ["@earendil-works/pi-ai", "@earendil-works/pi-coding-agent", "@earendil-works/pi-tui", "typebox"]) {
  assert.equal(packageManifest.peerDependencies[name], "*");
  assert.equal(packageManifest.peerDependenciesMeta[name]?.optional, true);
}
console.log(`verified vendored pi-intercom ${expectedSha256}`);
