import { spawnSync } from "node:child_process";
import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, getCurrentSystemPrompt } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";

/**
 * Project-root lock (restructure plan §6.4, V3; K-0 §7 E0e) guarding the Pi seam
 * slice E2 (`kernel/pi`) at the `projectDir` patch call sites (K-0 §4 patch
 * item 1): a chat whose cwd is a subdirectory of a Git project, through the real
 * Gateway over a loopback WebSocket (`gateway-lock-harness.ts`).
 *
 * The scenario records, with the root and the subdirectory each carrying a
 * `.pi/` and an `AGENTS.md`:
 * - trust inspection resolves the subdirectory to the root and asks for a
 *   decision (`trust.inspect`), and `session.create` refuses until one exists;
 * - the decision a client makes for the subdirectory is saved for the root;
 * - the chat keeps its own cwd while its Project layer is the root's: root
 *   settings resolve for the chat, the root's skill and extension tool reach the
 *   provider request and the subdirectory's do not, both instruction files are
 *   in the prompt, and the extension sees `cwd` and `projectDir` apart.
 * `project-root.integration.test.ts` covers reload, linked worktrees, MCP and
 * revocation at the registry; this lock pins what clients and the model see.
 */

const MODULE = "gateway/session-catalog";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

function git(cwd: string, ...args: string[]): void {
  const result = spawnSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" },
  });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr}`);
}

async function write(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, text);
}

/** A project extension whose tool reports where the SDK says the chat is. */
const probeExtension = (tool: string) => `
export default function (pi) {
  pi.registerTool({
    name: ${JSON.stringify(tool)}, label: "Project probe", description: "Report the chat's cwd and Project root",
    parameters: { type: "object", properties: {} },
    execute: async (_id, _params, _signal, _update, ctx) => ({
      content: [{ type: "text", text: "cwd=" + ctx.cwd + " projectDir=" + ctx.projectDir }], details: {},
    }),
  });
}
`;

const skill = (name: string, description: string) => `---\nname: ${name}\ndescription: ${description}\n---\n\nFollow ${name}.\n`;

describe("gateway/session-catalog project-root lock", () => {
  it("projectDir: a subdirectory chat of a trusted Git project loads the root's Project layer and keeps its cwd", async () => {
    const gateway = await startLockGateway("project-root-trust");
    gateways.push(gateway);
    // Trust and the SDK name canonical paths; the temp root is a symlink on macOS.
    const root = await realpath(gateway.root);
    const project = join(root, "project");
    const nested = join(project, "packages", "app");
    await write(join(project, ".pi", "settings.json"), `${JSON.stringify({ retry: { maxRetries: 7 }, skills: ["../lock-skills"] })}\n`);
    await write(join(project, ".pi", "extensions", "root-probe.ts"), probeExtension("project_probe"));
    await write(join(project, "lock-skills", "root-lock-skill", "SKILL.md"), skill("root-lock-skill", "The project root's lock skill"));
    await write(join(project, "AGENTS.md"), "ROOT-INSTRUCTIONS: the project root's AGENTS.md.\n");
    await write(join(nested, ".pi", "settings.json"), `${JSON.stringify({ retry: { maxRetries: 99 }, skills: ["../nested-skills"] })}\n`);
    await write(join(nested, ".pi", "extensions", "nested-probe.ts"), probeExtension("nested_probe"));
    await write(join(nested, "nested-skills", "nested-lock-skill", "SKILL.md"), skill("nested-lock-skill", "A subdirectory skill that must not load"));
    await write(join(nested, "AGENTS.md"), "NESTED-INSTRUCTIONS: the subdirectory's AGENTS.md.\n");
    git(project, "init", "-q");

    const phone = await gateway.connect("phone");
    let systemPrompt = "";
    gateway.script([
      (context) => {
        systemPrompt = getCurrentSystemPrompt(context.messages) ?? "";
        return fauxAssistantMessage([fauxToolCall("project_probe", {}, { id: "lock-project-probe" })], { stopReason: "toolUse" });
      },
      () => fauxAssistantMessage("The chat runs in the subdirectory of the trusted project."),
    ]);

    const undecided = await phone.request("trust.inspect", { cwd: nested });
    const refused = await phone.request("session.create", { commandId: gateway.commandId(), cwd: nested });
    const decided = await phone.request("settings.change", {
      commandId: gateway.commandId(), target: { kind: "mac" }, reason: "Trust the lock project",
      changes: [{ key: "permissions.projectTrust", layer: "mac", op: "set", value: true, qualifiers: { project: nested } }],
    });
    const rootInspection = await phone.request("trust.inspect", { cwd: project });
    const nestedInspection = await phone.request("trust.inspect", { cwd: nested });
    const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: nested });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    const opened = await phone.request("session.open", { sessionId });
    expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
    const chatSettings = await phone.request("settings.resolve", { target: { kind: "session", sessionId }, keys: ["run.retry.maxRetries"] });
    const projectSettings = await phone.request("settings.resolve", { target: { kind: "project", cwd: nested }, keys: ["run.retry.maxRetries", "permissions.projectTrust"] });
    expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId, text: "where does this chat run?" })).ok).toBe(true);
    await gateway.settled(sessionId);
    const transcript = await phone.request("session.transcript", { sessionId });

    const recorded = gateway.record();
    const trace = {
      lock: "project-root-trust",
      exchanges: recorded.exchanges,
      events: recorded.events,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(sessionId),
      // The trust store is keyed by path; normalization rewrites values, so list its entries.
      files: { trust: normalizeTraceValue(Object.entries(JSON.parse(await readFile(join(gateway.agentDir, "trust.json"), "utf8")))
        .map(([path, trusted]) => ({ path, trusted })), gateway.normalization) },
      // The prompt hash already covers the whole text; these name what it must hold.
      observed: Object.fromEntries(["root-lock-skill", "nested-lock-skill", "ROOT-INSTRUCTIONS", "NESTED-INSTRUCTIONS"]
        .map((marker) => [marker, systemPrompt.includes(marker)])),
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        const [projectDir, cwd] = [project, nested].map((path) => path.split(root).join("<tmp>"));
        expect(undecided.result).toMatchObject({ projectDir: project, requiresDecision: true, effectiveDecision: null });
        expect(refused.error).toMatchObject({ code: "trust_required" });
        expect(decided.ok, JSON.stringify(decided)).toBe(true);
        expect(rootInspection.result).toMatchObject({ projectDir: project, savedDecision: true });
        expect(nestedInspection.result).toMatchObject({ cwd: nested, projectDir: project, savedDecision: true });
        expect(JSON.stringify(chatSettings.result)).toContain('"value":7');
        expect(transcript.ok).toBe(true);
        expect(trace.observed).toEqual({ "root-lock-skill": true, "nested-lock-skill": false, "ROOT-INSTRUCTIONS": true, "NESTED-INSTRUCTIONS": true });
        const first = recorded.providerRequests[0]!;
        expect(first.tools).toContain("project_probe");
        expect(first.tools).not.toContain("nested_probe");
        const messages = JSON.stringify(recorded.providerRequests[1]!.messages);
        expect(messages).toContain(`cwd=${cwd} projectDir=${projectDir}`);
        expect(trace.files.trust).toContainEqual({ path: projectDir, trusted: true });
      },
    });
  });
});
