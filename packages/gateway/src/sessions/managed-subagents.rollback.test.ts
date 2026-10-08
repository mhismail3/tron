import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { gunzipSync, gzipSync } from "node:zlib";
import { ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } from "./managed-subagents.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";

const gatewayRoot = fileURLToPath(new URL("../../", import.meta.url));
const leg = process.env.TRON_SUBAGENTS_ROLLBACK_LEG;
interface Completion { parentId: string; parentFile: string; childId: string; childFile: string; runId: string; processId?: string }

async function retainedFiles(root: string): Promise<Record<string, string>> {
  const result: Record<string, string> = {};
  async function visit(path: string): Promise<void> {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      const file = join(path, entry.name);
      if (entry.isDirectory()) await visit(file);
      else if (entry.isFile()) result[relative(root, file)] = createHash("sha256").update(await readFile(file)).digest("hex");
    }
  }
  await visit(root);
  return result;
}

// Each selection gets a fresh module/process lifetime, just as a payload restart
// does. Never mutate the repository pin or reuse a loaded extension across legs.
it("executes previous → candidate → previous and retains candidate history on rollback", async () => {
  if (leg) return runLeg();
  const retainedRoot = process.env.TRON_SUBAGENTS_ROLLBACK_ROOT;
  const root = retainedRoot ?? await mkdtemp(join(tmpdir(), "tron-subagents-rollback-"));
  const payloads = await mkdtemp(join(tmpdir(), "tron-subagents-payloads-"));
  const reportPath = process.env.TRON_SUBAGENTS_ROLLBACK_REPORT ?? join(gatewayRoot, "test-results", "managed-subagents.rollback.json");
  const report: { passed: boolean; legs: unknown[]; error?: string } = { passed: false, legs: [] };
  try {
    if (retainedRoot) await mkdir(root); // Refuse to overwrite a prior retained fixture.
    await Promise.all([mkdir(join(root, "agent")), mkdir(join(root, "workspace")), mkdir(join(root, "npm-cache")), mkdir(join(root, "home")), mkdir(join(root, "tmp"))]);
    const pin = JSON.parse(await readFile(join(gatewayRoot, "pi-subagents-pin.json"), "utf8"));
    for (const name of ["previous", "candidate", "rollback"]) {
      const payload = join(payloads, name);
      await copyPayload(payload);
      const selection = name === "candidate" ? pin : { ...pin, version: pin.previous.version, closure: pin.previous.closure, fork: { commit: null } };
      await writeFile(join(payload, "pi-subagents-pin.json"), JSON.stringify(selection));
      let before: Record<string, string> | undefined;
      let parentBefore: Buffer | undefined;
      let childBefore: Buffer | undefined;
      let candidate: { completion: Completion } | undefined;
      if (name === "rollback") {
        before = await retainedFiles(join(root, "agent", "sessions"));
        candidate = JSON.parse(await readFile(join(root, "candidate.json"), "utf8"));
        parentBefore = await readFile(join(root, candidate!.completion.parentFile));
        childBefore = await readFile(join(root, candidate!.completion.childFile));
      }
      const output = await promisify(execFile)(process.execPath, [join(gatewayRoot, "node_modules", "vitest", "vitest.mjs"), "run", "src/sessions/managed-subagents.rollback.test.ts", "--maxWorkers=2"], {
        cwd: payload, timeout: 30_000, maxBuffer: 1024 * 1024,
        env: { PATH: process.env.PATH!, HOME: join(root, "home"), TMPDIR: join(root, "tmp"), PI_SKIP_VERSION_CHECK: "1",
          TRON_SUBAGENTS_ROLLBACK_LEG: name, TRON_SUBAGENTS_ROLLBACK_FIXTURE: root },
      }).catch(async (error: Error & { stdout?: string; stderr?: string }) => {
        await writeFile(join(root, `${name}.log`), (error.stdout ?? "") + (error.stderr ?? ""));
        const failed = JSON.parse(await readFile(join(root, `${name}.json`), "utf8"));
        report.legs.push(failed);
        throw new Error(`${name} leg failed: ${failed.error ?? error.message}`);
      });
      await writeFile(join(root, `${name}.log`), output.stdout + output.stderr);
      report.legs.push(JSON.parse(await readFile(join(root, `${name}.json`), "utf8")));
      if (before) {
        const after = await retainedFiles(join(root, "agent", "sessions"));
        const parentPath = join(root, candidate!.completion.parentFile);
        for (const [file, digest] of Object.entries(before)) {
          const path = join(root, "agent", "sessions", file);
          if (path !== parentPath && path !== join(root, candidate!.completion.childFile)) expect(after[file], `retained run artifact bytes: ${file}`).toBe(digest);
        }
        expect((await readFile(parentPath)).subarray(0, parentBefore!.length).equals(parentBefore!)).toBe(true);
        expect((await readFile(join(root, candidate!.completion.childFile))).subarray(0, childBefore!.length).equals(childBefore!)).toBe(true);
        report.legs.push({ retainedArtifactCount: Object.keys(before).length - 2, candidateParentPrefixBytes: parentBefore!.length,
          candidateChildPrefixBytes: childBefore!.length, preserved: true });
      }
    }
    for (const selection of [pin, pin.previous]) {
      const receipt = JSON.parse(await readFile(join(root, "tron", "internal", "pi-subagents", selection.version, "tron-install-receipt.json"), "utf8"));
      expect(receipt).toMatchObject({ version: selection.version, sha512: selection.closure.sha512 });
    }
    expect((await readdir(join(root, "tron", "internal", "pi-subagents"))).sort()).toEqual([pin.previous.version, pin.version].sort());
    report.passed = true;
  } catch (error) {
    report.error = error instanceof Error ? error.message : String(error);
    throw error;
  } finally {
    await rm(payloads, { recursive: true, force: true });
    if (!retainedRoot) await rm(root, { recursive: true, force: true });
    await mkdir(dirname(reportPath), { recursive: true });
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  }
}, 100_000);

