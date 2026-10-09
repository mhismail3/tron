import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { EpisodicSessionSource, EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { HomeMemory, homeMemoryToolUnavailable } from "./home-memory.js";
import { homeMemoryTools, type HomeMemoryToolDetails } from "./home-memory-tools.js";

/*
 * The failure modes of Home's memory tools that a real activation cannot reach,
 * because an unconfigured or unopened memory refuses every activation before any
 * provider request: no faux model can call a tool against one. Here the same
 * registered tool definitions and a real `HomeMemory` are used directly, so the
 * typed answers are the owner's own state, not a stub's.
 *
 * Everything else (the zoom/date/search answers themselves, the bounds, the
 * placeholders and the omissions) is covered end to end by
 * `sessions/home-memory-tools.e2e.test.ts`.
 */

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(workspaces.splice(0).map((workspace) => workspace.dispose()));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

const summarizer: EpisodicSummarizer = async () => {
  throw new Error("this fixture never compacts");
};
/** These fixtures never open a store, so no chapter is read. */
const unreadSource: EpisodicSessionSource = {
  read: async function* () { throw new Error("this fixture never reads a chapter"); },
  branchAtCursor: async function* () { throw new Error("this fixture never reads a chapter"); },
};

/** A Home memory with no open store: `configure` records the configuration, and
 * the store opens only for a session file that exists. */
async function memory(sessionFile: () => Promise<string | undefined>): Promise<HomeMemory> {
  const root = await mkdtemp(join(tmpdir(), "tron-home-tools-unit-"));
  roots.push(root);
  const workspace = new TronWorkspace(join(root, "tron"));
  workspaces.push(workspace);
  await mkdir(join(root, "sessions"), { recursive: true });
  return new HomeMemory({ sessionId: "session-1", workspace, sessionFile, sessionSource: unreadSource, modelSummarizer: () => ({ summarizer }) });
}

const missing = async () => undefined;

type Tool = ReturnType<typeof homeMemoryTools>[number];

/** Call one registered tool the way the agent loop does, and read what the model
 * would see. */
async function callTool(tools: Tool[], name: string, args: Record<string, unknown>): Promise<{ text: string; details: HomeMemoryToolDetails | undefined; isError: boolean }> {
  const tool = tools.find((candidate) => candidate.name === name);
  expect(tool, name).toBeDefined();
  const result = await (tool as unknown as {
    execute: (...call: unknown[]) => Promise<{ content: Array<{ text: string }>; details: HomeMemoryToolDetails }>;
  }).execute("call-1", args, undefined, undefined, undefined);
  return { text: result.content.map((part) => part.text).join(""), details: result.details, isError: false };
}

describe("Home memory tools", () => {
  it("answers a typed unavailable result, never a throw, when no memory is there", async () => {
    // The session is not the enabled Home: the Home owner answers no memory at
    // all, and every tool says so instead of reading something else's memory.
    const tools = homeMemoryTools(() => undefined);
    for (const [name, args] of [["zoom", { id: 0, n: 1 }], ["date", { id: 0 }], ["memory_search", { query: "x" }]] as const) {
      const answer = await callTool(tools, name, args);
      expect(answer.details, name).toEqual({ status: "unavailable", reason: "not-home-session" });
      expect(answer.text, name).toContain("not Tron Home");
    }
  });

  it("answers the memory's own state for a memory that is not configured or not open", async () => {
    // No configuration at all (decision D4: there are no defaults).
    const unconfigured = await memory(missing);
    const unconfiguredTools = homeMemoryTools(() => unconfigured);
    for (const [name, args] of [["zoom", { id: 0, n: 1 }], ["date", { id: 0 }], ["memory_search", { query: "" }]] as const) {
      const answer = await callTool(unconfiguredTools, name, args);
      // The state of the memory is the answer even for a query the tool would
      // otherwise refuse: a memory that cannot serve anything must not look like a
      // badly spelled request.
      expect(answer.details, name).toEqual({ status: "unavailable", reason: "memory-not-configured" });
      expect(answer.text, name).toBe(homeMemoryToolUnavailable("memory-not-configured").text);
    }

    // Configured, but the store is not open: configuration is recorded for a
    // session that has no canonical file yet, and a tool call never opens it.
    const unopened = await memory(missing);
    await unopened.configure({ model: { provider: "p", id: "m" } });
    expect(unopened.open).toBe(false);
    const answer = await callTool(homeMemoryTools(() => unopened), "zoom", { id: 0, n: 1 });
    expect(answer.details).toEqual({ status: "unavailable", reason: "memory-unavailable" });
    expect(answer.text).toBe(homeMemoryToolUnavailable("memory-unavailable").text);

    await unconfigured.dispose();
    await unopened.dispose();
  });
});
