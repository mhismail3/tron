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
import { GatewayError } from "../errors.js";
import { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } from "./managed-subagents.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { delegatedProviderEnvironment } from "./delegated-provider.js";
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
it("executes previous → candidate → previous with detached resume through the selected Gateway host", async () => {
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
      const selection = name === "candidate" ? pin : pin.previous.fork ? pin.previous
        : { ...pin, version: pin.previous.version, closure: pin.previous.closure, fork: { commit: null } };
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
          TRON_SUBAGENTS_ROLLBACK_LEG: name, TRON_SUBAGENTS_ROLLBACK_FIXTURE: root,
          TRON_TEST_PROCESS_OWNER: root,
          TRON_TEST_PROCESS_OWNER_FAILURE: process.env.TRON_TEST_PROCESS_OWNER_FAILURE ?? join(root, "process-owner-failure.jsonl"),
          NODE_OPTIONS: `--import=${join(payload, "test-support", "fixture-process-owner.mjs")}` },
      }).catch(async (error: Error & { stdout?: string; stderr?: string }) => {
        await writeFile(join(root, `${name}.log`), (error.stdout ?? "") + (error.stderr ?? ""));
        const failed = JSON.parse(await readFile(join(root, `${name}.json`), "utf8"));
        report.legs.push(failed);
        throw new Error(`${name} leg failed: ${JSON.stringify(failed)}`);
      });
      await writeFile(join(root, `${name}.log`), output.stdout + output.stderr);
      const completed = JSON.parse(await readFile(join(root, `${name}.json`), "utf8"));
      const retainedSelection = name === "candidate" ? pin : pin.previous;
      expect(completed.receipt).toEqual({ version: retainedSelection.version, sha512: retainedSelection.closure.sha512,
        forkCommit: retainedSelection.fork?.commit ?? null });
      report.legs.push(completed);
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
      expect(receipt).toEqual({ version: selection.version, sha512: selection.closure.sha512, forkCommit: selection.fork?.commit ?? null });
    }
    expect((await readdir(join(root, "tron", "internal", "pi-subagents"))).sort()).toEqual([pin.previous.version, pin.version].sort());
    report.passed = true;
  } catch (error) {
    report.error = error instanceof Error ? error.message : String(error);
    throw error;
  } finally {
    await mkdir(dirname(reportPath), { recursive: true });
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    await refuseUnjoinedFixture(root);
    await rm(payloads, { recursive: true, force: true });
    if (!retainedRoot) await rm(root, { recursive: true, force: true });
  }
}, 100_000);

async function refuseUnjoinedFixture(root: string): Promise<void> {
  let failure: string;
  try { failure = await readFile(process.env.TRON_TEST_PROCESS_OWNER_FAILURE ?? join(root, "process-owner-failure.jsonl"), "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
  throw new Error(`Refusing fixture removal after process join failure: ${failure}`);
}

async function copyPayload(payload: string): Promise<void> {
  await mkdir(payload);
  // A nested leg runs only this file. Copying the other test files was over half
  // of each leg's cost under host load; the source modules it imports are all kept.
  const ownTestFile = "managed-subagents.rollback.test.ts";
  await cp(join(gatewayRoot, "src"), join(payload, "src"), {
    recursive: true,
    filter: (source) => !source.endsWith(".test.ts") || source.endsWith(ownTestFile),
  });
  for (const file of ["test-support", "vitest.config.ts", "package.json"]) {
    await cp(join(gatewayRoot, file), join(payload, file), { recursive: true });
  }
  await symlink(join(gatewayRoot, "node_modules"), join(payload, "node_modules"));
  await symlink(join(gatewayRoot, "artifacts"), join(payload, "artifacts"));
}

// Valid closure bytes with an invalid manifest entry exercise the installer and
// both admission paths. Installed-file tampering would only test digest refusal.
it.skipIf(Boolean(leg)).each([
  { entries: ["../outside.js"] },
  { entries: ["./missing.js"] },
  { entries: [] },
])("refuses verified builds with invalid extension entries: $entries", async ({ entries }) => {
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
        TRON_SUBAGENTS_ROLLBACK_LEG: "invalid", TRON_SUBAGENTS_ROLLBACK_FIXTURE: root, TRON_SUBAGENTS_ROLLBACK_INVALID_ENTRY: "1",
        TRON_TEST_PROCESS_OWNER: root,
        TRON_TEST_PROCESS_OWNER_FAILURE: process.env.TRON_TEST_PROCESS_OWNER_FAILURE ?? join(root, "process-owner-failure.jsonl"),
        NODE_OPTIONS: `--import=${join(payload, "test-support", "fixture-process-owner.mjs")}` },
    });
  } finally {
    await refuseUnjoinedFixture(root);
    await rm(root, { recursive: true, force: true });
  }
}, 20_000);

