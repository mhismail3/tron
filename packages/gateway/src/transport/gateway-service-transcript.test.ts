import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { CommandReceiptStore } from "./command-receipts.js";
import { DeviceStore } from "../security/device-store.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";

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
  it("passes the exact deleting RPC work token through to RuntimeRegistry", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-service-delete-owner-"));
    const workRegistry = new GatewayWorkRegistry();
    const deleteSession = vi.fn(async (sessionId: string, workToken?: string) => {
      expect(sessionId).toBe("error-session");
      expect(workRegistry.facts()).toContainEqual(expect.objectContaining({
        token: workToken, kind: "rpc-mutation", method: "session.delete", sessionId,
      }));
    });
    const service = new GatewayService({
      config: { tronHome: root },
      sessions: { delete: deleteSession, removeDisplayArtifacts: async () => {} },
      uploads: { removeSession: async () => {} },
      sessionDeleted: () => {},
      receipts: new CommandReceiptStore(root), workRegistry,
    } as unknown as GatewayServiceDependencies);
    try {
      await expect(service.invoke(client, "session.delete", {
        commandId: "delete-error-session", sessionId: "error-session",
      })).resolves.toEqual({ deleted: true });
      expect(deleteSession).toHaveBeenCalledOnce();
      expect(workRegistry.facts()).toEqual([]);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("passes the exact scoped RPC work token into a fresh-session model mutation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-service-model-owner-"));
    const workRegistry = new GatewayWorkRegistry();
    const mutateModel = vi.fn(async (provider: string, modelId: string, workToken?: string) => {
      expect(provider).toBe("anthropic");
      expect(modelId).toBe("claude-opus-4-5-20251101");
      expect(workRegistry.facts()).toContainEqual(expect.objectContaining({
        token: workToken, kind: "rpc-mutation", method: "session.setModel", sessionId: "fresh-session",
      }));
    });
    const service = new GatewayService({
      config: { tronHome: root },
      sessions: { acquire: async () => ({ setModel: mutateModel }) },
      receipts: new CommandReceiptStore(root), workRegistry,
    } as unknown as GatewayServiceDependencies);
    try {
      await expect(service.invoke(client, "session.setModel", {
        commandId: "fresh-session-model-change", sessionId: "fresh-session",
        provider: "anthropic", modelId: "claude-opus-4-5-20251101",
      })).resolves.toEqual({ updated: true });
      expect(mutateModel).toHaveBeenCalledOnce();
      expect(workRegistry.facts()).toEqual([]);
    } finally { await rm(root, { recursive: true, force: true }); }
  });


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

  it("rejects an unsupported method without removing canonical JSONL import", async () => {
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
    await expect(service.invoke(client, "session.import", {
      commandId: "command-2",
      uploadId: "upload-1",
      cwd: "/tmp/project",
    })).resolves.toEqual({ sessionId: "canonical-session" });
    expect(importFromJsonl).toHaveBeenCalledWith("/tmp/session.jsonl", "/tmp/project");
    expect(release).toHaveBeenCalledOnce();
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
    const root = await mkdtemp(join(tmpdir(), "tron-service-subagent-stop-"));
    try {
      const path = join(root, "child.jsonl");
      await writeFile(path, "{}\n");
      const abortSubagentProcess = vi.fn(async () => undefined);
      const slot = {
        id: "parent",
        reconcileProcessChildSessionBinding: vi.fn(async () => {}),
        processChildSessionBinding: () => ({ ref: "child", runId: "run-1" }),
        processChildSessionPath: () => undefined,
        processSubagentAbortAuthority: () => ({ expectedOperationId: "operation-1" }),
        abortSubagentProcess,
      };
      const sessions = {
        isSubscribed: () => true,
        acquire: vi.fn(async () => slot),
        resolveReadOnlySubagentPath: vi.fn(async () => ({ path, fileIdentity: "1:1" })),
        readOnlySubagentTranscriptPage: vi.fn(async () => ({
          items: [], start: 0, end: 0, total: 0, revision: "revision-1", fileIdentity: "1:1",
        })),
      };
      const service = new GatewayService({
        config: { tronHome: root },
        sessions,
        receipts: new CommandReceiptStore(root),
      } as unknown as GatewayServiceDependencies);
      const owner = { ...client, subscriptionToken: () => "subscription-1", sendEvent: vi.fn() };
      const other = { ...client, id: "other-phone", identity: "device:other", subscriptionToken: () => "subscription-2", sendEvent: vi.fn() };

      await expect(service.invoke(owner, "session.processTranscript.open", {
        sessionId: "parent", processId: "process", viewerId: "lease-1", subscriptionToken: "subscription-1",
      })).resolves.toMatchObject({ leaseId: "lease-1", canAbort: true });

      // Only the connection that owns the lease may stop it.
      await expect(service.invoke(other, "session.processTranscript.abort", {
        leaseId: "lease-1", commandId: "other-command",
      })).rejects.toMatchObject({ code: "not_found" });

      await expect(service.invoke(owner, "session.processTranscript.abort", {
        leaseId: "lease-1", commandId: "command-subagent-stop",
      })).resolves.toEqual({ aborted: true });
      expect(abortSubagentProcess).toHaveBeenCalledWith("process", "run-1", "operation-1");
      await expect(service.invoke(owner, "command.status", {
        method: "session.processTranscript.abort", commandId: "command-subagent-stop",
      })).resolves.toMatchObject({ status: "completed", result: { aborted: true } });
    } finally { await rm(root, { recursive: true, force: true }); }
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

  it("rejects live session mutation or terminal creation before session ownership and preserves list-scoped rename", async () => {
    const prompt = vi.fn(async () => ({ queued: false }));
    const rename = vi.fn(async () => {});
    const open = vi.fn();
    const acquire = vi.fn(async () => ({ id: "session", prompt, rename }));
    const execute = vi.fn(async (
      _identity: string,
      _method: string,
      _commandId: string,
      operation: () => Promise<unknown>,
    ) => operation());
    const closedClient = { ...client, isSubscribed: () => false };
    const closedService = new GatewayService({
      sessions: { isSubscribed: () => false, acquire },
      uploads: { materialize: async () => ({ envelope: "", images: [] }) },
      terminals: { open },
      receipts: { execute },
    } as unknown as GatewayServiceDependencies);

    await expect(closedService.invoke(closedClient, "session.prompt", {
      sessionId: "session",
      text: "hello",
      commandId: "command-1",
    })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(closedService.invoke(closedClient, "terminal.open", {
      sessionId: "session",
      columns: 80,
      rows: 24,
      commandId: "command-3",
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(acquire).not.toHaveBeenCalled();
    expect(prompt).not.toHaveBeenCalled();
    expect(open).not.toHaveBeenCalled();

    await expect(closedService.invoke(closedClient, "session.rename", {
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

  it("admits empty resources and rejects mismatched or malformed resource invocations", async () => {
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

    const cases: Array<[string, Record<string, unknown>, boolean]> = [
      ["an empty skill invocation", { commandId: "00000000-0000-4000-8000-000000000007", text: "", uploadIds: [], resourceInvocation: { source: "skill", name: "review", arguments: "" } }, true],
      ["skill text that differs from its arguments", { commandId: "00000000-0000-4000-8000-000000000008", text: "shown", uploadIds: [], resourceInvocation: { source: "skill", name: "review", arguments: "executed" } }, false],
      ["an extension resource with an attachment", { commandId: "00000000-0000-4000-8000-000000000009", text: "", uploadIds: ["upload"], resourceInvocation: { source: "extension", name: "goal", arguments: "" } }, false],
      ["a control character in the arguments", { commandId: "00000000-0000-4000-8000-000000000011", text: "bad\u0000", uploadIds: [], resourceInvocation: { source: "prompt", name: "x", arguments: "bad\u0000" } }, false],
      ["an oversized UTF-8 resource name", { commandId: "00000000-0000-4000-8000-000000000012", text: "x".repeat(200), uploadIds: [], resourceInvocation: { source: "prompt", name: "🙂".repeat(300), arguments: "x".repeat(200) } }, false],
    ];
    for (const [label, request, admitted] of cases) {
      const invocation = service.invoke(client, "session.prompt", { sessionId: "session", ...request });
      if (admitted) await expect(invocation, label).resolves.toEqual({ operationId: "resource-operation" });
      else await expect(invocation, label).rejects.toMatchObject({ code: "invalid_request" });
    }
    // Only the admitted invocation may reach the runtime.
    expect(prompt).toHaveBeenCalledTimes(1);
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

  it("applies absolute attention reads and receipt-backed attention mutations", async () => {
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
});
