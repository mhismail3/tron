import { spawnSync } from "node:child_process";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { HomeTaskReportOwner } from "../kernel/delegation/task-report.js";
import { NotificationGrantStore } from "../notifications/grant-store.js";
import { NotificationService } from "../notifications/notification-service.js";
import { PushRelayClient } from "../notifications/relay-client.js";
import { startLockGateway, type LockClient, type LockGateway, type LockGatewayOptions, type ProviderRequestRecord } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockUpdateRequested, type TraceValue } from "../../test-support/scenario-lock.js";
import { awaitsWithin } from "../../test-support/wait-for.js";

/**
 * Model-visible session shapes (#2279): what the model receives for each kind of
 * session the Gateway runs, recorded once here so the behavior locks need not pin
 * it. For each shape: the declared tool names in order, the system-prompt section
 * headings and a hash of the normalized prompt text; and for the requests whose
 * text the product writes itself (the compaction summary prompts and the task
 * worker's report reminder), the messages too.
 *
 * Shapes: a plain chat; a chat with an extension tool; a chat with push
 * notifications (the `notify` tool) with and without an extension; a chat with
 * automations (the `schedule` tool); a Home task worker (`checkin`, `report`) and
 * its reminder turn; a trusted project subdirectory chat (project context, the
 * root's skill and extension) and the same chat after trust is revoked; and a
 * manual compaction's two summary requests. Tron Home's own prompts stay in
 * `home-activation-wake`.
 *
 * It is the `gateway/pi-sdk` module's scenario lock beside the SDK behavior trace:
 * intended prompt or tool changes update it with `TRON_UPDATE_LOCKS=gateway/pi-sdk`.
 */

const GOLDEN = resolve(process.cwd(), "test-fixtures", "pi-sdk", "session-shapes.golden.json");
const gateways: LockGateway[] = [];
const releases: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const release of releases.splice(0).reverse()) await release();
  await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose()));
});

const SELECT_TOOL = { name: "lock-select.ts", source: `
  export default function (pi) {
    pi.registerTool({
      name: "lock_select", label: "Lock select", description: "Ask the user which lock path to take",
      parameters: { type: "object", properties: {} },
      execute: async (_id, _params, _signal, _update, ctx) => {
        const answer = await ctx.ui.select("Choose a lock path", ["Keep", "Change"]);
        return { content: [{ type: "text", text: "chosen: " + (answer ?? "cancelled") }], details: { answer: answer ?? null } };
      },
    });
  }
` };
const BACKGROUND_TOOL = { name: "lock-background.ts", source: `
  import { mkdirSync, writeFileSync } from "node:fs";
  import { join } from "node:path";
  export default function (pi) {
    pi.registerTool({
      name: "lock_background", label: "Lock background", description: "Start the lock's background run",
      parameters: { type: "object", properties: {} },
      execute: async (_id, _params, _signal, _update, ctx) => {
        const runId = "lock-background-run";
        const asyncDir = join(ctx.cwd, ".pi", "subagents", "async-subagent-runs", runId);
        mkdirSync(asyncDir, { recursive: true });
        writeFileSync(join(asyncDir, "status.json"), JSON.stringify({ runId, state: "running", startedAt: Date.now(), lastUpdate: Date.now() }));
        return { content: [{ type: "text", text: "Background run started." }], details: { runId, asyncDir, state: "running" } };
      },
    });
  }
` };

/** The shape of one provider request: no messages unless the product writes them. */
const shape = (request: ProviderRequestRecord, messages = false): TraceValue => ({
  tools: [...request.tools], promptSections: [...request.promptSections], promptHash: request.promptHash,
  ...(messages ? { messages: request.messages as TraceValue[] } : {}),
});

/** A Gateway whose chat answers one prompt; returns that request's shape. */
async function chatShape(name: string, options: LockGatewayOptions = {}): Promise<TraceValue> {
  const gateway = await startLockGateway(name, options);
  gateways.push(gateway);
  const phone = await gateway.connect("phone");
  const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  await attach(phone, sessionId);
  gateway.script([() => fauxAssistantMessage("Shape recorded.")]);
  expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId, text: "record the shape" })).ok).toBe(true);
  await gateway.settled(sessionId);
  const requests = gateway.record().providerRequests;
  expect(requests).toHaveLength(1);
  return shape(requests[0]!);
}