async function runLeg(): Promise<void> {
  const root = await realpath(process.env.TRON_SUBAGENTS_ROLLBACK_FIXTURE!);
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  const tronHome = join(root, "tron");
  const overrides = { PI_CODING_AGENT_DIR: agentDir, PI_SUBAGENTS_TEMP_ROOT: join(tronHome, "internal", "subagents"),
    PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT: join(root, "unavailable-inherited-host"),
    npm_config_cache: join(root, "npm-cache"), npm_config_offline: "true", npm_config_registry: "http://registry.invalid" };
  const previous = Object.fromEntries(Object.keys(overrides).map((name) => [name, process.env[name]]));
  let registry: RuntimeRegistry | undefined;
  let server: Server | undefined;
  let resumeTarget: string | undefined;
  let candidateTarget: string | undefined;
  let requests = 0;
  const facts: Record<string, unknown> = { leg, passed: false };
  try {
    Object.assign(process.env, overrides);
    // Match Gateway startup: the process selects its own host (overriding an
    // inherited selection) before loading the reserved extension, whose
    // detached children cannot resolve the Gateway SDK locally.
    delegatedProviderEnvironment(overrides.PI_SUBAGENTS_TEMP_ROOT);
    const managedSubagents = new ManagedSubagents(tronHome);
    const installedRoot = managedSubagents.install();
    const pin = JSON.parse(await readFile(join(gatewayRoot, "pi-subagents-pin.json"), "utf8"));
    const receipt = JSON.parse(await readFile(join(installedRoot, "tron-install-receipt.json"), "utf8"));
    expect(receipt).toMatchObject({ version: pin.version, sha512: pin.closure.sha512, forkCommit: pin.fork.commit });
    expect(installedRoot).toBe(join(await realpath(tronHome), "internal", "pi-subagents", pin.version));
    facts.receipt = receipt;
    if (process.env.TRON_SUBAGENTS_ROLLBACK_INVALID_ENTRY) {
      const settings = SettingsManager.create(cwd, agentDir, { projectTrusted: false });
      const before = await retainedFiles(installedRoot);
      await expect(managedSubagents.loaderOptions(settings)).rejects.toMatchObject({ code: "conflict" });
      expect(() => managedSubagents.admit([])).toThrow(GatewayError);
      expect(await retainedFiles(installedRoot)).toEqual(before);
      facts.passed = true;
      return;
    }
    const model = { provider: "tron-rollback-subagents", id: "rollback-model" };
    // Requests are keyed by the current canonical turn, not arrival order:
    // detached revive and parent acknowledgement can arrive concurrently.
    server = createServer(async (request, response) => {
      let bytes = "";
      for await (const chunk of request) {
        bytes += chunk;
        if (bytes.length > 2 * 1024 * 1024) { response.writeHead(413).end(); return; }
      }
      const messages = JSON.parse(bytes).messages as Array<{ role: string; content: unknown }>;
      const last = messages.at(-1);
      const input = typeof last?.content === "string" ? last.content : JSON.stringify(last?.content);
      let scripted: string | { id: string; args: Record<string, unknown> } | undefined;
      if (last?.role === "tool") scripted = "PARENT_COMPLETE";
      else if (input.includes("Launch rollback-worker and report completion")) scripted = {
        id: `${leg}-launch`, args: { agent: "rollback-worker", task: `Return CHILD_${leg!.toUpperCase()}_COMPLETE`, async: false,
          acceptance: { level: "none", reason: "Read-only rollback probe" } },
      };
      else if (input.includes("Inspect the retained candidate run without changing it")) scripted = {
        id: "rollback-status", args: { action: "status", id: candidateTarget },
      };
      else if (input.includes("Resume the retained candidate child through the selected previous provider")) scripted = {
        id: "rollback-resume", args: { action: "resume", id: candidateTarget, message: "Return CHILD_ROLLBACK_RESUMED", async: false },
      };
      else if (input.includes("Inspect the completed revived run")) scripted = {
        id: "rollback-resume-status", args: { action: "status", id: resumeTarget },
      };
      else if (input.includes("CHILD_ROLLBACK_RESUMED")) scripted = "CHILD_ROLLBACK_RESUMED";
      else if (input.includes(`CHILD_${leg!.toUpperCase()}_COMPLETE`)) scripted = `CHILD_${leg!.toUpperCase()}_COMPLETE`;
      // Completion notifications are additional parent turns, never child work.
      else if (input.includes("Subagent updates above.") || (input.toLowerCase().includes("subagent") && input.includes("complete"))) scripted = "PARENT_COMPLETE";
      ((facts.modelRoutes ??= []) as unknown[]).push({ role: last?.role, input: input.slice(0, 512), response: scripted });
      if (++requests > 24 || scripted === undefined || request.url !== "/v1/chat/completions") {
        response.writeHead(500).end(`Unexpected model request: ${input}`);
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
      candidateTarget = candidate.completion.runId;
      await old.prompt("Inspect the retained candidate run without changing it");
      await waitFor(() => !old.isBusy, "rollback candidate status");
      const result = SessionManager.open(old.sessionFile!).getEntries().find((entry) => entry.type === "message"
        && entry.message.role === "toolResult" && entry.message.toolCallId === "rollback-status");
      facts.retainedStatusResult = result;
      expect(result, JSON.stringify(result)).toMatchObject({ message: { isError: false } });
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
      await old.prompt("Resume the retained candidate child through the selected previous provider");
      const resumed = await waitFor(() => SessionManager.open(old.sessionFile!).getEntries().find((entry) => entry.type === "message"
        && entry.message.role === "toolResult" && entry.message.toolCallId === "rollback-resume"), "accepted rollback revival");
      facts.retainedResumeResult = resumed;
      expect(resumed, JSON.stringify(resumed)).toMatchObject({ message: { isError: false } });
      if (!resumed || resumed.type !== "message" || resumed.message.role !== "toolResult") throw new Error("Missing canonical rollback resume");
      const detail = resumed.message.details as { asyncId: string; asyncDir: string };
      expect(detail.asyncId).toBeTruthy();
      expect(detail.asyncDir).toBeTruthy();
      resumeTarget = detail.asyncId;
      const childFile = join(root, candidate.completion.childFile);
      await waitFor(() => SessionManager.open(childFile).getEntries().some((entry) => entry.type === "message"
        && entry.message.role === "assistant" && entry.message.content.some((block) => block.type === "text" && block.text === "CHILD_ROLLBACK_RESUMED")),
      "revived canonical child completion", { intervalMs: 100 });
      const terminal = await waitFor(async () => {
        try {
          const proof = JSON.parse(await readFile(join(detail.asyncDir, "process-terminal.json"), "utf8"));
          return proof.state === "observed" ? proof : false;
        } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; }
      }, "revived process exit observation", { intervalMs: 100 });
      expect(terminal.runId).toBe(detail.asyncId);
      expect(terminal.instances.length).toBeGreaterThan(0);
      for (const instance of terminal.instances) expect(instance).toMatchObject({ exitCode: 0, signal: null });
      await waitFor(() => !old.isBusy, "revive notification settlement").catch((error) => {
        facts.busyAfterRevival = { snapshot: old.snapshot(), tail: SessionManager.open(old.sessionFile!).getEntries().slice(-4) };
        throw error;
      });
      await old.prompt("Inspect the completed revived run");
      await waitFor(() => !old.isBusy, "revived producer status");
      const status = SessionManager.open(old.sessionFile!).getEntries().find((entry) => entry.type === "message"
        && entry.message.role === "toolResult" && entry.message.toolCallId === "rollback-resume-status");
      expect(status).toMatchObject({ message: { isError: false } });
      if (!status || status.type !== "message" || status.message.role !== "toolResult") throw new Error("Missing revived status");
      const text = status.message.content.filter((block) => block.type === "text").map((block) => block.text).join("\n");
      facts.revivedTerminal = terminal;
      facts.revivedStatus = text;
      expect(text).toMatch(/complete|completed/);
      expect(text).toContain("Process terminal: observed");
      const child = SessionManager.open(join(root, candidate.completion.childFile));
      expect(child.getSessionId()).toBe(candidate.completion.childId);
      expect(child.getEntries().some((entry) => entry.type === "message" && entry.message.role === "assistant"
        && entry.message.content.some((block) => block.type === "text" && block.text === "CHILD_ROLLBACK_RESUMED"))).toBe(true);
      facts.candidateResume = { runId: detail.asyncId, childId: child.getSessionId(), exitCode: 0,
        output: "CHILD_ROLLBACK_RESUMED", canonicalChildRetained: true, processesExited: true };
    }
    facts.passed = true;
  } catch (error) {
    facts.error = error instanceof Error ? error.message : String(error);
    throw error;
  } finally {
    try {
      await registry?.dispose();
    } finally {
      // Producer terminal evidence proves the run, not fixture retirement.
      // Join spawn-owned trees even if an assertion failed before asyncDir was
      // returned. The inherited preload also owns runner descendants and joins
      // on process exit/signals before the outer harness can remove roots.
      const { disposeFixtureProcesses } = await import("../../test-support/fixture-process-owner.mjs");
      await disposeFixtureProcesses();
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
