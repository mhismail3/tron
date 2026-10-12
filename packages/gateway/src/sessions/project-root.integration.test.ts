import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { GatewayError } from "../errors.js";
import { waitFor } from "../../test-support/wait-for.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import type { RuntimeSlot } from "./runtime-slot.js";

/**
 * The Project layer is the worktree root's `.pi/` (settings-model decision 31),
 * through the Tron-patched SDK's `projectDir`. A real RuntimeRegistry, real Git
 * repository and linked worktree, a faux model and a real stdio MCP server prove
 * that a chat in a subdirectory loads root settings, resources and MCP while its
 * own cwd, tools and nested AGENTS.md stay intact.
 */

// One stdio MCP server per configuration; `where` reports the directory the
// server process was started in.
const SERVER = `
import { writeFileSync } from "node:fs";
import readline from "node:readline";
const [pidPath] = process.argv.slice(2);
writeFileSync(pidPath, String(process.pid));
const send = (message) => process.stdout.write(JSON.stringify(message) + "\\n");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (!("id" in message)) return;
  const result = message.method === "initialize"
    ? { protocolVersion: message.params?.protocolVersion ?? "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "where", version: "1" } }
    : message.method === "tools/list"
      ? { tools: [{ name: "where", description: "Report the server directory", inputSchema: { type: "object", properties: {} } }] }
      : message.method === "tools/call" ? { content: [{ type: "text", text: process.cwd() }] } : {};
  send({ jsonrpc: "2.0", id: message.id, result });
});
`;

function git(cwd: string, ...args: string[]): void {
  const result = spawnSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid" },
  });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr}`);
}

async function writeJson(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
}

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch (error) { return (error as NodeJS.ErrnoException).code !== "ESRCH"; }
}

const session = (slot: RuntimeSlot) => (slot as unknown as { runtime: { session: {
  settingsManager: SettingsManager; systemPrompt: string; getAllTools(): Array<{ name: string }>;
} } }).runtime.session;
const maxRetries = (slot: RuntimeSlot) => session(slot).settingsManager.getRetrySettings().maxRetries;
const mcpTools = (slot: RuntimeSlot) => session(slot).getAllTools().map(({ name }) => name).filter((name) => name.startsWith("mcp__")).sort();
function toolText(slot: RuntimeSlot, toolCallId: string): string {
  const item = slot.snapshot().transcript.find((entry) => entry.kind === "message" && entry.role === "toolResult" && entry.toolCallId === toolCallId);
  return (item?.content ?? []).map((block) => block.type === "text" ? block.text : "").join("").trim();
}

describe.sequential("Project root through the patched Pi SDK", () => {
  const cleanup: Array<() => Promise<void>> = [];
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  afterEach(async () => {
    for (const step of cleanup.splice(0).reverse()) await step();
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  it("loads the worktree root's .pi for a nested chat and keeps the chat's cwd and instructions", async () => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "tron-project-root-")));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const agentDir = join(root, "agent");
    const repo = join(root, "repo");
    const nested = join(repo, "packages", "app");
    const linked = join(root, "linked");
    const plain = join(root, "plain");
    const server = join(root, "where-server.mjs");
    const probe = join(root, "probe.json");
    await Promise.all([mkdir(join(agentDir, "sessions"), { recursive: true }), mkdir(nested, { recursive: true }), mkdir(plain, { recursive: true })]);
    await writeFile(server, SERVER);
    await writeJson(join(agentDir, "mcp.json"), { mcpServers: {} });
    const mcpServer = (name: string) => ({ [name]: { command: process.execPath, args: [server, join(root, `${name}.pid`)], exposure: "direct" } });
    await writeJson(join(repo, ".pi", "settings.json"), { retry: { maxRetries: 7 } });
    await writeJson(join(repo, ".pi", "mcp.json"), { mcpServers: mcpServer("root") });
    await mkdir(join(repo, ".pi", "extensions"), { recursive: true });
    await writeFile(join(repo, ".pi", "extensions", "probe.ts"), `import { writeFileSync } from "node:fs";