/** Open and sync a session as a phone does before prompting. */
async function attach(phone: LockClient, sessionId: string): Promise<void> {
  const opened = await phone.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
}

/** The production notification owner over an always-accepting relay. */
const withNotifications = (relayOrigin = "https://relay.lock.invalid") => async (tronHome: string) => {
  const service = new NotificationService(new NotificationGrantStore(tronHome),
    new PushRelayClient(relayOrigin, async () => new Response(JSON.stringify({ status: "accepted_by_apns" }), { status: 200 }) as never),
    Date.now, () => {}, () => {}, () => {}, () => false);
  await service.initialize();
  releases.push(async () => service.dispose());
  return service;
};

async function write(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, text);
}

describe("gateway/pi-sdk session shapes", () => {
  it("session-shapes: what the model receives for each kind of session", async () => {
    const shapes: Record<string, TraceValue> = {};
    shapes.chat = await chatShape("session-shape-chat");
    shapes.chatWithExtensionSelect = await chatShape("session-shape-select", { extensions: [SELECT_TOOL] });
    shapes.chatWithExtensionBackground = await chatShape("session-shape-background", { extensions: [BACKGROUND_TOOL] });
    shapes.chatWithNotificationsSelect = await chatShape("session-shape-notify-select", { extensions: [SELECT_TOOL], notifications: withNotifications() });
    shapes.chatWithNotificationsBackground = await chatShape("session-shape-notify-background", { extensions: [BACKGROUND_TOOL], notifications: withNotifications() });
    shapes.chatWithAutomations = await chatShape("session-shape-automations", { automations: true });

    // A Home task worker, admitted as the dispatcher admits it, with no report: its
    // turn, then the reminder turn the product writes.
    {
      const gateway = await startLockGateway("session-shape-worker", { extensions: [SELECT_TOOL], notifications: withNotifications() });
      gateways.push(gateway);
      gateway.script([() => fauxAssistantMessage("Worker reply without a report."), () => fauxAssistantMessage("Worker still has no report.")]);
      const operationId = "task-shape-operation";
      const report = new HomeTaskReportOwner({ taskId: "shape-task", homeId: "shape-home", generation: 1, operationId }, async () => {});
      const dispatch = gateway.registry.delegation;
      const lease = await dispatch.createWorker(gateway.cwd, report);
      const terminal = new Promise<unknown>((resolve) => {
        void lease.slot.prompt("do the lock task", [], undefined, undefined, undefined, {
          operationId, signal: report.signal, origin: { kind: "gateway", ownerId: "shape-task", title: "Home task", confidence: "boundary" },
          onTerminal: resolve,
        });
      });
      await awaitsWithin(terminal, "the task worker's terminal");
      await dispatch.acknowledge(lease.slot.id, operationId, lease);
      report.retire();
      await gateway.settled(lease.slot.id);
      const requests = gateway.record().providerRequests;
      expect(requests).toHaveLength(2);
      shapes.taskWorker = shape(requests[0]!);
      shapes.taskWorkerReminder = shape(requests[1]!, true);
    }

    // A chat in the subdirectory of a trusted Git project: the root's Project layer
    // (skill, extension, instructions) reaches the prompt; after revoking trust it does not.
    {
      const gateway = await startLockGateway("session-shape-project");
      gateways.push(gateway);
      const root = await realpath(gateway.root);
      const project = join(root, "project");
      const nested = join(project, "packages", "app");
      const probe = (tool: string) => `
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
      await write(join(project, ".pi", "settings.json"), `${JSON.stringify({ retry: { maxRetries: 7 }, compaction: { reserveTokens: 4_096, keepRecentTokens: 240 }, skills: ["../lock-skills"] })}\n`);
      await write(join(project, ".pi", "extensions", "root-probe.ts"), probe("project_probe"));
      await write(join(project, "lock-skills", "root-lock-skill", "SKILL.md"), skill("root-lock-skill", "The project root's lock skill"));
      await write(join(project, "AGENTS.md"), "ROOT-INSTRUCTIONS: the project root's AGENTS.md.\n");
      await write(join(nested, ".pi", "settings.json"), `${JSON.stringify({ retry: { maxRetries: 9 }, compaction: { reserveTokens: 8_192, keepRecentTokens: 480 }, skills: ["../nested-skills"] })}\n`);
      await write(join(nested, ".pi", "extensions", "nested-probe.ts"), probe("nested_probe"));
      await write(join(nested, "nested-skills", "nested-lock-skill", "SKILL.md"), skill("nested-lock-skill", "A subdirectory skill that must not load"));
      await write(join(nested, "AGENTS.md"), "NESTED-INSTRUCTIONS: the subdirectory's AGENTS.md.\n");
      const git = spawnSync("git", ["-C", project, "init", "-q"], { encoding: "utf8", env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" } });
      expect(git.status, git.stderr).toBe(0);
      const phone = await gateway.connect("phone");
      const trust = (value: boolean) => phone.request("settings.change", {
        commandId: gateway.commandId(), target: { kind: "global" }, reason: "Trust decision for the shape project",
        changes: [{ key: "permissions.projectTrust", layer: "global", op: "set", value, qualifiers: { project: nested } }],
      });
      expect((await trust(true)).ok).toBe(true);
      const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: nested });
      expect(created.ok, JSON.stringify(created)).toBe(true);
      const sessionId = created.result.sessionId as string;
      await attach(phone, sessionId);
      gateway.script([() => fauxAssistantMessage("Trusted shape."), () => fauxAssistantMessage("Revoked shape.")]);
      expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId, text: "where does this chat run?" })).ok).toBe(true);
      await gateway.settled(sessionId);
      expect((await trust(false)).ok).toBe(true);
      expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId, text: "and after revoking trust?" })).ok).toBe(true);
      await gateway.settled(sessionId);
      const requests = gateway.record().providerRequests;
      expect(requests).toHaveLength(2);
      shapes.trustedProjectSubdirectory = shape(requests[0]!);
      shapes.revokedProjectSubdirectory = shape(requests[1]!);
    }

    // A manual compaction: the summary of the cut history, then the prefix of the split turn.
    {
      const gateway = await startLockGateway("session-shape-compaction");
      gateways.push(gateway);
      const phone = await gateway.connect("phone");
      const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
      const sessionId = created.result.sessionId as string;
      await attach(phone, sessionId);
      const long = "lock context ".repeat(80);
      gateway.script([
        () => fauxAssistantMessage(`First answer. ${long}`),
        () => fauxAssistantMessage(`Second answer. ${long}`),
        () => fauxAssistantMessage("Summary: two answered turns about the lock context."),
        () => fauxAssistantMessage("Turn prefix: the second question."),
      ]);
      for (const text of ["first question", "second question"]) {
        expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId, text })).ok).toBe(true);
        await gateway.settled(sessionId);
      }
      expect((await phone.request("session.compact", { commandId: gateway.commandId(), sessionId })).ok).toBe(true);
      const requests = gateway.record().providerRequests;
      expect(requests).toHaveLength(4);
      shapes.compactionSummary = shape(requests[2]!, true);
      shapes.compactionTurnPrefix = shape(requests[3]!, true);
    }

    await compareWithGolden({
      module: "gateway/pi-sdk", goldenPath: GOLDEN,
      actualPath: resolve(process.cwd(), "test-results", "session-shapes.actual.json"),
      diffPath: resolve(process.cwd(), "test-results", "session-shapes.diff"),
      trace: { lock: "session-shapes", shapes }, update: lockUpdateRequested("gateway/pi-sdk"),
      validate: () => { expect(Object.keys(shapes)).toHaveLength(12); },
    });
  }, 120_000);
});