async function copyPayload(payload: string): Promise<void> {
  await mkdir(payload);
  for (const file of ["src", "test-support", "vitest.config.ts", "package.json"]) {
    await cp(join(gatewayRoot, file), join(payload, file), { recursive: true });
  }
  await symlink(join(gatewayRoot, "node_modules"), join(payload, "node_modules"));
  await symlink(join(gatewayRoot, "artifacts"), join(payload, "artifacts"));
}

// Valid closure bytes with an invalid manifest entry exercise the installer and
// both admission paths. Installed-file tampering would only test digest refusal.
it.skipIf(Boolean(leg)).each([
  { entries: ["../outside.js"], reason: "extension entry escapes the verified root" },
  { entries: ["./missing.js"], reason: "extension entry is missing or not a regular file inside the verified root" },
  { entries: [], reason: "extension entries are absent or invalid" },
])("refuses verified builds with invalid extension entries: $entries", async ({ entries, reason }) => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagents-invalid-entry-"));
  try {
    const payload = join(root, "payload");
    await copyPayload(payload);
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
    await promisify(execFile)(process.execPath, [join(gatewayRoot, "node_modules", "vitest", "vitest.mjs"), "run", "src/sessions/managed-subagents.rollback.test.ts", "--maxWorkers=2"], {
      cwd: payload, timeout: 15_000, maxBuffer: 1024 * 1024,
      env: { PATH: process.env.PATH!, HOME: join(root, "home"), TMPDIR: join(root, "tmp"),
        TRON_SUBAGENTS_ROLLBACK_LEG: "invalid", TRON_SUBAGENTS_ROLLBACK_FIXTURE: root, TRON_SUBAGENTS_ROLLBACK_REJECTION: reason },
    });
  } finally { await rm(root, { recursive: true, force: true }); }
}, 20_000);