export default function (pi) {
  pi.on("session_start", (_event, ctx) => writeFileSync(${JSON.stringify(probe)}, JSON.stringify({ cwd: ctx.cwd, projectDir: ctx.projectDir })));
}
`);
    await writeFile(join(repo, "AGENTS.md"), "ROOT-INSTRUCTIONS-764\n");
    await writeFile(join(nested, "AGENTS.md"), "NESTED-INSTRUCTIONS-764\n");
    await writeJson(join(nested, ".pi", "settings.json"), { retry: { maxRetries: 99 } });
    await writeJson(join(nested, ".pi", "mcp.json"), { mcpServers: mcpServer("nested") });
    await writeJson(join(plain, ".pi", "settings.json"), { retry: { maxRetries: 11 } });
    git(repo, "init", "-q");
    git(repo, "add", "-A");
    git(repo, "commit", "-q", "-m", "fixture");
    git(repo, "worktree", "add", "-q", "-b", "linked", linked);
    await writeJson(join(linked, ".pi", "settings.json"), { retry: { maxRetries: 5 } });
    await writeJson(join(linked, ".pi", "mcp.json"), { mcpServers: {} });
    const linkedNested = join(linked, "packages", "app");

    process.env.PI_CODING_AGENT_DIR = agentDir;
    const trust = new TrustService(agentDir);
    const faux = fauxProvider({ provider: "tron-project-root", tokensPerSecond: 10_000 });
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, maximumLiveRuntimes: 4,
      modelRuntimeFactory, trust, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    cleanup.push(() => registry.dispose());
    await registry.initialize();
    const builtInMaxRetries = SettingsManager.inMemory().getRetrySettings().maxRetries;
    const evidence: Record<string, unknown> = {};

    // Trust is decided for the root: the nested chat asks for the root's decision.
    const undecided = await registry.create(nested).then(() => undefined, (error: unknown) => error);
    expect(undecided).toBeInstanceOf(GatewayError);
    expect((undecided as GatewayError).details).toMatchObject({ cwd: nested, projectDir: repo, requiresDecision: true });
    const decided = await trust.set(nested, true);
    expect(decided).toMatchObject({ cwd: nested, projectDir: repo, savedDecision: true });
    expect((await trust.inspect(repo)).savedDecision).toBe(true);

    const slot = await registry.create(nested);
    expect(slot.cwd).toBe(nested);
    expect(slot.projectDir).toBe(repo);
    expect(maxRetries(slot)).toBe(7);
    expect(session(slot).systemPrompt).toContain("NESTED-INSTRUCTIONS-764");
    expect(session(slot).systemPrompt).toContain("ROOT-INSTRUCTIONS-764");
    expect(JSON.parse(await readFile(probe, "utf8"))).toEqual({ cwd: nested, projectDir: repo });

    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("mcp__root__where", {}, { id: "root-where" }),
        fauxToolCall("bash", { command: "pwd -P" }, { id: "tool-cwd" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    await slot.prompt("where are we");
    await waitFor(() => !slot.isBusy, "the nested chat to settle");
    expect(mcpTools(slot)).toEqual(["mcp__root__where"]);
    expect(toolText(slot, "root-where")).toBe(repo);
    expect(toolText(slot, "tool-cwd")).toBe(nested);
    expect(existsSync(join(root, "nested.pid"))).toBe(false);
    evidence.nested = { cwd: slot.cwd, projectDir: slot.projectDir, maxRetries: 7, mcpTools: mcpTools(slot), mcpServerCwd: repo, toolCwd: nested, nestedAgentsMd: true };

    // An outside edit of the root follows on reload; an edit of the nested .pi does not.
    await writeJson(join(repo, ".pi", "settings.json"), { retry: { maxRetries: 8 } });
    await writeJson(join(repo, ".pi", "mcp.json"), { mcpServers: mcpServer("root2") });
    await writeJson(join(nested, ".pi", "settings.json"), { retry: { maxRetries: 50 } });
    await slot.reload();
    expect(maxRetries(slot)).toBe(8);
    await waitFor(() => mcpTools(slot).join() === "mcp__root2__where", "the edited root MCP server");
    evidence.outsideEdit = { maxRetries: 8, mcpTools: mcpTools(slot), nestedEditIgnored: true };

    // A linked worktree is its own Project: its own decision and its own values.
    const linkedUndecided = await registry.create(linkedNested).then(() => undefined, (error: unknown) => error);
    expect((linkedUndecided as GatewayError).details).toMatchObject({ projectDir: linked, requiresDecision: true });
    await trust.set(linkedNested, true);
    const linkedSlot = await registry.create(linkedNested);
    expect(linkedSlot.projectDir).toBe(linked);
    expect(maxRetries(linkedSlot)).toBe(5);
    expect(maxRetries(slot)).toBe(8);
    evidence.linkedWorktree = { projectDir: linked, maxRetries: 5, mainChatMaxRetries: 8 };

    // Outside a repository the chat's cwd is its Project, as before.
    await trust.set(plain, true);
    const plainSlot = await registry.create(plain);
    expect(plainSlot.projectDir).toBe(plain);
    expect(maxRetries(plainSlot)).toBe(11);
    evidence.standalone = { cwd: plain, projectDir: plain, maxRetries: 11 };

    // Revoking the root's trust reloads the nested chat without project settings or MCP.
    const rootServer = Number(await readFile(join(root, "root2.pid"), "utf8"));
    await trust.setAndApply(nested, false,
      (inspection) => registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false),
      (inspection) => registry.commitProjectReload(inspection.projectDir));
    expect((await trust.inspect(repo)).savedDecision).toBe(false);
    expect(maxRetries(slot)).toBe(builtInMaxRetries);
    expect(mcpTools(slot)).toEqual([]);
    await waitFor(() => !alive(rootServer), "the root MCP server to stop");
    expect(maxRetries(linkedSlot)).toBe(5);
    evidence.untrustedRoot = { maxRetries: builtInMaxRetries, mcpTools: [], rootServerStopped: true, linkedWorktreeUnaffected: true };

    const artifact = join(process.cwd(), "test-results", "project-root-864.json");
    await mkdir(dirname(artifact), { recursive: true });
    await writeFile(artifact, `${JSON.stringify(evidence, null, 2)}\n`);
  }, 60_000);
});
