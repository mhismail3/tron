import { mkdir, mkdtemp, readFile, readdir, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import net from "node:net";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { PackageService } from "../admin/package-service.js";
import { GatewayLogger } from "../transport/logger.js";
import { TrustService } from "../admin/trust-service.js";
import { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } from "./managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, DELEGATED_PROVIDER_ROOT_ENV } from "./delegated-provider.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";

/** Real Gateway/SDK execution; only the external model output is scripted.
 * The fixture owns home/cache/session state and disposes the runtime before files. */
it.each([
  { conflict: false, bound: true, foreignHome: false },
  { conflict: true, bound: true, foreignHome: false },
  { conflict: false, bound: false, foreignHome: false },
  { conflict: false, bound: true, foreignHome: true },
])("activates offline with ignored packages=$conflict and bound root=$bound and foreign registry home=$foreignHome", async ({ conflict, bound, foreignHome }) => {
  const root = await mkdtemp(join(tmpdir(), "tron-offline-subagents-"));
  const agentDir = join(root, "agent");
  const cache = join(root, "npm-cache");
  const cwd = join(root, "workspace");
  const tronHome = join(root, "tron");
  const overrides = {
    PI_CODING_AGENT_DIR: agentDir,
    [DELEGATED_PROVIDER_ROOT_ENV]: undefined as string | undefined,
    PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT: undefined as string | undefined,
    PI_SUBAGENT_CHILD: undefined as string | undefined,
    npm_config_cache: cache,
    npm_config_offline: "true",
    npm_config_registry: "http://registry.invalid",
  };
  const previous = Object.fromEntries(Object.keys(overrides).map((name) => [name, process.env[name]]));
  const connect = net.Socket.prototype.connect;
  let networkAttempts = 0;
  let registry: RuntimeRegistry | undefined;
  const reportPath = process.env.TRON_SUBAGENTS_REPORT ?? join(process.cwd(), "test-results", "managed-subagents.integration.json");
  const facts: Record<string, unknown> = { passed: false };
  try {
    await Promise.all([mkdir(agentDir), mkdir(cache), mkdir(cwd)]);
    expect(await readdir(agentDir)).toEqual([]);
    expect(await readdir(cache)).toEqual([]);
    facts.emptyAgentHome = true;
    facts.emptyNpmCache = true;
    Object.assign(process.env, overrides);
    delete process.env[DELEGATED_PROVIDER_ROOT_ENV];
    delete process.env.PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT;
    if (bound) delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    // Deny all TCP, including loopback: this case needs no HTTP fixture.
    net.Socket.prototype.connect = function () {
      networkAttempts++;
      throw new Error("Network denied during managed subagent activation/execution");
    } as typeof connect;
    const settingsFiles = [join(agentDir, "settings.json"), join(cwd, ".pi", "settings.json")];
    const untouched = new Map<string, string>();
    const loadedMarker = join(root, "user-package-loaded");
    if (conflict) {
      for (const [index, base] of [agentDir, join(cwd, ".pi")].entries()) {
        const packageRoot = join(base, "npm", "node_modules", "pi-subagents");
        await mkdir(join(packageRoot, "skills", "ignored-user-skill"), { recursive: true });
        await mkdir(join(packageRoot, "prompts"), { recursive: true });
        const files = {
          [settingsFiles[index]!]: JSON.stringify({ packages: index ? [{ source: "npm:pi-subagents@0.59.0", extensions: ["index.mjs"] }] : ["npm:pi-subagents@0.59.0"] }),
          [join(base, "npm", "package.json")]: JSON.stringify({ dependencies: { "pi-subagents": "0.59.0" } }),
          [join(packageRoot, "package.json")]: JSON.stringify({ name: "pi-subagents", version: "0.59.0", pi: { extensions: ["index.mjs"], skills: ["skills"], prompts: ["prompts"] } }),
          [join(packageRoot, "skills", "ignored-user-skill", "SKILL.md")]: "---\nname: ignored-user-skill\ndescription: Must not load\n---\nIgnored",
          [join(packageRoot, "prompts", "ignored-user-prompt.md")]: "Ignored",
          [join(packageRoot, "index.mjs")]: `import {writeFileSync} from 'node:fs'; writeFileSync(${JSON.stringify(loadedMarker)}, 'loaded'); export default pi => pi.registerTool({name:'subagent',label:'Foreign',description:'Foreign',parameters:{type:'object'},execute:async()=>({content:[]})});`,
        };
        for (const [path, bytes] of Object.entries(files)) { await writeFile(path, bytes); untouched.set(path, bytes); }
      }
    }
    await mkdir(join(agentDir, "skills", "ordinary-local"), { recursive: true });
    await writeFile(join(agentDir, "skills", "ordinary-local", "SKILL.md"), "---\nname: ordinary-local\ndescription: Local resource control\n---\nLocal");
    const logger = new GatewayLogger();
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome, logger);
    const installedRoot = managedSubagents.verify();
    const receiptPath = join(installedRoot, "tron-install-receipt.json");
    const receipt = JSON.parse(await readFile(receiptPath, "utf8"));
    const beforeRestart = await Promise.all([stat(installedRoot), stat(receiptPath)]);
    const restarted = ManagedSubagents.activateForStartup(tronHome);
    expect(restarted.root).toBe(installedRoot);
    const afterRestart = await Promise.all([stat(installedRoot), stat(receiptPath)]);
    expect(afterRestart.map(({ ino, mtimeMs }) => ({ ino, mtimeMs })))
      .toEqual(beforeRestart.map(({ ino, mtimeMs }) => ({ ino, mtimeMs })));
    facts.receipt = receipt;
    facts.restartReusedImmutableRoot = true;
    const faux = fauxProvider({ provider: "tron-offline-subagents", tokensPerSecond: 10_000 });
    const model = faux.getModel();
    await mkdir(join(cwd, ".pi", "agents"), { recursive: true });
    await writeFile(join(cwd, ".pi", "agents", "offline-worker.md"), `---\nname: offline-worker\ndescription: Offline activation probe\nmodel: ${model.provider}/${model.id}\ntools: read\n---\nReturn the requested probe marker.\n`);
    const invalidDefinition = join(cwd, ".pi", "agents", "invalid-worker.md");
    if (conflict) await writeFile(invalidDefinition, "---\nname: invalid-worker\ndescription: Invalid definition probe\nfallbackModels: [provider/model]\n---\nRead only.\n");
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", {
        agent: "offline-worker", task: "Return CHILD_OFFLINE_COMPLETE", async: false,
        acceptance: { level: "none", reason: "Read-only offline activation probe" },
      }, { id: "offline-launch" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("CHILD_OFFLINE_COMPLETE"),
      fauxAssistantMessage("PARENT_OFFLINE_COMPLETE"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    registry = new RuntimeRegistry({
      agentDir, tronHome: foreignHome ? join(root, "foreign-tron") : tronHome, managedSubagents, trust, idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    await registry.initialize();
    if (!bound || foreignHome) {
      let failure: unknown;
      let unexpectedSlot;
      try { unexpectedSlot = await registry.create(cwd); }
      catch (error) { failure = error; }
      if (unexpectedSlot) {
        // A negative control may admit the provider. Join its real execution
        // before asserting refusal so disposal cannot race session-start work.
        await unexpectedSlot.setModel(model.provider, model.id);
        await unexpectedSlot.prompt("Launch offline-worker and report completion");
        await waitFor(() => !unexpectedSlot!.isBusy, "unexpected unbound child completion");
      }
      expect(failure).toMatchObject({ message: expect.stringMatching(/managed pi-subagents requires PI_SUBAGENTS_TEMP_ROOT/) });
      facts.invalidHomeBindingRefused = true;
      facts.passed = true;
      return;
    }
    const slot = await registry.create(cwd);
    await slot.setModel(model.provider, model.id);
    const resources = await slot.resources() as unknown as {
      subagents: Array<{ name: string }>; tools: Array<{ name: string; source: string }>;
      subagentDiagnostics?: string;
      skills: { skills: Array<{ name: string; path: string; source: string; distribution?: string }> };
      prompts: { prompts: Array<{ name: string; path: string; source: string; distribution?: string }> };
    };
    if (conflict) {
      expect(resources.subagentDiagnostics).toContain("fallbackModels");
      expect(resources.subagentDiagnostics).toContain("invalid-worker");
      expect(logger.recent(100).filter(row => row.event === "pi-subagents.agent-definition-invalid")).toMatchObject([
        { counts: { definitions: 1 } },
      ]);
      await slot.resources();
      expect(logger.recent(100).filter(row => row.event === "pi-subagents.agent-definition-invalid")).toHaveLength(1);
    } else expect(resources.subagentDiagnostics).toBeUndefined();
    const assertManagedResources = (value: typeof resources) => {
      for (const name of ["pi-subagents", "council-mode"]) {
        expect(value.skills.skills.find(skill => skill.name === name)?.path.startsWith(`${installedRoot}/skills/`)).toBe(true);
      }
      expect(value.skills.skills.find(skill => skill.name === "pi-subagents")).toMatchObject({ source: MANAGED_SUBAGENTS_SOURCE, distribution: "external" });
      expect(value.skills.skills.find(skill => skill.name === "ordinary-local")).toMatchObject({ source: "auto", distribution: "local" });
      for (const prompt of value.prompts.prompts.filter(prompt => prompt.path.startsWith(`${installedRoot}/prompts/`))) {
        expect(prompt).toMatchObject({ source: MANAGED_SUBAGENTS_SOURCE, distribution: "external" });
      }
      expect(value.skills.skills.some(skill => skill.name === "ignored-user-skill")).toBe(false);
      expect(value.prompts.prompts.some(prompt => prompt.path.startsWith(`${installedRoot}/prompts/`))).toBe(true);
      expect(value.prompts.prompts.some(prompt => prompt.name === "ignored-user-prompt")).toBe(false);
    };
    assertManagedResources(resources);
    facts.managedResources = {
      skills: resources.skills.skills.filter(skill => skill.path.startsWith(`${installedRoot}/skills/`)).map(({ name, source, distribution }) => ({ name, source, distribution })),
      prompts: resources.prompts.prompts.filter(prompt => prompt.path.startsWith(`${installedRoot}/prompts/`)).map(({ name, source, distribution }) => ({ name, source, distribution })),
      localControl: resources.skills.skills.find(skill => skill.name === "ordinary-local")?.source,
      ignoredUserResourcesAbsent: true,
    };
    expect(resources.subagents.some((agent) => agent.name === "offline-worker")).toBe(true);
    expect(resources.subagents.some((agent) => agent.name === "researcher")).toBe(true);
    expect(resources.tools.find(tool => tool.name === "subagent")).toMatchObject({ source: MANAGED_SUBAGENTS_SOURCE });
    if (conflict) {
      for (const trusted of [false, true]) {
        await trust.set(cwd, trusted);
        await slot.reload(trusted, true, true);
        assertManagedResources(await slot.resources() as unknown as typeof resources);
      }
      const inventory = await new PackageService(agentDir, trust, () => {}, undefined, managedSubagents).list(cwd) as {
        packages: Array<{source: string; conflict?: {code: string; message: string}; provides: {tools: string[]; subagents: string[]; skills: string[]; prompts: string[]}}>;
      };
      const ignored = inventory.packages.filter(row => row.source === "npm:pi-subagents@0.59.0");
      expect(ignored).toHaveLength(2);
      for (const row of ignored) {
        expect(row.conflict).toEqual({ code: "managed-provider", message: "Tron manages pi-subagents; this user declaration is ignored. Remove it with `pi remove npm:pi-subagents`." });
        expect(Object.values(row.provides).flat()).toEqual([]);
      }
      const provided = inventory.packages.find(row => row.source === MANAGED_SUBAGENTS_SOURCE)!.provides;
      expect(provided.tools).toContain("subagent");
      expect(provided.skills).toEqual(["council-mode", "pi-subagents"]);
      expect(provided.prompts).toEqual(resources.prompts.prompts.filter(prompt => prompt.path.startsWith(`${installedRoot}/prompts/`)).map(prompt => prompt.name).sort());
      expect(provided.prompts.length).toBeGreaterThan(0);
      expect(logger.recent(100).filter(row => row.event === "pi-subagents.user-package-ignored")).toHaveLength(4);
      expect(await stat(loadedMarker).then(() => true, () => false)).toBe(false);
      for (const [path, bytes] of untouched) expect(await readFile(path, "utf8")).toBe(bytes);
      expect(logger.recent(100).filter(row => row.event === "pi-subagents.agent-definition-invalid")).toHaveLength(4);
      await writeFile(invalidDefinition, "---\nname: invalid-worker\ndescription: Repaired definition\n---\nRead only.\n");
      await slot.reload(true, true, true);
      expect((await slot.resources() as Record<string, unknown>).subagentDiagnostics).toBeUndefined();
      expect(logger.recent(100).filter(row => row.event === "pi-subagents.agent-definition-invalid")).toHaveLength(4);
      facts.invalidDefinition = { field: "fallbackModels", reportCount: 4, readsDoNotReport: true, clearedAfterRepair: true };
      facts.ignoredPackage = { scopes: 2, diagnosticCount: 4, userCodeLoaded: false, filesUnchanged: true };
    }
    facts.discovery = { agent: "offline-worker", packagedAgent: "researcher", source: MANAGED_SUBAGENTS_SOURCE };
    await slot.prompt("Launch offline-worker and report completion");
    await waitFor(() => !slot.isBusy, "real subagent completion");
    const session = SessionManager.open(slot.sessionFile!);
    const results = session.getEntries().filter((entry) => entry.type === "message" && entry.message.role === "toolResult");
    const launch = results.find((entry) => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "offline-launch");
    expect(launch).toBeDefined();
    expect(launch).toMatchObject({ message: { toolName: "subagent", isError: false } });
    if (!launch || launch.type !== "message" || launch.message.role !== "toolResult") throw new Error("Missing canonical launch");
    const details = launch.message.details as {
      runId: string;
      results: Array<{ index: number; exitCode: number; finalOutput: string; sessionFile: string; sessionOwnerId: string }>;
    };
    expect(details.results).toHaveLength(1);
    const result = details.results[0]!;
    expect(result).toMatchObject({ index: 0, exitCode: 0, finalOutput: "CHILD_OFFLINE_COMPLETE", sessionOwnerId: details.runId });
    expect(relative(agentDir, result.sessionFile).startsWith("..")).toBe(false);
    const child = SessionManager.open(result.sessionFile);
    expect(child.getSessionId()).not.toBe(session.getSessionId());
    const childMessages = child.getEntries().filter((entry) => entry.type === "message");
    expect(childMessages.some((entry) => entry.type === "message" && entry.message.role === "assistant"
      && entry.message.content.some((block) => block.type === "text" && block.text === "CHILD_OFFLINE_COMPLETE"))).toBe(true);
    const activity = slot.snapshot().processActivities?.find((row) => row.toolCallId === "offline-launch");
    expect(activity).toMatchObject({
      kind: "subagent", runId: details.runId, childSessionRef: child.getSessionId(), lifecycle: { state: "completed" },
    });
    expect(activity).toBeDefined();
    const admitted = await registry.resolveReadOnlySubagentPath(
      child.getSessionId(), await realpath(result.sessionFile), slot.id, activity!.processId, details.runId,
    );
    const transcript = await registry.readOnlySubagentTranscriptPage(
      child.getSessionId(), admitted.path, slot.id, activity!.processId, details.runId,
    );
    expect(transcript.total).toBeGreaterThan(0);
    expect(JSON.stringify(transcript)).toContain("CHILD_OFFLINE_COMPLETE");
    facts.declaredTranscript = { sessionRef: child.getSessionId(), total: transcript.total };
    const receiptEntry = session.getEntries().find((entry) => entry.type === "custom"
      && entry.customType === "tron.extension-activity.v1");
    expect(receiptEntry).toMatchObject({ data: {
      runId: details.runId, state: "completed", owner: { source: MANAGED_SUBAGENTS_SOURCE },
      summary: { children: [{ childSessionRef: child.getSessionId(), sessionOwnerId: details.runId }] },
    } });
    facts.completion = { runId: details.runId, output: result.finalOutput, exitCode: result.exitCode,
      canonicalChildSessionId: child.getSessionId(), canonicalChildMessages: childMessages.length,
      gatewayChildSessionRef: activity?.childSessionRef, gatewayState: activity?.lifecycle.state,
      ownerSource: MANAGED_SUBAGENTS_SOURCE };
    expect(networkAttempts).toBe(0);
    for (const [path, bytes] of untouched) expect(await readFile(path, "utf8")).toBe(bytes);
    expect(await stat(loadedMarker).then(() => true, () => false)).toBe(false);
    facts.passed = true;
  } finally {
    try { await registry?.dispose(); }
    finally {
      net.Socket.prototype.connect = connect;
      for (const [name, value] of Object.entries(previous)) {
        if (value === undefined) delete process.env[name];
        else process.env[name] = value;
      }
      facts.networkAttempts = networkAttempts;
      await rm(root, { recursive: true, force: true });
      const defaultRoot = join(tmpdir(), `pi-subagents-uid-${process.getuid?.() ?? "unknown"}`);
      facts.defaultRootAbsent = !await stat(defaultRoot).then(() => true, () => false);
      await mkdir(dirname(reportPath), { recursive: true });
      const suffix = foreignHome ? ".foreign-home.json" : !bound ? ".unbound.json" : conflict ? ".conflict.json" : ".json";
      await writeFile(reportPath.replace(/\.json$/u, suffix), `${JSON.stringify(facts, null, 2)}\n`);
      expect(facts.defaultRootAbsent, "managed provider must never create the system-temp default root").toBe(true);
    }
  }
});
