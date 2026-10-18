import { appendFile, mkdir, readFile, realpath, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ExtensionRunActivity, ExtensionToolOrigin } from "../protocol/types.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";
import { createColdRegistryFixture } from "../../test-support/runtime-registry-fixture.js";

describe("RuntimeRegistry with the pinned agent runtime", { concurrent: false }, () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];
  const coldFixture = createColdRegistryFixture.bind(undefined, registries);

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  it("rejects read-only child access without an exact live parent process owner", async () => {
    const fixture = await coldFixture("readonly-unowned", { nested: true, name: "subagent-worker" });
    const sessionId = fixture.manager.getSessionId();
    await expect(fixture.registry.resolveReadOnlySubagentPath(
      sessionId,
      await realpath(fixture.sessionFile),
      "missing-parent",
      "missing-process",
      "missing-run",
    )).rejects.toMatchObject({ code: "not_found" });
    expect(fixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("retries a live child binding when the canonical session appears after status publication", async () => {
    const fixture = await coldFixture("delayed-live-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const rootRunId = "delayed-workflow-root";
    const childRunId = "delayed-workflow-child";
    const toolCallId = "delayed-workflow-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", rootRunId);
    const parentFile = slot.sessionFile!;
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), childRunId, "run-0");
    const childFile = join(childDirectory, "session.jsonl");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    const started = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: rootRunId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 500,
      mode: "workflow",
      steps: [{
        workflowKey: "delayed-child",
        runId: childRunId,
        agent: "worker",
        status: "running",
        sessionFile: childFile,
      }],
    }));
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      startExtensionActivityWatcher: (toolCallId: string, asyncDir: string) => void;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "delayed-workflow-activity", runId: rootRunId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(rootRunId, { toolCallId, asyncDir, terminal: false });
    internal.startExtensionActivityWatcher(toolCallId, asyncDir);
    await waitFor(() => slot.snapshot().processActivities?.some((activity) =>
      activity.kind === "subagent" && activity.childSessionRef === undefined) === true, "the subagent activity without a child reference");

    const childManager = SessionManager.create(fixture.cwd, childDirectory, { id: "delayed-child-session" });
    childManager.appendMessage(fauxAssistantMessage("published after artifact status"));
    await rename(childManager.getSessionFile()!, childFile);

    await waitFor(() => slot.snapshot().processActivities?.some((activity) =>
      activity.kind === "subagent" && activity.childSessionRef === "delayed-child-session") === true, "the delayed subagent child reference");
    const process = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(process).toMatchObject({ childSessionRef: "delayed-child-session", visibility: "active" });
    expect(slot.processChildSessionBinding(process!.processId)).toMatchObject({
      ref: "delayed-child-session",
      producerId: "delayed-child",
      sessionOwnerId: childRunId,
      runId: rootRunId,
    });
  });

  it("admits the exact fresh child path for read-only process viewing", async () => {
    const fixture = await coldFixture("validated-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "validated-child-run";
    const toolCallId = "validated-child-tool";
    const activityId = "validated-child-activity";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    const parentFile = slot.sessionFile!;
    const childProducerId = "step:0";
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), runId, "run-0");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    // Match the current producer: the root run reserves the fresh session
    // directory while the stable artifact step owns the child process row.
    const childManager = SessionManager.create(fixture.cwd, childDirectory, {
      id: "validated-child-session",
    });
    childManager.appendMessage(fauxAssistantMessage("child transcript"));
    const generatedChildFile = childManager.getSessionFile()!;
    const childFile = join(childDirectory, "session.jsonl");
    await rename(generatedChildFile, childFile);
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId, runId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId,
      state: "running",
      startedAt: Date.parse(startedAt),
      lastUpdate: Date.now(),
      mode: "workflow",
      steps: [{ agent: "worker", status: "running", sessionFile: childFile }],
    }));
    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    const activeSnapshot = slot.snapshot();
    const activeProcess = activeSnapshot.processActivities?.find((activity) => activity.kind === "subagent");
    expect(activeSnapshot.extensionActivities?.[0]?.lifecycle).toMatchObject({
      state: "running",
      visibility: "current",
    });
    expect(activeSnapshot.extensionActivities?.[0]?.lifecycle).not.toHaveProperty("remainingMs");
    expect(activeProcess).toMatchObject({
      title: "worker",
      childSessionRef: "validated-child-session",
      executionMode: "asynchronous",
      visibility: "active",
      lifecycle: { state: "running" },
    });

    // Pi reloads configured npm packages through their resolved local path in
    // production. Controller authority follows the exact installed owner ID,
    // not the mutable `source` display label.
    const localOwner = {
      id: "extension:installed-subagent", title: "Pi Subagents", source: "local",
    };
    const controllerOrigin = { source: "local", owner: localOwner };
    const controllerExecute = vi.fn(async (..._arguments: unknown[]) => ({
      content: [{ type: "text", text: "stopped" }], details: {},
    }));
    const abortInternals = slot as unknown as {
      extensionToolOrigin: (toolName: string) => ExtensionToolOrigin | undefined;
      subagentExtensionOrigin: () => ExtensionToolOrigin;
      runtime: { session: { extensionRunner: { getToolDefinition: (toolName: string) => unknown } } };
    };
    const toolOrigin = vi.spyOn(abortInternals, "extensionToolOrigin").mockReturnValue(controllerOrigin);
    const installedOrigin = vi.spyOn(abortInternals, "subagentExtensionOrigin").mockReturnValue(controllerOrigin);
    const toolDefinition = vi.spyOn(abortInternals.runtime.session.extensionRunner, "getToolDefinition")
      .mockReturnValue({ execute: controllerExecute });
    expect(slot.processSubagentAbortAuthority(activeProcess!.processId, runId)).toEqual({});
    await slot.abortSubagentProcess(activeProcess!.processId, runId);
    expect(controllerExecute.mock.calls[0]?.[1]).toEqual({
      action: "stop", id: runId, childId: childProducerId,
    });
    toolOrigin.mockRestore();
    installedOrigin.mockRestore();
    toolDefinition.mockRestore();

    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId,
      state: "complete",
      startedAt: Date.parse(startedAt),
      endedAt,
      lastUpdate: endedAt + 1,
      mode: "workflow",
      steps: [{ agent: "worker", status: "completed", sessionFile: childFile }],
    }));

    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    const process = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(process).toMatchObject({
      title: "worker",
      childSessionRef: "validated-child-session",
      executionMode: "asynchronous",
    });
    expect(JSON.stringify(process)).not.toContain(childFile);
    expect(slot.processChildSessionPath(process!.processId)).toEqual({
      ref: "validated-child-session",
      producerId: childProducerId,
      runId,
      path: await realpath(childFile),
    });
    const admission = await fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", await realpath(childFile), slot.id, process!.processId, runId,
    );
    const page = await fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    );
    expect(page.total).toBeGreaterThan(0);
    expect(page.revision).toMatch(/^[a-f0-9]{32}$/u);
    expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);

    // Ownership reads only the immutable session header, so an in-progress
    // canonical append cannot transiently become an identity change. Page
    // projection still waits for that JSONL entry's terminating newline.
    const existingLines = (await readFile(childFile, "utf8")).trimEnd().split("\n");
    const parentId = (JSON.parse(existingLines.at(-1)!) as { id: string }).id;
    const appendedEntry = JSON.stringify({
      type: "message",
      id: "live-child-append",
      parentId,
      timestamp: new Date().toISOString(),
      message: fauxAssistantMessage("live appended transcript"),
    });
    await appendFile(childFile, appendedEntry);
    await expect(fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
    )).resolves.toMatchObject({ path: admission.path, fileIdentity: admission.fileIdentity });
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).rejects.toMatchObject({ code: "busy", retryable: true });
    await appendFile(childFile, "\n");
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).resolves.toMatchObject({ fileIdentity: admission.fileIdentity });

    await expect(fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", admission.path, slot.id, "wrong-process", runId,
    )).rejects.toMatchObject({ code: "not_found" });
    await waitFor(() => slot.processHistory(undefined, 25, { kind: "subagent" }).activities.length === 1, "the subagent history entry");
    expect(slot.processHistory(undefined, 25, { kind: "subagent" }).activities[0])
      .toMatchObject({ childSessionRef: "validated-child-session" });
    // Historical opening must derive its exact binding from the canonical
    // receipt rather than an unbounded runtime cache.
    (slot as unknown as { childSessionBindings: Map<string, unknown> }).childSessionBindings.clear();
    expect(slot.processChildSessionBinding(process!.processId)).toMatchObject({
      ref: "validated-child-session", producerId: childProducerId, sessionOwnerId: runId, runId,
    });

    const replacement = `${childFile}.replacement`;
    await writeFile(replacement, await readFile(childFile));
    await rm(childFile);
    await rename(replacement, childFile);
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).rejects.toMatchObject({ code: "conflict", retryable: true });
  });

  it("binds a live async single child through its exact recovery root owner", async () => {
    const fixture = await coldFixture("validated-async-single-recovery-owner");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const asyncRunId = "async-single-run";
    const rootRunId = "parent-root-run";
    const toolCallId = "async-single-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", asyncRunId);
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), rootRunId, "run-0");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    const childManager = SessionManager.create(fixture.cwd, childDirectory, { id: "async-single-child-session" });
    childManager.appendMessage(fauxAssistantMessage("live async single transcript"));
    const childFile = join(childDirectory, "session.jsonl");
    await rename(childManager.getSessionFile()!, childFile);
    const started = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "async-single-activity", runId: asyncRunId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(asyncRunId, { toolCallId, asyncDir, terminal: false });
    const statusPath = join(asyncDir, "status.json");
    const descriptorPath = join(asyncDir, "recovery-descriptor.json");
    await writeFile(statusPath, JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: asyncRunId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 500,
      mode: "single",
      // A raw status field cannot nominate the fresh path owner; only the
      // matching private descriptor may produce Gateway-attested evidence.
      steps: [{ agent: "worker", status: "running", sessionFile: childFile, sessionOwnerId: rootRunId }],
    }));
    await writeFile(descriptorPath, JSON.stringify({
      version: 1,
      sourceRunId: "foreign-async-run",
      sessionFile: childFile,
      runFanoutBudget: { version: 1, rootRunId, directory: "/private/opaque", limit: 64 },
    }));
    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    const unbound = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(unbound).toMatchObject({ source: "delegatedAgent", visibility: "active" });
    expect(unbound).not.toHaveProperty("childSessionRef");
    expect(slot.processChildSessionBinding(unbound!.processId)).toBeUndefined();

    // The descriptor is private producer evidence: its exact source run,
    // session file, and fan-out root must agree before the path owner is used.
    await writeFile(descriptorPath, JSON.stringify({
      version: 1,
      sourceRunId: asyncRunId,
      sessionFile: childFile,
      runFanoutBudget: { version: 1, rootRunId, directory: "/private/opaque", limit: 64 },
    }));
    await writeFile(statusPath, JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: asyncRunId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 700,
      mode: "single",
      steps: [{ agent: "worker", status: "running", sessionFile: childFile }],
    }));
    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);

    const bound = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(bound).toMatchObject({
      processId: unbound!.processId,
      childSessionRef: "async-single-child-session",
      visibility: "active",
    });
    expect(slot.processChildSessionBinding(bound!.processId)).toMatchObject({
      ref: "async-single-child-session",
      producerId: "step:0",
      sessionOwnerId: rootRunId,
      runId: asyncRunId,
    });
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      "async-single-child-session", await realpath(childFile), slot.id, bound!.processId, asyncRunId,
    )).total).toBeGreaterThan(0);
  });

  it("separates a workflow producer identity from its fresh child-run path owner", async () => {
    const fixture = await coldFixture("validated-workflow-child-owner");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const rootRunId = "workflow-root";
    const childRunId = "workflow-child-run";
    const producerId = "workflow-key";
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), childRunId, "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childManager = SessionManager.create(fixture.cwd, childDirectory, { id: "workflow-child-session" });
    childManager.appendMessage(fauxAssistantMessage("workflow child transcript"));
    const childFile = join(childDirectory, "session.jsonl");
    await rename(childManager.getSessionFile()!, childFile);
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const activity: ExtensionRunActivity = {
      id: "workflow-tool", activityId: "workflow-activity", runId: rootRunId, toolCallId: "workflow-tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "workflow", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: producerId, producerId, label: "worker", status: "running", lifecycle: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const internal = slot as unknown as {
      childSessionAdmission: { attach: (activity: ExtensionRunActivity, value: unknown, strategy: "piArtifact") => ExtensionRunActivity };
      syncSubagentProcesses: (activity: ExtensionRunActivity) => void;
    };
    const attached = internal.childSessionAdmission.attach(activity, {
      runId: rootRunId,
      steps: [{ workflowKey: producerId, runId: childRunId, agent: "worker", status: "running", sessionFile: childFile }],
    }, "piArtifact");
    internal.syncSubagentProcesses(attached);
    const process = slot.snapshot().processActivities?.find((candidate) => candidate.kind === "subagent");
    expect(process).toMatchObject({ childSessionRef: "workflow-child-session" });
    expect(slot.processChildSessionBinding(process!.processId)).toMatchObject({
      ref: "workflow-child-session", producerId, sessionOwnerId: childRunId, runId: rootRunId,
    });
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      "workflow-child-session", await realpath(childFile), slot.id, process!.processId, rootRunId,
    )).total).toBeGreaterThan(0);
  });

  it("admits a fork-context transcript only from its artifact child identity and mounted parent", async () => {
    const fixture = await coldFixture("validated-fork-context");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "fork-run");
    await Promise.all([mkdir(forksDirectory, { recursive: true }), mkdir(asyncDir, { recursive: true })]);
    const fork = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    const firstChildEntry = fork.appendMessage(fauxAssistantMessage("fork transcript"));
    const forkFile = fork.getSessionFile()!;
    const artifactChildId = "artifact-fork-child";
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set("fork-tool", {
      id: "fork-tool", activityId: "fork-activity", runId: "fork-run", toolCallId: "fork-tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set("fork-run", { toolCallId: "fork-tool", asyncDir, terminal: false });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId: "fork-run", state: "running", startedAt: Date.parse(startedAt), lastUpdate: Date.now(),
      mode: "workflow",
      steps: [{ runId: artifactChildId, agent: "filename-must-not-bind", status: "running", sessionFile: forkFile }],
    }));

    await internal.refreshExtensionActivityFromArtifact("fork-tool", asyncDir);
    const process = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(process).toMatchObject({ childSessionRef: fork.getSessionId() });
    expect(slot.processChildSessionPath(process!.processId)).toEqual({
      ref: fork.getSessionId(), producerId: artifactChildId, runId: "fork-run", path: await realpath(forkFile),
    });
    const admission = await fixture.registry.resolveReadOnlySubagentPath(
      fork.getSessionId(), await realpath(forkFile), slot.id, process!.processId, "fork-run",
    );
    const projected = await fixture.registry.readOnlySubagentTranscriptPage(
      fork.getSessionId(), admission.path, slot.id, process!.processId, "fork-run",
    );
    expect(projected.total).toBeGreaterThan(0);
    expect(projected.forkBoundary).toMatchObject({
      kind: "subagentFork", inheritedAnchorId: expect.any(String), gapOrdinal: 2,
    });
  });

  it("binds the canonical single-run fork step before and after terminal persistence", async () => {
    const fixture = await coldFixture("validated-single-fork-context");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "single-run");
    await Promise.all([mkdir(forksDirectory, { recursive: true }), mkdir(asyncDir, { recursive: true })]);
    const fork = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    fork.appendMessage(fauxAssistantMessage("single fork transcript"));
    const forkFile = fork.getSessionFile()!;
    const started = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set("single-tool", {
      id: "single-tool", activityId: "single-activity", runId: "single-run", toolCallId: "single-tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set("single-run", { toolCallId: "single-tool", asyncDir, terminal: false });
    const statusPath = join(asyncDir, "status.json");
    await writeFile(statusPath, JSON.stringify({
      runId: "single-run", state: "running", startedAt: started, lastUpdate: started + 500,
      mode: "single",
      steps: [{ agent: "worker", status: "running", sessionFile: forkFile }],
    }));

    await internal.refreshExtensionActivityFromArtifact("single-tool", asyncDir);
    const active = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(active).toMatchObject({ source: "delegatedAgent", childSessionRef: fork.getSessionId(), visibility: "active" });
    expect(slot.processChildSessionPath(active!.processId)).toEqual({
      ref: fork.getSessionId(), producerId: "step:0", runId: "single-run", path: await realpath(forkFile),
    });

    await writeFile(statusPath, JSON.stringify({
      runId: "single-run", state: "complete", startedAt: started, endedAt: started + 700, lastUpdate: started + 800,
      mode: "single",
      steps: [{ agent: "worker", status: "complete", sessionFile: forkFile }],
    }));
    await internal.refreshExtensionActivityFromArtifact("single-tool", asyncDir);
    const recent = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(recent).toMatchObject({
      processId: active!.processId,
      source: "delegatedAgent",
      childSessionRef: fork.getSessionId(),
      visibility: "recent",
      lifecycle: { state: "completed" },
    });
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      fork.getSessionId(), (await realpath(forkFile)), slot.id, recent!.processId, "single-run",
    )).total).toBeGreaterThan(0);
  });

  it("rejects wrong-parent, unbound, and extra-depth fork or fresh child paths", async () => {
    const fixture = await coldFixture("rejected-child-shapes");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const childRoot = join(dirname(parentFile), basename(parentFile, ".jsonl"));
    const forksDirectory = join(childRoot, "forks");
    const otherParent = SessionManager.create(fixture.cwd, dirname(parentFile), { id: "other-fork-parent" });
    otherParent.appendMessage(fauxAssistantMessage("other parent"));
    await mkdir(forksDirectory, { recursive: true });
    const wrongParentFork = SessionManager.forkFrom(otherParent.getSessionFile()!, fixture.cwd, forksDirectory);
    wrongParentFork.appendMessage(fauxAssistantMessage("wrong parent fork"));
    const validParentFork = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    validParentFork.appendMessage(fauxAssistantMessage("unbound fork"));
    const extraForkDirectory = join(forksDirectory, "extra");
    await mkdir(extraForkDirectory, { recursive: true });
    const extraDepthFork = SessionManager.forkFrom(parentFile, fixture.cwd, extraForkDirectory);
    extraDepthFork.appendMessage(fauxAssistantMessage("extra fork"));
    const extraRunDirectory = join(childRoot, "fresh-child", "run-0", "extra");
    await mkdir(extraRunDirectory, { recursive: true });
    const extraDepthRun = SessionManager.create(fixture.cwd, extraRunDirectory, {
      id: "extra-depth-run", parentSession: parentFile,
    });
    extraDepthRun.appendMessage(fauxAssistantMessage("extra run"));
    const extraDepthRunFile = join(extraRunDirectory, "session.jsonl");
    await rename(extraDepthRun.getSessionFile()!, extraDepthRunFile);
    const startedAt = new Date().toISOString();
    const activity: ExtensionRunActivity = {
      id: "tool", activityId: "activity", runId: "expected-run", toolCallId: "tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: "artifact-child", label: "worker", status: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const admission = (slot as unknown as {
      childSessionAdmission: { attach: (activity: ExtensionRunActivity, value: unknown) => ExtensionRunActivity };
    }).childSessionAdmission;
    const attach = admission.attach.bind(admission);
    const child = (sessionFile: string, producerId = "artifact-child", includeProducer = true) => attach({
      ...activity, children: [{ id: producerId, label: "worker", status: "running" }],
    }, {
      runId: "expected-run",
      results: [{ ...(includeProducer ? { runId: producerId } : {}), agent: producerId, sessionFile }],
    }).children[0]?.childSessionRef;

    expect(child(wrongParentFork.getSessionFile()!)).toBeUndefined();
    expect(child(validParentFork.getSessionFile()!, "artifact-child", false)).toBeUndefined();
    expect(child(extraDepthFork.getSessionFile()!)).toBeUndefined();
    expect(child(extraDepthRunFile, "fresh-child")).toBeUndefined();
  });

  it("fails closed for foreign or wrong-run child-session evidence", async () => {
    const fixture = await coldFixture("rejected-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const unrelatedDirectory = join(fixture.agentDir, "sessions", "workspace", "unrelated");
    await mkdir(unrelatedDirectory, { recursive: true });
    const unrelated = SessionManager.create(fixture.cwd, unrelatedDirectory, { id: "unrelated-child" });
    unrelated.appendMessage(fauxAssistantMessage("not this run"));
    const startedAt = new Date().toISOString();
    const activity: ExtensionRunActivity = {
      id: "tool", activityId: "activity", runId: "expected-run", toolCallId: "tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: "child-run", label: "worker", status: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const admission = (slot as unknown as {
      childSessionAdmission: { attach: (activity: ExtensionRunActivity, value: unknown) => ExtensionRunActivity };
    }).childSessionAdmission;
    const attach = admission.attach.bind(admission);
    const foreign = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: unrelated.getSessionFile() }],
    });
    expect(foreign.children[0]?.childSessionRef).toBeUndefined();
    const wrongRun = attach(activity, {
      runId: "forged-run",
      results: [{ runId: "child-run", sessionFile: unrelated.getSessionFile() }],
    });
    expect(wrongRun.children[0]?.childSessionRef).toBeUndefined();

    const parentFile = slot.sessionFile!;
    const oversizedDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "expected-run", "run-0");
    await mkdir(oversizedDirectory, { recursive: true });
    const oversizedFile = join(oversizedDirectory, "session.jsonl");
    await writeFile(oversizedFile, `${JSON.stringify({ type: "session", version: 3, id: "oversized-child", timestamp: startedAt, cwd: fixture.cwd })}${" ".repeat(70 * 1_024)}\n`);
    const oversized = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: oversizedFile }],
    });
    expect(oversized.children[0]?.childSessionRef).toBeUndefined();

    const missingParentDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "child-run", "run-missing-parent");
    await mkdir(missingParentDirectory, { recursive: true });
    const missingParent = SessionManager.create(fixture.cwd, missingParentDirectory, { id: "missing-parent-child" });
    missingParent.appendSessionInfo("subagent-worker");
    const missingParentResult = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: missingParent.getSessionFile() }],
    });
    expect(missingParentResult.children[0]?.childSessionRef).toBeUndefined();

    const ordinaryDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "expected-run", "run-ordinary");
    await mkdir(ordinaryDirectory, { recursive: true });
    const ordinary = SessionManager.create(fixture.cwd, ordinaryDirectory, {
      id: "ordinary-child",
      parentSession: parentFile,
    });
    ordinary.appendSessionInfo("ordinary-worker");
    const ordinaryResult = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: ordinary.getSessionFile() }],
    });
    expect(ordinaryResult.children[0]?.childSessionRef).toBeUndefined();
  });
});
