import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { gunzipSync, gzipSync } from "node:zlib";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { GatewayError } from "../errors.js";
import { copyPayload, refuseUnjoinedFixture, retainedFiles } from "../../test-support/nested-vitest-payload.js";
import { ManagedSubagents } from "./managed-subagents.js";
import { delegatedProviderEnvironment } from "./delegated-provider.js";

const gatewayRoot = fileURLToPath(new URL("../../", import.meta.url));
const ownTestFile = "managed-subagents.invalid-entry.integration.test.ts";
const leg = process.env.TRON_SUBAGENTS_INVALID_ENTRY_FIXTURE;

// Valid closure bytes with an invalid manifest entry exercise the installer and
// both admission paths. Installed-file tampering would only test digest refusal.
// Each case runs this file in a nested vitest so the pinned closure is its own
// payload; the nested leg imports only the managed-subagents module it refuses.
it.skipIf(Boolean(leg)).each([
  { entries: ["../outside.js"] },
  { entries: ["./missing.js"] },
  { entries: [] },
])("refuses verified builds with invalid extension entries: $entries", async ({ entries }) => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagents-invalid-entry-"));
  try {
    const payload = join(root, "payload");
    await copyPayload(payload, ownTestFile);
    const pin = JSON.parse(await readFile(join(gatewayRoot, "pi-subagents-pin.json"), "utf8"));
    const tar = gunzipSync(await readFile(join(gatewayRoot, pin.closure.path)));
    const blocks: Buffer[] = [];
    for (let offset = 0; offset + 512 <= tar.length;) {
      const header = Buffer.from(tar.subarray(offset, offset + 512));
      if (header.every((byte) => byte === 0)) break;
      const size = parseInt(header.subarray(124, 136).toString().replace(/\0.*$/su, "").trim() || "0", 8);
      const name = header.subarray(0, 100).toString().replace(/\0.*$/su, "");
      let bytes = tar.subarray(offset + 512, offset + 512 + size);
      if (name === "package/package.json") {
        const manifest = JSON.parse(bytes.toString());
        manifest.pi.extensions = entries;
        bytes = Buffer.from(JSON.stringify(manifest));
        header.write(`${bytes.length.toString(8).padStart(11, "0")}\0`, 124, 12);
        header.fill(32, 148, 156);
        header.write(`${header.reduce((sum, byte) => sum + byte, 0).toString(8).padStart(6, "0")}\0 `, 148, 8);
      }
      blocks.push(header, bytes, Buffer.alloc((512 - bytes.length % 512) % 512));
      offset += 512 + Math.ceil(size / 512) * 512;
    }
    const archive = gzipSync(Buffer.concat([...blocks, Buffer.alloc(1024)]));
    await writeFile(join(payload, "invalid-closure.tgz"), archive);
    pin.closure = { path: "invalid-closure.tgz", sha512: createHash("sha512").update(archive).digest("hex") };
    await writeFile(join(payload, "pi-subagents-pin.json"), JSON.stringify(pin));
    for (const directory of ["agent", "workspace", "home", "tmp"]) await mkdir(join(root, directory));
    await promisify(execFile)(process.execPath, [join(gatewayRoot, "node_modules", "vitest", "vitest.mjs"), "run", "--config", "vitest.nested.config.ts", `src/sessions/${ownTestFile}`], {
      // Hang guard only: this file runs alone in the nested pass (vitest.nested.config.ts);
      // a passing cold child takes about 3-14 s, so a reached bound means a hung child.
      cwd: payload, timeout: 120_000, maxBuffer: 1024 * 1024,
      env: { PATH: process.env.PATH!, HOME: join(root, "home"), TMPDIR: join(root, "tmp"),
        TRON_SUBAGENTS_INVALID_ENTRY_FIXTURE: root,
        TRON_TEST_PROCESS_OWNER: root,
        TRON_TEST_PROCESS_OWNER_FAILURE: process.env.TRON_TEST_PROCESS_OWNER_FAILURE ?? join(root, "process-owner-failure.jsonl"),
        NODE_OPTIONS: `--import=${join(payload, "test-support", "fixture-process-owner.mjs")}` },
    });
  } finally {
    await refuseUnjoinedFixture(root);
    await rm(root, { recursive: true, force: true });
  }
}, 150_000);

// Runs in the nested child only: the staged payload's pin selects the invalid closure.
it.skipIf(!leg)("refuses the staged invalid extension entry", async () => {
  const root = await realpath(process.env.TRON_SUBAGENTS_INVALID_ENTRY_FIXTURE!);
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  const tronHome = join(root, "tron");
  const overrides = { PI_CODING_AGENT_DIR: agentDir, PI_SUBAGENTS_TEMP_ROOT: join(tronHome, "internal", "subagents"),
    PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT: join(root, "unavailable-inherited-host"),
    npm_config_cache: join(root, "npm-cache"), npm_config_offline: "true", npm_config_registry: "http://registry.invalid" };
  Object.assign(process.env, overrides);
  // Match Gateway startup: bind this process's delegated artifact root before the
  // managed loader reads any extension entry.
  delegatedProviderEnvironment(overrides.PI_SUBAGENTS_TEMP_ROOT);
  const managedSubagents = new ManagedSubagents(tronHome);
  const installedRoot = managedSubagents.install();
  const pin = JSON.parse(await readFile(join(gatewayRoot, "pi-subagents-pin.json"), "utf8"));
  const receipt = JSON.parse(await readFile(join(installedRoot, "tron-install-receipt.json"), "utf8"));
  expect(receipt).toMatchObject({ version: pin.version, sha512: pin.closure.sha512, forkCommit: pin.fork.commit });
  const settings = SettingsManager.create(cwd, agentDir, { projectTrusted: false });
  const before = await retainedFiles(installedRoot);
  await expect(managedSubagents.loaderOptions(settings)).rejects.toMatchObject({ code: "conflict" });
  expect(() => managedSubagents.admit([])).toThrow(GatewayError);
  expect(await retainedFiles(installedRoot)).toEqual(before);
});
