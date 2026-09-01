import { describe, expect, it, vi } from "vitest";
import type { WorkspaceInspectionService } from "../machine/workspace-inspection-service.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

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
};

describe("Gateway workspace inspection dispatch", () => {
  it("advertises the session-bound capability", () => {
    const service = new GatewayService({
      config: { machineId: "machine", machineName: "Mac", tronHome: "/tmp/tron-workspace-capability" },
      sessions: {},
    } as unknown as GatewayServiceDependencies);
    expect((service.info() as { capabilities: string[] }).capabilities).toContain("workspace-inspector.v1");
  });

  it("derives every workspace root from the subscribed runtime slot", async () => {
    const inspect = vi.fn(async () => ({ root: "/authoritative", revision: "revision" }));
    const list = vi.fn(async () => ({ root: "/authoritative", path: "", revision: "listing", entries: [] }));
    const file = vi.fn(async () => ({ blobId: "blob", name: "a.txt", mimeType: "text/plain", size: 1, revision: "file" }));
    const diff = vi.fn(async () => ({ path: "a.txt", patch: "", binary: false, truncated: false, revision: "diff" }));
    const historyList = vi.fn(async () => ({ commits: [], revision: "history" }));
    const historyGet = vi.fn(async () => ({ oid: "a".repeat(40), changes: [], revision: "detail" }));
    const workspaceInspector = { inspect, list, file, diff, historyList, historyGet } as unknown as WorkspaceInspectionService;
    const service = new GatewayService({
      config: { machineId: "machine", machineName: "Mac", tronHome: "/tmp/tron-workspace-dispatch" },
      sessions: {
        isSubscribed: (clientID: string, sessionID: string) => clientID === "phone" && sessionID === "session",
        acquire: async () => ({ cwd: "/authoritative" }),
      },
      workspaceInspector,
    } as unknown as GatewayServiceDependencies);

    await service.invoke(client, "session.workspace.inspect", { sessionId: "session" });
    await service.invoke(client, "session.workspace.list", { sessionId: "session" });
    await service.invoke(client, "session.workspace.file", { sessionId: "session", path: "a.txt" });
    await service.invoke(client, "session.workspace.git.diff", { sessionId: "session", path: "a.txt", scope: "staged" });
    await service.invoke(client, "session.workspace.git.history.list", { sessionId: "session", scope: "allReferences", limit: 20 });
    await service.invoke(client, "session.workspace.git.history.get", { sessionId: "session", oid: "a".repeat(40) });

    expect(inspect).toHaveBeenCalledWith("/authoritative");
    expect(list).toHaveBeenCalledWith("/authoritative", undefined);
    expect(file).toHaveBeenCalledWith("/authoritative", "a.txt");
    expect(diff).toHaveBeenCalledWith("/authoritative", "a.txt", "staged");
    expect(historyList).toHaveBeenCalledWith("/authoritative", "phone", "allReferences", undefined, 20);
    expect(historyGet).toHaveBeenCalledWith("/authoritative", "a".repeat(40));
  });

  it("rejects reads without an established session subscription", async () => {
    const service = new GatewayService({
      config: { machineId: "machine", machineName: "Mac", tronHome: "/tmp/tron-workspace-rejection" },
      sessions: { isSubscribed: () => false },
      workspaceInspector: {} as WorkspaceInspectionService,
    } as unknown as GatewayServiceDependencies);
    await expect(service.invoke(client, "session.workspace.inspect", { sessionId: "session" }))
      .rejects.toMatchObject({ code: "invalid_request" });
  });
});
