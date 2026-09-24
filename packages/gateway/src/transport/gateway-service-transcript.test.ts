import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { CommandReceiptStore } from "./command-receipts.js";
import { DeviceStore } from "../security/device-store.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";

const client: ClientContext = {
  id: "phone",
  identity: "device:test",
  isLocal: false,
  beginSynchronization: () => "sync",
  establishSynchronization: () => {},
  completeSynchronization: () => {},
  setPresentationVisibility: (_sessionId, _token, revision, visible) => ({ revision, visible }),
  unsubscribe: () => true,
  attachTerminal: () => {},
  detachTerminal: () => {},
  ownsTerminal: () => false,
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
};

describe("session transcript paging", () => {
  it("resolves knowledge receipt references after supporting evidence is forgotten", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-service-knowledge-erasure-"));
    const workspace = new TronWorkspace(root);
    try {
      const store = new KnowledgeStore(workspace);
      const source = await store.captureSource({ commandId: "service-erasure-source", record: { kind: "source", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Evidence", text: "private fixture", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" } } });
      const request = { commandId: "service-erasure-note", record: { kind: "note" as const, scope: "personal" as const, provenance: { actor: "agent" as const, evidence: [{ recordId: source.record.id, revisionId: source.record.revisionId }] }, relations: [], content: { title: "Derived", body: "private fixture", role: "fact" as const, confirmed: false } } };
      const service = new GatewayService({ config: { tronHome: root }, sessions: {}, receipts: new CommandReceiptStore(root), knowledge: new KnowledgeService(store, { admit() {}, dispose() {} }), updateService: {}, iosDeviceInstallService: {}, gitWorktrees: {}, workspaceInspector: {}, providerUsage: {} } as unknown as GatewayServiceDependencies);
      const first = await service.invoke(client, "knowledge.note.create", request);
      expect(JSON.stringify(first)).toContain("private fixture");
      await service.invoke(client, "knowledge.forget", { commandId: "service-erasure-forget", recordId: source.record.id, reason: "fixture erasure", expectedRevision: source.record.revisionId });
      const status = await service.invoke(client, "command.status", { method: "knowledge.note.create", commandId: request.commandId });
      const replay = await service.invoke(client, "knowledge.note.create", request);
      expect(JSON.stringify(status)).not.toContain("private fixture");
      expect(JSON.stringify(replay)).not.toContain("private fixture");
    } finally { await workspace.dispose(); await rm(root, { recursive: true, force: true }); }
  });
  it("replays thumbnail refresh receipts without rerunning a no-image operation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-service-preview-receipt-"));
    const workspace = new TronWorkspace(root);
    try {
      const store = new KnowledgeStore(workspace);
      const source = await store.captureSource({ commandId: "preview-receipt-source", record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "No preview", text: "body", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" } } });
      const service = new GatewayService({ config: { tronHome: root }, sessions: {}, receipts: new CommandReceiptStore(root), knowledge: new KnowledgeService(store, { admit() {}, dispose() {} }), updateService: {}, iosDeviceInstallService: {}, gitWorktrees: {}, workspaceInspector: {}, providerUsage: {} } as unknown as GatewayServiceDependencies);
      const request = { commandId: "preview-receipt-command", sourceId: source.record.id, expectedRevision: source.record.revisionId };
      const first = await service.invoke(client, "knowledge.source.preview.refresh", request);
      const second = await service.invoke(client, "knowledge.source.preview.refresh", request);
      expect(second).toEqual(first);
      expect(first).toMatchObject({ status: "unavailable", reason: "Source has no safe URL for preview refresh." });
      expect((await store.read(source.record.id))?.revisionId).toBe(source.record.revisionId);
    } finally { await workspace.dispose(); await rm(root, { recursive: true, force: true }); }
  });

  it("publishes durable self-revocation before install cleanup and preserves idempotence", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-service-revoke-"));
    let releaseCleanup: (() => void) | undefined;
    let revoke: Promise<unknown> | undefined;
    try {
      const devices = new DeviceStore(root, "machine");
      await devices.initialize();
      const enrollment = await devices.ensureEnrollment();
      const paired = await devices.pair(enrollment.code, "Phone");
      const cleanupGate = new Promise<void>((resolve) => { releaseCleanup = resolve; });
      const removeDevice = vi.fn(async () => cleanupGate);
      const published = vi.fn();
      const service = new GatewayService({
        config: { tronHome: root },
        devices,
        sessions: {},
        receipts: new CommandReceiptStore(root),
        iosDeviceInstallService: { removeDevice, isUsable: false } as never,
      } as unknown as GatewayServiceDependencies);

      revoke = service.invoke({ ...client, identity: paired.deviceId, revokeDevice: published }, "device.revoke", {
        deviceId: paired.deviceId,
        commandId: "revoke-command-1",
      });
      await vi.waitFor(() => expect(removeDevice).toHaveBeenCalledOnce());
      expect(published).toHaveBeenCalledOnce();
      expect(JSON.parse(await readFile(join(root, "gateway", "devices.json"), "utf8")).devices).toEqual([]);
      expect(await devices.authenticateAndAdmit(paired.token, (identity) => identity)).toBeNull();
      releaseCleanup();
      await expect(revoke).resolves.toEqual({ revoked: true });

      await expect(service.invoke({ ...client, identity: paired.deviceId }, "device.revoke", {
        deviceId: paired.deviceId,
        commandId: "revoke-command-2",
      })).resolves.toEqual({ revoked: false });
      expect(removeDevice).toHaveBeenCalledOnce();
      expect(published).toHaveBeenCalledOnce();
    } finally {
      releaseCleanup?.();
      try { if (revoke) await revoke; }
      finally { await rm(root, { recursive: true, force: true }); }
    }
  });

  it("does not recreate an auth owner after runtime resolution loses device authority", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-service-auth-revoke-"));
    let releaseRuntime: (() => void) | undefined;
    let begin: Promise<unknown> | undefined;
    try {
      const devices = new DeviceStore(root, "machine");
      await devices.initialize();
      const enrollment = await devices.ensureEnrollment();
      const paired = await devices.pair(enrollment.code, "Phone");
      let enterRuntime!: () => void;
      const runtimeEntered = new Promise<void>((resolve) => { enterRuntime = resolve; });
      const runtimeGate = new Promise<void>((resolve) => { releaseRuntime = resolve; });
      const authStart = vi.fn(() => ({ operationId: "operation", recovered: false }));
      const service = new GatewayService({
        config: { tronHome: root },
        devices,
        sessions: {
          acquire: async () => {
            enterRuntime();
            await runtimeGate;
            return { modelRuntime: {} };
          },
        },
        auth: { start: authStart },
      } as unknown as GatewayServiceDependencies);

      begin = service.invoke({ ...client, identity: paired.deviceId }, "auth.begin", {
        providerId: "provider",
        authType: "api_key",
        sessionId: "session",
      });
      await runtimeEntered;
      await devices.revoke(paired.deviceId, () => {});
      releaseRuntime();
      await expect(begin).rejects.toMatchObject({ code: "unauthenticated" });
      begin = undefined;
      expect(authStart).not.toHaveBeenCalled();
    } finally {
      releaseRuntime?.();
      try { if (begin) await begin; }
      finally { await rm(root, { recursive: true, force: true }); }
    }
  });

  it("removes retired legacy RPCs without removing canonical JSONL import", async () => {
    const importFromJsonl = vi.fn(async () => ({ id: "canonical-session" }));
    const release = vi.fn(async () => {});
    const service = new GatewayService({
      config: {
        machineId: "machine",
        machineGroupID: "group",
        machineName: "Mac",
        tronHome: "/tmp/tron-legacy-retirement",
      },
      receipts: {
        execute: async (_identity: string, _method: string, _commandID: string, operation: () => Promise<unknown>) => operation(),
      },
      uploads: {
        prepareSessionImport: async () => ({ path: "/tmp/session.jsonl", release }),
        remove: vi.fn(async () => {}),
      },
      sessions: { importFromJsonl },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "legacy.inspect", {})).rejects.toMatchObject({ code: "not_found" });
    await expect(service.invoke(client, "legacy.import", { commandId: "command-1" })).rejects.toMatchObject({ code: "not_found" });
    await expect(service.invoke(client, "session.import", {
      commandId: "command-2",
      uploadId: "upload-1",
      cwd: "/tmp/project",
    })).resolves.toEqual({ sessionId: "canonical-session" });
    expect(importFromJsonl).toHaveBeenCalledWith("/tmp/session.jsonl", "/tmp/project");
    expect(release).toHaveBeenCalledOnce();
  });

  it("routes exact mobile presentation visibility through connection ownership", async () => {
    const setPresentationVisibility = vi.fn((_sessionId, _token, revision: number, visible: boolean) => ({
      revision,
      visible,
    }));
    const service = new GatewayService({
      sessions: {},
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke({ ...client, setPresentationVisibility }, "session.presentation.set", {
      sessionId: "session",
      subscriptionToken: "subscription",
      revision: 7,
      visible: true,
    })).resolves.toEqual({ revision: 7, visible: true });
    expect(setPresentationVisibility).toHaveBeenCalledWith("session", "subscription", 7, true);
  });

  it("advertises independent process and scalable upload-status capabilities", () => {
    const service = new GatewayService({
      config: {
        machineId: "machine",
        machineGroupID: "group",
        machineName: "Mac",
        tronHome: "/tmp/tron-process-capabilities",
      },
      sessions: {},
    } as unknown as GatewayServiceDependencies);

    const capabilities = (service.info() as { capabilities: string[] }).capabilities;
    expect(capabilities).toEqual(expect.arrayContaining([
      "process-activity.v1",
      "process-history.v1",
      "process-transcript.v2",
      "process-transcript-abort.v1",
      "uploads-status.v2",
      "session-export.v2",
      "display-artifacts.v1",
      "browser-live-view.v1",
    ]));
    expect(capabilities).not.toContain("uploads-status.v1");
  });

  it("routes bounded unified process history through an established parent session", async () => {
    const processHistory = vi.fn(() => ({ activities: [], historyRevision: "revision" }));
    const processDetail = vi.fn(() => ({
      version: 1,
      processId: "process:command:test",
      kind: "command",
      executionMode: "foreground",
      source: "mainAssistant",
      lifecycle: { version: 1, state: "completed", attention: "none", sequence: 0, observedAt: "2026-01-01T00:00:00.000Z", terminalAt: "2026-01-01T00:00:00.000Z" },
      visibility: "historical",
      title: "Command",
      outputTruncated: false,
    }));
    const acquire = vi.fn(async () => ({ processHistory, processDetail }));
    const service = new GatewayService({
      sessions: { isSubscribed: () => true, acquire },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "session.processHistory.list", {
      sessionId: "session",
      limit: 25,
      kind: "command",
    })).resolves.toEqual({ activities: [], historyRevision: "revision" });
    expect(processHistory).toHaveBeenCalledWith(undefined, 25, { kind: "command" });

    await expect(service.invoke(client, "session.processHistory.get", {
      sessionId: "session",
      processId: "process:command:test",
      historyRevision: "revision",
    })).resolves.toEqual({ activity: expect.objectContaining({ kind: "command" }) });
    expect(processDetail).toHaveBeenCalledWith("process:command:test", "revision");
  });

  it("routes subagent stop only through the exact connection-owned transcript lease", async () => {
    const abortOwned = vi.fn(async () => undefined);
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const service = new GatewayService({
      sessions: {},
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);
    Object.assign(service as unknown as Record<string, unknown>, {
      processTranscriptLeases: { abortOwned },
    });

    await expect(service.invoke(client, "session.processTranscript.abort", {
      leaseId: "lease-1",
      commandId: "command-subagent-stop",
    })).resolves.toEqual({ aborted: true });
    expect(abortOwned).toHaveBeenCalledWith("phone", "lease-1");
    expect(execute).toHaveBeenCalledWith(
      "device:test",
      "session.processTranscript.abort",
      "command-subagent-stop",
      expect.any(Function),
    );
  });

  it("returns a bounded page only for an established subscription without creating ownership", async () => {
    const transcriptPage = vi.fn(() => ({
      items: [{ id: "entry", type: "message", role: "user", text: "earlier" }],
      start: 0,
      end: 1,
      total: 1,
    }));
    const acquire = vi.fn(async () => ({ transcriptPage }));
    const service = new GatewayService({
      sessions: { isSubscribed: () => true, acquire },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "session.transcript", {
      sessionId: "session",
      before: 1,
      expectedNextEntryId: "next",
      expectedRuntimeGeneration: "runtime",
      expectedLeafEntryId: "leaf",
    })).resolves.toEqual({
      items: [{ id: "entry", type: "message", role: "user", text: "earlier" }],
      start: 0,
      end: 1,
      total: 1,
    });
    expect(acquire).toHaveBeenCalledWith("session");
    expect(transcriptPage).toHaveBeenCalledWith(1, "next", "runtime", "leaf");

    const closedService = new GatewayService({
      sessions: { isSubscribed: () => false, acquire },
    } as unknown as GatewayServiceDependencies);
    await expect(closedService.invoke({ ...client, isSubscribed: () => false }, "session.transcript", {
      sessionId: "session",
      before: 1,
    })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("rejects live mutation before session ownership and preserves list-scoped rename", async () => {
    const prompt = vi.fn(async () => ({ queued: false }));
    const rename = vi.fn(async () => {});
    const acquire = vi.fn(async () => ({ id: "session", prompt, rename }));
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const closedService = new GatewayService({
      sessions: { isSubscribed: () => false, acquire },
      uploads: { materialize: async () => ({ envelope: "", images: [] }) },
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);

    await expect(closedService.invoke({ ...client, isSubscribed: () => false }, "session.prompt", {
      sessionId: "session",
      text: "hello",
      commandId: "command-1",
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(acquire).not.toHaveBeenCalled();
    expect(prompt).not.toHaveBeenCalled();

    await expect(closedService.invoke({ ...client, isSubscribed: () => false }, "session.rename", {
      sessionId: "session",
      name: "Dashboard rename",
      commandId: "command-2",
    })).resolves.toEqual({ updated: true });
    expect(rename).toHaveBeenCalledWith("Dashboard rename");
  });

  it("passes bounded upload descriptors into prompt projection without bytes", async () => {
    const descriptor = {
      id: "upload:00000000-0000-4000-8000-000000000001",
      name: "notes.txt", mimeType: "text/plain", size: 4,
    };
    const prompt = vi.fn(async () => ({ operationId: "operation" }));
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const service = new GatewayService({
      sessions: {
        isSubscribed: () => true,
        retainLiveSession: () => () => {},
        acquire: async () => ({ id: "session", prompt }),
      },
      uploads: {
        materialize: async () => ({
          envelope: '<attachment name="notes.txt" />',
          images: [],
          photoCount: 0,
          fileAttachmentCount: 1,
          attachments: [descriptor],
        }),
      },
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session",
      text: "review",
      uploadIds: ["upload"],
      commandId: "00000000-0000-4000-8000-000000000002",
    })).resolves.toEqual({ operationId: "operation" });
    expect(prompt).toHaveBeenCalledWith(
      'review\n\n<attachment name="notes.txt" />',
      [],
      undefined,
      expect.objectContaining({ attachmentCount: 1, attachments: [descriptor] }),
      expect.any(Function),
    );
  });

  it("validates selected resources and preserves literal command arguments", async () => {
    const prompt = vi.fn(async () => ({ operationId: "skill-operation" }));
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const commands = vi.fn(() => [
      { name: "skill:review", source: "skill" },
      { name: "goal", source: "extension" },
    ]);
    const service = new GatewayService({
      sessions: {
        isSubscribed: () => true,
        retainLiveSession: () => () => {},
        acquire: async () => ({ id: "session", prompt, commands }),
      },
      uploads: {
        materialize: async () => ({ envelope: "", images: [], photoCount: 0, fileAttachmentCount: 0, attachments: [] }),
      },
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session",
      text: "Inspect this change",
      resourceInvocation: { source: "skill", name: "review", arguments: "Inspect this change" },
      commandId: "00000000-0000-4000-8000-000000000003",
    })).resolves.toEqual({ operationId: "skill-operation" });
    expect(prompt).toHaveBeenCalledWith(
      "/skill:review Inspect this change",
      [],
      undefined,
      expect.objectContaining({ text: "Inspect this change" }),
      expect.any(Function),
    );

    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session",
      text: "Inspect this change",
      resourceInvocation: { source: "skill", name: "retired", arguments: "Inspect this change" },
      commandId: "00000000-0000-4000-8000-000000000004",
    })).rejects.toMatchObject({ code: "conflict", retryable: false });
    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session",
      text: "",
      resourceInvocation: { source: "skill", name: "review", arguments: "" },
      commandId: "00000000-0000-4000-8000-000000000005",
    })).resolves.toEqual({ operationId: "skill-operation" });
    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session",
      text: "/goal\tvalue",
      commandId: "00000000-0000-4000-8000-000000000013",
    })).resolves.toEqual({ operationId: "skill-operation" });
    expect(prompt).toHaveBeenCalledWith("/goal\tvalue", [], undefined, expect.anything(), expect.any(Function));

    commands.mockReturnValue([
      { name: "skill:review", source: "skill" },
      { name: "skill:review", source: "extension" },
    ]);
    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session",
      text: "Inspect this change",
      resourceInvocation: { source: "skill", name: "review", arguments: "Inspect this change" },
      commandId: "00000000-0000-4000-8000-000000000006",
    })).rejects.toMatchObject({ code: "conflict", retryable: false });
    expect(prompt).toHaveBeenCalledTimes(3);
  });

  it("admits empty resources, rejects mismatched text, and rejects extension attachments", async () => {
    const prompt = vi.fn(async () => ({ operationId: "resource-operation" }));
    const execute = vi.fn(async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation());
    const commands = vi.fn(() => [
      { name: "skill:review", source: "skill" },
      { name: "goal", source: "extension" },
    ]);
    const service = new GatewayService({
      sessions: { isSubscribed: () => true, retainLiveSession: () => () => {}, acquire: async () => ({ id: "session", prompt, commands }) },
      uploads: { materialize: async () => ({ envelope: "", images: [], photoCount: 0, fileAttachmentCount: 1, attachments: [{ id: "upload", name: "a.txt", mimeType: "text/plain", size: 1 }] }) },
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session", text: "", uploadIds: [],
      resourceInvocation: { source: "skill", name: "review", arguments: "" },
      commandId: "00000000-0000-4000-8000-000000000007",
    })).resolves.toEqual({ operationId: "resource-operation" });
    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session", text: "shown", uploadIds: [],
      resourceInvocation: { source: "skill", name: "review", arguments: "executed" },
      commandId: "00000000-0000-4000-8000-000000000008",
    })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session", text: "", uploadIds: ["upload"],
      resourceInvocation: { source: "extension", name: "goal", arguments: "" },
      commandId: "00000000-0000-4000-8000-000000000009",
    })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("rejects invalid resource controls and oversized UTF-8 names", async () => {
    const service = new GatewayService({
      sessions: { isSubscribed: () => true, retainLiveSession: () => () => {}, acquire: async () => ({ id: "session", prompt: vi.fn(), commands: vi.fn(() => []) }) },
      uploads: { materialize: async () => ({ envelope: "", images: [], photoCount: 0, fileAttachmentCount: 0, attachments: [] }) },
      receipts: { execute: vi.fn(async (_a: string, _b: string, _c: string, operation: () => Promise<unknown>) => operation()) },
    } as unknown as GatewayServiceDependencies);
    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session", text: "x", uploadIds: [],
      resourceInvocation: { source: "prompt", name: "x", arguments: "bad\u0000" },
      commandId: "00000000-0000-4000-8000-000000000011",
    })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(service.invoke(client, "session.prompt", {
      sessionId: "session", text: "x".repeat(200), uploadIds: [],
      resourceInvocation: { source: "prompt", name: "🙂".repeat(300), arguments: "x".repeat(200) },
      commandId: "00000000-0000-4000-8000-000000000012",
    })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("rejects terminal control until this connection attaches", async () => {
    const write = vi.fn();
    const resize = vi.fn();
    const terminate = vi.fn();
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const service = new GatewayService({
      terminals: { write, resize, terminate },
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);

    for (const [method, params] of [
      ["terminal.write", { terminalId: "terminal", writeId: "write", data: "echo", commandId: "command-1" }],
      ["terminal.resize", { terminalId: "terminal", columns: 80, rows: 24, commandId: "command-2" }],
      ["terminal.terminate", { terminalId: "terminal", commandId: "command-3" }],
    ] as const) {
      await expect(service.invoke(client, method, params)).rejects.toMatchObject({ code: "invalid_request" });
    }
    expect(write).not.toHaveBeenCalled();
    expect(resize).not.toHaveBeenCalled();
    expect(terminate).not.toHaveBeenCalled();

    const attached = { ...client, ownsTerminal: (terminalId: string) => terminalId === "terminal" };
    await expect(service.invoke(attached, "terminal.write", {
      terminalId: "terminal", writeId: "write", data: "echo", commandId: "command-4",
    })).resolves.toEqual({ written: true });
    expect(write).toHaveBeenCalledWith("terminal", "write", "echo");
  });

  it("post-success upload cleanup cannot make import or deletion ambiguous", async () => {
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const remove = vi.fn(async () => { throw new Error("cleanup failed"); });
    const removeSession = vi.fn(async () => { throw new Error("cleanup failed"); });
    const removeDisplayArtifacts = vi.fn(async () => { throw new Error("cleanup failed"); });
    const releaseImport = vi.fn(async () => {});
    const sessionDeleted = vi.fn();
    const service = new GatewayService({
      sessions: {
        importFromJsonl: async () => ({ id: "imported" }),
        delete: async () => {},
        removeDisplayArtifacts,
      },
      uploads: {
        prepareSessionImport: async () => ({
          path: "/owned/import.jsonl",
          release: releaseImport,
        }),
        remove,
        removeSession,
      },
      receipts: { execute },
      sessionDeleted,
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "session.import", {
      uploadId: "00000000-0000-0000-0000-000000000001",
      cwd: "/workspace",
      commandId: "command-1",
    })).resolves.toEqual({ sessionId: "imported" });
    await expect(service.invoke(client, "session.delete", {
      sessionId: "deleted",
      commandId: "command-2",
    })).resolves.toEqual({ deleted: true });
    expect(remove).toHaveBeenCalled();
    expect(releaseImport).toHaveBeenCalledTimes(1);
    expect(sessionDeleted).toHaveBeenCalledWith("deleted");
    expect(removeSession).toHaveBeenCalledWith("deleted");
    expect(removeDisplayArtifacts).toHaveBeenCalledWith("deleted");
  });

  it("releases bounded import staging after a definitive import failure", async () => {
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const releaseImport = vi.fn(async () => {});
    const remove = vi.fn(async () => {});
    const service = new GatewayService({
      sessions: {
        importFromJsonl: async () => { throw new Error("invalid import"); },
      },
      uploads: {
        prepareSessionImport: async () => ({
          path: "/owned/import.jsonl",
          release: releaseImport,
        }),
        remove,
      },
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "session.import", {
      uploadId: "00000000-0000-0000-0000-000000000001",
      cwd: "/workspace",
      commandId: "command-failed-import",
    })).rejects.toThrow("invalid import");
    expect(releaseImport).toHaveBeenCalledTimes(1);
    expect(remove).not.toHaveBeenCalled();
  });

  it("joins the attention barrier before snapshotting an open revision", async () => {
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    let reconciled = false;
    const snapshot = vi.fn(() => ({ sessionId: "session", revision: 2 }));
    const slot = {
      id: "session",
      reconcileAttention: vi.fn(async () => { await barrier; reconciled = true; }),
      snapshot: vi.fn(() => {
        expect(reconciled).toBe(true);
        return snapshot();
      }),
    };
    const service = new GatewayService({
      sessions: {
        acquire: vi.fn(async () => slot),
        attentionProjection: vi.fn(() => ({ completionRevision: 7, attentionRevision: 7, isUnread: true })),
      },
      logger: { log: vi.fn() },
    } as unknown as GatewayServiceDependencies);

    let settled = false;
    const open = service.invoke(client, "session.open", { sessionId: "session" }).then((value) => {
      settled = true;
      return value;
    });
    await Promise.resolve();
    expect(settled).toBe(false);
    expect(snapshot).not.toHaveBeenCalled();
    release();
    await expect(open).resolves.toMatchObject({ completionRevision: 7 });
    expect(snapshot).toHaveBeenCalledTimes(1);
  });

  it("serializes absolute attention mutations and stale-safe open acknowledgements", async () => {
    const setAttention = vi.fn(async (_sessionId: string, unread: boolean, through?: number) => ({
      completionRevision: 4, attentionRevision: 8, isUnread: unread || (through ?? 0) < 4,
    }));
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const service = new GatewayService({
      sessions: { setAttention },
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "session.attention.read", {
      sessionId: "session", throughCompletionRevision: 3,
    })).resolves.toMatchObject({ isUnread: true });
    await expect(service.invoke(client, "session.attention.set", {
      sessionId: "session", unread: false, throughCompletionRevision: 4, commandId: "command-read",
    })).resolves.toMatchObject({ isUnread: false });
    await expect(service.invoke(client, "session.attention.set", {
      sessionId: "session", unread: true, throughCompletionRevision: 4, commandId: "command-unread",
    })).resolves.toMatchObject({ isUnread: true });
    expect(execute).toHaveBeenCalledTimes(2);
    expect(setAttention).toHaveBeenNthCalledWith(1, "session", false, 3);
  });

  it("rejects terminal creation before the client opens the session", async () => {
    const acquire = vi.fn();
    const open = vi.fn();
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const service = new GatewayService({
      sessions: { isSubscribed: () => false, acquire },
      terminals: { open },
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke({ ...client, isSubscribed: () => false }, "terminal.open", {
      sessionId: "session",
      columns: 80,
      rows: 24,
      commandId: "command-1",
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(acquire).not.toHaveBeenCalled();
    expect(open).not.toHaveBeenCalled();
  });
});