async function runLeg(): Promise<void> {
  const root = await realpath(process.env.TRON_SUBAGENTS_ROLLBACK_FIXTURE!);
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  const tronHome = join(root, "tron");
  const overrides = { PI_CODING_AGENT_DIR: agentDir, npm_config_cache: join(root, "npm-cache"), npm_config_offline: "true", npm_config_registry: "http://registry.invalid" };
  const previous = Object.fromEntries(Object.keys(overrides).map((name) => [name, process.env[name]]));
  let registry: RuntimeRegistry | undefined;
  let server: Server | undefined;
  const responses: Array<string | { id: string; args: Record<string, unknown> }> = [];
  let requests = 0;
  const facts: Record<string, unknown> = { leg, passed: false };
  try {
    Object.assign(process.env, overrides);
    const managedSubagents = new ManagedSubagents(tronHome);
    const installedRoot = managedSubagents.install();
    const pin = JSON.parse(await readFile(join(gatewayRoot, "pi-subagents-pin.json"), "utf8"));
    const receipt = JSON.parse(await readFile(join(installedRoot, "tron-install-receipt.json"), "utf8"));
    expect(receipt).toMatchObject({ version: pin.version, sha512: pin.closure.sha512, forkCommit: pin.fork.commit });
    expect(installedRoot).toBe(join(await realpath(tronHome), "internal", "pi-subagents", pin.version));
    facts.receipt = receipt;
    if (process.env.TRON_SUBAGENTS_ROLLBACK_REJECTION) {
      const reason = process.env.TRON_SUBAGENTS_ROLLBACK_REJECTION;
      const settings = SettingsManager.create(cwd, agentDir, { projectTrusted: false });
      expect(() => managedSubagents.loaderOptions(settings, agentDir)).toThrow(reason);
      expect(() => managedSubagents.admit([])).toThrow(reason);
      facts.passed = true;
      return;
    }
    const model = { provider: "tron-rollback-subagents", id: "rollback-model" };
    server = createServer((request, response) => {
      request.resume();
      const scripted = responses.shift();
      if (++requests > 16 || scripted === undefined || request.url !== "/v1/chat/completions") {
        response.writeHead(500).end("Unexpected model request");
        return;
      }
      response.writeHead(200, { "content-type": "text/event-stream" });
      const delta = typeof scripted === "string" ? { content: scripted } : {
        tool_calls: [{ index: 0, id: scripted.id, type: "function", function: { name: "subagent", arguments: JSON.stringify(scripted.args) } }],
      };
      for (const [value, finish] of [[{ role: "assistant", ...delta }, null], [{}, typeof scripted === "string" ? "stop" : "tool_calls"]]) {
        response.write(`data: ${JSON.stringify({ id: `probe-${requests}`, object: "chat.completion.chunk", created: 1, model: model.id,
          choices: [{ index: 0, delta: value, finish_reason: finish }] })}\n\n`);
      }
      response.end("data: [DONE]\n\n");
    });
    server.requestTimeout = 5_000;
    await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;
    await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { [model.provider]: {
      baseUrl: `http://127.0.0.1:${port}/v1`, api: "openai-completions", apiKey: "fixture-only-not-a-credential",
      models: [{ id: model.id, name: "Rollback fixture", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    } } }));
    await mkdir(join(cwd, ".pi", "agents"), { recursive: true });
    await writeFile(join(cwd, ".pi", "agents", "rollback-worker.md"), `---\nname: rollback-worker\ndescription: Read-only rollback probe\nmodel: ${model.provider}/${model.id}\ntools: read\n---\nReturn the requested probe marker.\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    registry = new RuntimeRegistry({
      agentDir, tronHome, managedSubagents, trust, idleRuntimeMs: 60_000,
      modelRuntimeFactory: () => ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false }),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    await registry.initialize();
    if (leg === "rollback") {
      const candidate = JSON.parse(await readFile(join(root, "candidate.json"), "utf8")) as { completion: Completion };
      const old = await waitFor(async () => {
        try { return await registry!.acquire(candidate.completion.parentId); }
        catch (error) { if ((error as { code?: string }).code === "busy") return false; throw error; }
      }, "rollback catalog reconstruction");
      const session = SessionManager.open(old.sessionFile!);
      expect(session.getEntries().some((entry) => entry.type === "message" && entry.message.role === "toolResult"
        && entry.message.toolCallId === "candidate-launch" && !entry.message.isError)).toBe(true);
      const child = SessionManager.open(join(root, candidate.completion.childFile));
      expect(child.getSessionId()).toBe(candidate.completion.childId);
      expect(candidate.completion.processId).toBeDefined();
      await expect(old.abortSubagentProcess(candidate.completion.processId!, candidate.completion.runId)).rejects.toMatchObject({ code: "conflict" });
      facts.candidateHistory = { parentId: session.getSessionId(), childId: child.getSessionId(), terminalControlRefused: true,
        activities: old.snapshot().processActivities };
      // Producer-owned status is exercised through the real tool, not inferred
      // from a surviving directory. No resume is assumed for non-resumable runs.
      responses.push({ id: "rollback-status", args: { action: "status", id: candidate.completion.runId } }, "ROLLBACK_STATUS_READ");
      await old.prompt("Inspect the retained candidate run without changing it");
      await waitFor(() => !old.isBusy, "rollback candidate status");
      const result = SessionManager.open(old.sessionFile!).getEntries().find((entry) => entry.type === "message"
        && entry.message.role === "toolResult" && entry.message.toolCallId === "rollback-status");
      expect(result).toMatchObject({ message: { isError: false } });
      if (!result || result.type !== "message" || result.message.role !== "toolResult") throw new Error("Missing retained candidate status");
      const text = result.message.content.filter((block) => block.type === "text").map((block) => block.text).join("\n");
      expect(text).toContain(candidate.completion.runId);
      expect(text).toContain("CHILD_CANDIDATE_COMPLETE");
      facts.candidateStatus = { isError: result.message.isError, runId: candidate.completion.runId, retainedOutput: "CHILD_CANDIDATE_COMPLETE" };
    }
    const slot = await registry.create(cwd);
    await slot.setModel(model.provider, model.id);
    const resources = await slot.resources() as unknown as { subagents: Array<{ name: string }>; tools: Array<{ name: string }>; subagentDiagnostics?: string };
    expect(resources.subagentDiagnostics).toBeUndefined();
    expect(resources.subagents.some((agent) => agent.name === "researcher")).toBe(true);
    expect(resources.subagents.some((agent) => agent.name === "rollback-worker")).toBe(true);
    expect(resources.tools.some((tool) => tool.name === "subagent")).toBe(true);
    const marker = `CHILD_${leg!.toUpperCase()}_COMPLETE`;
    responses.push({ id: `${leg}-launch`, args: { agent: "rollback-worker", task: `Return ${marker}`, async: false,
      acceptance: { level: "none", reason: "Read-only rollback probe" } } }, marker, "PARENT_COMPLETE");
    await slot.prompt("Launch rollback-worker and report completion");
    await waitFor(() => !slot.isBusy, `${leg} real child completion`);
    const session = SessionManager.open(slot.sessionFile!);
    const launch = session.getEntries().find((entry) => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === `${leg}-launch`);
    facts.launch = launch && launch.type === "message" && launch.message.role === "toolResult"
      ? { toolCallId: launch.message.toolCallId, toolName: launch.message.toolName, isError: launch.message.isError } : null;
    expect(launch).toMatchObject({ message: { toolName: "subagent", isError: false } });
    if (!launch || launch.type !== "message" || launch.message.role !== "toolResult") throw new Error("Missing canonical launch");
    const details = launch.message.details as { runId: string; results: Array<{ exitCode: number; finalOutput: string; sessionFile: string }> };
    expect(details.results).toHaveLength(1);
    const result = details.results[0]!;
    expect(result).toMatchObject({ exitCode: 0, finalOutput: marker });
    expect(relative(agentDir, result.sessionFile).startsWith("..")).toBe(false);
    const child = SessionManager.open(result.sessionFile);
    expect(child.getEntries().some((entry) => entry.type === "message" && entry.message.role === "assistant"
      && entry.message.content.some((block) => block.type === "text" && block.text === marker))).toBe(true);
    const activity = slot.snapshot().processActivities?.find((row) => row.toolCallId === `${leg}-launch`);
    facts.completion = { parentId: session.getSessionId(), parentFile: relative(root, slot.sessionFile!), childId: child.getSessionId(), childFile: relative(root, result.sessionFile), runId: details.runId, processId: activity?.processId };
    const ownerReceipt = session.getEntries().find((entry) => entry.type === "custom" && entry.customType === "tron.extension-activity.v1");
    expect(ownerReceipt).toMatchObject({ data: { runId: details.runId, state: "completed", owner: { source: MANAGED_SUBAGENTS_SOURCE } } });
    facts.ownerSource = (ownerReceipt as { data: { owner: { source: string } } }).data.owner.source;
    if (leg === "rollback") {
      const candidate = JSON.parse(await readFile(join(root, "candidate.json"), "utf8")) as { completion: Completion };
      const old = await registry.acquire(candidate.completion.parentId);
      responses.push({ id: "rollback-resume", args: { async: false,
        workflowScript: `return runs.run("rollback-resume", { resume: ${JSON.stringify(candidate.completion.runId)}, task: "Return CHILD_ROLLBACK_RESUMED" })`,
      } }, "CHILD_ROLLBACK_RESUMED", "PARENT_RESUME_COMPLETE");
      await old.prompt("Resume the retained candidate child through the selected previous provider");
      await waitFor(() => !old.isBusy, "rollback candidate resume");
      const resumed = SessionManager.open(old.sessionFile!).getEntries().find((entry) => entry.type === "message"
        && entry.message.role === "toolResult" && entry.message.toolCallId === "rollback-resume");
      expect(resumed).toMatchObject({ message: { isError: false } });
      if (!resumed || resumed.type !== "message" || resumed.message.role !== "toolResult") throw new Error("Missing canonical rollback resume");
      expect(resumed.message.content.some((block) => block.type === "text" && block.text.includes("CHILD_ROLLBACK_RESUMED"))).toBe(true);
      const detail = resumed.message.details as { runId: string; results: Array<{ sessionFile: string; exitCode: number; finalOutput: string }> };
      expect(detail.results).toHaveLength(1);
      expect(detail.results[0]).toMatchObject({ sessionFile: join(root, candidate.completion.childFile), exitCode: 0, finalOutput: "CHILD_ROLLBACK_RESUMED" });
      const child = SessionManager.open(join(root, candidate.completion.childFile));
      expect(child.getSessionId()).toBe(candidate.completion.childId);
      expect(child.getEntries().some((entry) => entry.type === "message" && entry.message.role === "assistant"
        && entry.message.content.some((block) => block.type === "text" && block.text === "CHILD_ROLLBACK_RESUMED"))).toBe(true);
      facts.candidateResume = { runId: detail.runId, childId: child.getSessionId(), exitCode: detail.results[0]!.exitCode,
        output: detail.results[0]!.finalOutput, canonicalChildRetained: true };
    }
    expect(responses).toEqual([]);
    facts.passed = true;
  } catch (error) {
    facts.error = error instanceof Error ? error.message : String(error);
    throw error;
  } finally {
    try { await registry?.dispose(); }
    finally {
      server?.closeAllConnections();
      if (server) await new Promise<void>((resolve, reject) => server!.close((error) => error ? reject(error) : resolve()));
      for (const [name, value] of Object.entries(previous)) {
        if (value === undefined) delete process.env[name]; else process.env[name] = value;
      }
      facts.modelRequests = requests;
      await writeFile(join(root, `${leg}.json`), `${JSON.stringify(facts, null, 2)}\n`);
    }
  }
}
