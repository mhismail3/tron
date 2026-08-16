import { describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client: ClientContext = {
  id: "phone",
  identity: "device:test",
  isLocal: false,
  beginSynchronization: () => "sync",
  establishSynchronization: () => {},
  completeSynchronization: () => {},
  unsubscribe: () => true,
  attachTerminal: () => {},
  detachTerminal: () => {},
  ownsTerminal: () => false,
};

describe("session transcript paging", () => {
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
    })).resolves.toEqual({
      items: [{ id: "entry", type: "message", role: "user", text: "earlier" }],
      start: 0,
      end: 1,
      total: 1,
    });
    expect(acquire).toHaveBeenCalledWith("session");
    expect(transcriptPage).toHaveBeenCalledWith(1, "next");

    const closedService = new GatewayService({
      sessions: { isSubscribed: () => false, acquire },
    } as unknown as GatewayServiceDependencies);
    await expect(closedService.invoke(client, "session.transcript", {
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

    await expect(closedService.invoke(client, "session.prompt", {
      sessionId: "session",
      text: "hello",
      commandId: "command-1",
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(acquire).not.toHaveBeenCalled();
    expect(prompt).not.toHaveBeenCalled();

    await expect(closedService.invoke(client, "session.rename", {
      sessionId: "session",
      name: "Dashboard rename",
      commandId: "command-2",
    })).resolves.toEqual({ updated: true });
    expect(rename).toHaveBeenCalledWith("Dashboard rename");
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
    const service = new GatewayService({
      sessions: {
        importFromJsonl: async () => ({ id: "imported" }),
        delete: async () => {},
      },
      uploads: {
        prepareSessionImport: async () => "/owned/import.jsonl",
        remove,
        removeSession,
      },
      receipts: { execute },
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
    expect(removeSession).toHaveBeenCalledWith("deleted");
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

    await expect(service.invoke(client, "terminal.open", {
      sessionId: "session",
      columns: 80,
      rows: 24,
      commandId: "command-1",
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(acquire).not.toHaveBeenCalled();
    expect(open).not.toHaveBeenCalled();
  });
});
