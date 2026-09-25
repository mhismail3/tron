import { describe, expect, it } from "vitest";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createTronCoreExtension, tronContext, withWorkspaceHandoff } from "./tron-core-extension.js";

const descriptor = { root: "/test/tron/workspace", available: true };
function fixture() {
  const handlers = new Map<string, (...args: any[]) => any>();
  createTronCoreExtension({ describe: async () => descriptor })({
    on: (event: string, handler: (...args: any[]) => any) => { handlers.set(event, handler); },
    getActiveTools: () => ["read", "subagent"],
  } as unknown as ExtensionAPI);
  return handlers;
}

describe("Tron operating context", () => {
  it("keeps cwd separate, quotes paths, gates tool guidance, and provides unavailable facts", () => {
    const text = tronContext(descriptor, "/projects/one\nquoted", ["read"]);
    expect(text).toContain('"/projects/one\\nquoted"');
    expect(text).toContain(descriptor.root);
    expect(text).not.toContain("Use display");
    expect(text).not.toContain("Use notify");
    expect(text).not.toContain("Use ask_user");
    const all = tronContext(descriptor, "/project", ["display", "notify", "ask_user", "subagent"]);
    expect(all).toContain("source.kind=internal_file");
    expect(all).toContain("workflowScript/workflowScriptPath");
    expect(tronContext({ ...descriptor, available: false }, "/project", [])).toContain("Do not recreate");
  });

  it.each([
    { agent: "worker", task: "Read only", context: "fresh" },
    { agent: "worker", task: "Read only", context: "fork" },
    { agent: "codex-exec", task: "Read only" },
    { action: "resume", id: "run-id", message: "Read only" },
  ])("hands off workspace facts through supported direct task/resume input", async input => {
    const original = structuredClone(input);
    await fixture().get("tool_call")!({ toolName: "subagent", input });
    const text = "task" in input ? input.task : input.message;
    expect(text).toContain(descriptor.root);
    expect(text).toContain("Keep the working directory supplied by your launcher");
    expect(text).toContain("Use only tools actually supplied");
    expect(text).toMatch(/Read only$/);
    expect(input.context).toEqual("context" in original ? original.context : undefined);
  });

  it("does not rewrite workflow programs, management requests, or other tools", async () => {
    for (const input of [
      { workflowScript: 'return await runs.run("child", {agent:"worker", task:"review"});' },
      { workflowScriptPath: "workflow.js" },
      { action: "list" },
      { action: "update", agent: "worker", config: { task: "keep" } },
    ]) {
      const original = structuredClone(input);
      await fixture().get("tool_call")!({ toolName: "subagent", input });
      expect(input).toEqual(original);
    }
    const input = { agent: "worker", task: "unchanged" };
    await fixture().get("tool_call")!({ toolName: "other", input });
    expect(input.task).toBe("unchanged");
  });

  it("bounds the added handoff without truncating user content", () => {
    const task = "ü".repeat(600_000);
    expect(withWorkspaceHandoff(task, descriptor).endsWith(task)).toBe(true);
    expect(Buffer.byteLength(withWorkspaceHandoff("", descriptor))).toBeLessThanOrEqual(2_048);
    expect(() => withWorkspaceHandoff("unchanged", { root: "/" + "x".repeat(2_048), available: true }))
      .toThrow("2 KiB bound");
  });

  it("refreshes a prior handoff without accumulating or truncating the task", () => {
    const task = "ü".repeat(10_000);
    const first = withWorkspaceHandoff(task, descriptor);
    const second = withWorkspaceHandoff(first, { ...descriptor, available: false });
    expect(second.match(/\[Tron workspace handoff\]/g)).toHaveLength(1);
    expect(second).toContain("unavailable; do not recreate");
    expect(second.endsWith(task)).toBe(true);
  });
});
