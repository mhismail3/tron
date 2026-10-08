import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import net from "node:net";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } from "./managed-subagents.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";

/** Real Gateway/SDK execution; only the external model output is scripted.
 * The fixture owns home/cache/session state and disposes the runtime before files. */
it("activates offline from empty home/cache, discovers and completes a real canonical child", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-offline-subagents-"));
  const agentDir = join(root, "agent");
  const cache = join(root, "npm-cache");
  const cwd = join(root, "workspace");
  const tronHome = join(root, "tron");
  const overrides = {
    PI_CODING_AGENT_DIR: agentDir,
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
    // Deny all TCP, including loopback: this case needs no HTTP fixture.
    net.Socket.prototype.connect = function () {
      networkAttempts++;
      throw new Error("Network denied during managed subagent activation/execution");
    } as typeof connect;
    const managedSubagents = new ManagedSubagents(tronHome);
    const installedRoot = managedSubagents.install();
    const receipt = JSON.parse(await readFile(join(installedRoot, "tron-install-receipt.json"), "utf8"));
    facts.receipt = receipt;
    const faux = fauxProvider({ provider: "tron-offline-subagents", tokensPerSecond: 10_000 });
    const model = faux.getModel();
    await mkdir(join(cwd, ".pi", "agents"), { recursive: true });
    await writeFile(join(cwd, ".pi", "agents", "offline-worker.md"), `---\nname: offline-worker\ndescription: Offline activation probe\nmodel: ${model.provider}/${model.id}\ntools: read\n---\nReturn the requested probe marker.\n`);
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
      agentDir, tronHome, managedSubagents, trust, idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    await registry.initialize();
    const slot = await registry.create(cwd);
    await slot.setModel(model.provider, model.id);
    const resources = await slot.resources() as unknown as {
      subagents: Array<{ name: string }>; tools: Array<{ name: string; source: string }>;
      subagentDiagnostics?: string;
    };
    expect(resources.subagentDiagnostics).toBeUndefined();
    expect(resources.subagents.some((agent) => agent.name === "offline-worker")).toBe(true);
    expect(resources.subagents.some((agent) => agent.name === "researcher")).toBe(true);
    expect(resources.tools.some((tool) => tool.name === "subagent")).toBe(true);
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
      await mkdir(dirname(reportPath), { recursive: true });
      await writeFile(reportPath, `${JSON.stringify(facts, null, 2)}\n`);
    }
  }
}, 30_000);
