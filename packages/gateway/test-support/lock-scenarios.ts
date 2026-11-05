import { spawnSync } from "node:child_process";
import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fauxAssistantMessage, fauxThinking, fauxToolCall, getCurrentSystemPrompt } from "@earendil-works/pi-ai";
import { expect } from "vitest";
import { awaitsWithin, waitFor } from "./wait-for.js";
import { HomeTaskReportOwner } from "../src/kernel/delegation/task-report.js";
import { NotificationGrantStore } from "../src/notifications/grant-store.js";
import { NotificationService } from "../src/notifications/notification-service.js";
import { PushRelayClient } from "../src/notifications/relay-client.js";
import { startLockGateway, type LockClient, type LockGateway, type LockGatewayOptions } from "./gateway-lock-harness.js";
import { homeOwnerOf } from "./gateway-registry.js";
import type { TraceValue } from "./scenario-lock.js";

/**
 * Lock scenarios shared by the behavior lock that owns each one and by
 * `client-event-schemas.lock`, which runs the scenarios that together reach every
 * client event payload shape the phone decodes. A scenario drives the real
 * Gateway (`gateway-lock-harness.ts`) and returns what its owner asserts; it
 * asserts only that its own steps were admitted.
 */

export interface LockSession {
  readonly gateway: LockGateway;
  readonly client: LockClient;
  readonly sessionId: string;
  prompt(text: string, extra?: Record<string, unknown>): Promise<{ ok: boolean; result?: any; error?: any }>;
}

/** A Gateway with one opened and synced chat, as the phone holds it. The caller disposes the Gateway. */
export async function openLockSession(name: string, options?: LockGatewayOptions): Promise<LockSession> {
  const gateway = await startLockGateway(name, options);
  try {
    const client = await gateway.connect("phone");
    const created = await client.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    const opened = await client.request("session.open", { sessionId });
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
    return {
      gateway, client, sessionId,
      prompt: (text, extra = {}) => client.send("session.prompt", { commandId: gateway.commandId(), sessionId, text, ...extra }),
    };
  } catch (error) {
    await gateway.dispose();
    throw error;
  }
}

/** One prompt streams thinking, text and a tool round trip. Returns once the run settled. */
export async function promptStreamScenario(session: LockSession): Promise<{ admitted: { ok: boolean; result?: any } }> {
  session.gateway.script([
    async () => {
      await session.gateway.observeLiveOperation(session.client, session.sessionId);
      return fauxAssistantMessage([
        fauxThinking("Reading the lock notes."),
        { type: "text", text: "Reading notes." },
        fauxToolCall("read", { path: "notes.txt" }, { id: "lock-read" }),
      ], { stopReason: "toolUse" });
    },
    () => fauxAssistantMessage("The notes say: lock notes."),
  ]);
  const admitted = await session.prompt("read the notes");
  expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
  await session.gateway.settled(session.sessionId);
  return { admitted };
}

/** Two long turns, then a manual compaction: the summary of the cut history and the split turn's prefix. */
export async function compactionScenario(session: LockSession): Promise<{ compacted: { ok: boolean; result?: any } }> {
  const long = "lock context ".repeat(80);
  session.gateway.script([
    async () => {
      await session.gateway.observeLiveOperation(session.client, session.sessionId);
      return fauxAssistantMessage(`First answer. ${long}`);
    },
    () => fauxAssistantMessage(`Second answer. ${long}`),
    // A manual compaction asks for the summary of the cut history, then for the
    // prefix of the split turn the recent tail keeps.
    () => fauxAssistantMessage("Summary: two answered turns about the lock context."),
    () => fauxAssistantMessage("Turn prefix: the second question."),
  ]);
  expect((await session.prompt("first question")).ok).toBe(true);
  await session.gateway.settled(session.sessionId);
  expect((await session.prompt("second question")).ok).toBe(true);
  await session.gateway.settled(session.sessionId);
  const compacted = await session.client.request("session.compact", { commandId: session.gateway.commandId(), sessionId: session.sessionId });
  expect(compacted.ok, JSON.stringify(compacted)).toBe(true);
  return { compacted };
}

/** A gate a scripted provider step holds until the test opens it. */
export function gate(): { opened: Promise<void>; open(): void; reached: Promise<void>; reach(): void } {
  let open = (): void => {};
  let reach = (): void => {};
  const opened = new Promise<void>((resolve) => { open = resolve; });
  const reached = new Promise<void>((resolve) => { reach = resolve; });
  return { opened, open: () => open(), reached, reach: () => reach() };
}

/** A provider step that holds until the request is aborted. */
export function untilAborted(reached: () => void) {
  return async (_context: unknown, options: { signal?: AbortSignal } | undefined) => {
    reached();
    await new Promise<void>((resolve) => {
      const signal = options?.signal;
      if (!signal || signal.aborted) { resolve(); return; }
      signal.addEventListener("abort", () => resolve(), { once: true });
    });
    return fauxAssistantMessage("Aborted turn response.");
  };
}

export interface QueueState { queueRevision: number; queuedItems: Array<{ id: string; behavior: string; text: string }> }


/**
 * `run-queue-control`: three follow-ups queue behind a held run and a retried
 * command id replays; queue edits refuse a stale revision and an unknown item, then
 * reorder and drop; an abort naming a queued item is refused; a second held run's
 * follow-ups are cleared; a third run is stopped with a steer queued.
 */
export async function queueControlScenario(session: LockSession) {
  const { gateway, client: phone, sessionId } = session;
  const slot = await gateway.registry.acquire(sessionId);
  const queue = (): QueueState => {
    const snapshot = slot.snapshot() as unknown as QueueState;
    return { queueRevision: snapshot.queueRevision, queuedItems: snapshot.queuedItems.map(({ id, behavior, text }) => ({ id, behavior, text })) };
  };
  const queued = (count: number, label: string) => waitFor(() => queue().queuedItems.length === count ? queue() : undefined, label);
  const prompt = (text: string, extra: Record<string, unknown> = {}, commandId = gateway.commandId()) =>
    phone.send("session.prompt", { commandId, sessionId, text, ...extra });

  const first = gate();
  const second = gate();
  let thirdReached!: () => void;
  const third = new Promise<void>((resolve) => { thirdReached = resolve; });
  gateway.script([
    async () => { await gateway.observeLiveOperation(phone, sessionId); first.reach(); await first.opened; return fauxAssistantMessage("Held run settled."); },
    () => fauxAssistantMessage("Third follow-up answered."),
    () => fauxAssistantMessage("First follow-up answered."),
    async () => { second.reach(); await second.opened; return fauxAssistantMessage("Second held run settled."); },
    untilAborted(() => thirdReached()),
    () => fauxAssistantMessage("Stopped steer answered."),
  ]);

  // 1. Three follow-ups queue behind a held run; a retried command id replays.
  const held = await prompt("hold the first run open");
  expect(held.ok, JSON.stringify(held)).toBe(true);
  await awaitsWithin(first.reached, "the first held provider request");
  const retriedCommand = gateway.commandId();
  const followUps = [
    await prompt("first follow-up", { behavior: "followUp" }),
    await prompt("second follow-up", { behavior: "followUp" }, retriedCommand),
    await prompt("third follow-up", { behavior: "followUp" }),
  ];
  for (const response of followUps) expect(response.ok, JSON.stringify(response)).toBe(true);
  const retried = prompt("second follow-up", { behavior: "followUp" }, retriedCommand);
  const queuedThree = await queued(3, "three queued follow-ups");

  // 2. Edits: a stale revision and an unknown item are refused; then reorder and drop.
  const [one, two, three] = queuedThree.queuedItems;
  const staleEdit = await phone.request("session.queue.replace", {
    commandId: gateway.commandId(), sessionId, expectedRevision: queuedThree.queueRevision - 1, items: [three, one],
  });
  const unknownEdit = await phone.request("session.queue.replace", {
    commandId: gateway.commandId(), sessionId, expectedRevision: queuedThree.queueRevision,
    items: [three, { ...one!, id: "lock-unknown-queue-item" }],
  });
  const edited = await phone.request("session.queue.replace", {
    commandId: gateway.commandId(), sessionId, expectedRevision: queuedThree.queueRevision, items: [three, one],
  });
  expect(edited.ok, JSON.stringify(edited)).toBe(true);
  const afterEdit = queue();
  const wrongAbort = await phone.request("session.abort", { commandId: gateway.commandId(), sessionId, operationId: two!.id });

  // 3. The held run ends; the edited queue reaches the model in order.
  first.open();
  await gateway.settled(sessionId);
  const retriedResponse = await retried;

  // 4. A second held run: its follow-ups are cleared before they are delivered.
  expect((await prompt("hold the second run open")).ok).toBe(true);
  await awaitsWithin(second.reached, "the second held provider request");
  expect((await prompt("cleared follow-up one", { behavior: "followUp" })).ok).toBe(true);
  expect((await prompt("cleared follow-up two", { behavior: "followUp" })).ok).toBe(true);
  await queued(2, "two follow-ups to clear");
  const cleared = await phone.request("session.clearQueue", { commandId: gateway.commandId(), sessionId });
  expect(cleared.ok, JSON.stringify(cleared)).toBe(true);
  const afterClear = queue();
  second.open();
  await gateway.settled(sessionId);

  // 5. A third run is stopped with a steer queued: the steer becomes the next turn.
  const stoppable = await prompt("hold a run to stop");
  expect(stoppable.ok).toBe(true);
  await awaitsWithin(third, "the abortable provider request");
  expect((await prompt("steer queued at stop", { behavior: "steer" })).ok).toBe(true);
  const beforeStop = await queued(1, "the steer to queue");
  const stopped = await phone.request("session.abort", { commandId: gateway.commandId(), sessionId, operationId: stoppable.result.operationId });
  expect(stopped.ok, JSON.stringify(stopped)).toBe(true);
  await gateway.settled(sessionId);
  const finalQueue = queue();
  const transcript = await phone.request("session.transcript", { sessionId });
  return { queuedThree, staleEdit, unknownEdit, afterEdit, wrongAbort, retriedResponse, followUps, afterClear, beforeStop, finalQueue, transcript };
}

function projectGit(cwd: string, ...args: string[]): void {
  const result = spawnSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" },
  });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr}`);
}

async function writeProjectFile(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, text);
}

/** A project extension whose tool reports where the SDK says the chat is. */
export const probeExtension = (tool: string) => `
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

export const projectSkill = (name: string, description: string) => `---\nname: ${name}\ndescription: ${description}\n---\n\nFollow ${name}.\n`;


/**
 * `project-root-trust`: a chat in the subdirectory of a trusted Git project, each
 * level carrying `.pi/` and `AGENTS.md`; trust is decided for the subdirectory,
 * the chat runs a tool round trip, then trust is revoked and the chat answers again.
 */
export async function projectRootTrustScenario(gateway: LockGateway) {
  // Trust and the SDK name canonical paths; the temp root is a symlink on macOS.
  const root = await realpath(gateway.root);
  const project = join(root, "project");
  const nested = join(project, "packages", "app");
  await writeProjectFile(join(project, ".pi", "settings.json"), `${JSON.stringify({ retry: { maxRetries: 7 }, compaction: { reserveTokens: 4_096, keepRecentTokens: 240 }, skills: ["../lock-skills"] })}\n`);
  await writeProjectFile(join(project, ".pi", "extensions", "root-probe.ts"), probeExtension("project_probe"));
  await writeProjectFile(join(project, "lock-skills", "root-lock-skill", "SKILL.md"), projectSkill("root-lock-skill", "The project root's lock skill"));
  await writeProjectFile(join(project, "AGENTS.md"), "ROOT-INSTRUCTIONS: the project root's AGENTS.md.\n");
  await writeProjectFile(join(nested, ".pi", "settings.json"), `${JSON.stringify({ retry: { maxRetries: 9 }, compaction: { reserveTokens: 8_192, keepRecentTokens: 480 }, skills: ["../nested-skills"] })}\n`);
  await writeProjectFile(join(nested, ".pi", "extensions", "nested-probe.ts"), probeExtension("nested_probe"));
  await writeProjectFile(join(nested, "nested-skills", "nested-lock-skill", "SKILL.md"), projectSkill("nested-lock-skill", "A subdirectory skill that must not load"));
  await writeProjectFile(join(nested, "AGENTS.md"), "NESTED-INSTRUCTIONS: the subdirectory's AGENTS.md.\n");
  projectGit(project, "init", "-q");

  const phone = await gateway.connect("phone");
  let systemPrompt = "";
  gateway.script([
    async (context) => {
      await gateway.observeLiveOperation(phone, sessionId);
      systemPrompt = getCurrentSystemPrompt(context.messages) ?? "";
      return fauxAssistantMessage([fauxToolCall("project_probe", {}, { id: "lock-project-probe" })], { stopReason: "toolUse" });
    },
    () => fauxAssistantMessage("The chat runs in the subdirectory of the trusted project."),
    () => fauxAssistantMessage("Trust was revoked for the project."),
  ]);

  const undecided = await phone.request("trust.inspect", { cwd: nested });
  const refused = await phone.request("session.create", { commandId: gateway.commandId(), cwd: nested });
  const decided = await phone.request("settings.change", {
    commandId: gateway.commandId(), target: { kind: "global" }, reason: "Trust the lock project",
    changes: [{ key: "permissions.projectTrust", layer: "global", op: "set", value: true, qualifiers: { project: nested } }],
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
  // Revoking the root's decision reloads the chat through its projectDir without the Project layer.
  const revoked = await phone.request("settings.change", {
    commandId: gateway.commandId(), target: { kind: "global" }, reason: "Stop trusting the lock project",
    changes: [{ key: "permissions.projectTrust", layer: "global", op: "set", value: false, qualifiers: { project: nested } }],
  });
  expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId, text: "and after revoking trust?" })).ok).toBe(true);
  await gateway.settled(sessionId);
  const transcript = await phone.request("session.transcript", { sessionId });
  return { root, project, nested, phone, systemPrompt: () => systemPrompt, undecided, refused, decided, rootInspection, nestedInspection,
    created, sessionId, opened, chatSettings, projectSettings, revoked, transcript };
}

interface AutomationRunRecord { runId?: string; state?: string; executionSessionId?: string; assistantCompletionId?: string }
interface AutomationRecordFile { currentRun?: AutomationRunRecord | null; lastRun?: AutomationRunRecord | null }

/**
 * `automation-owned-run`: one chat turn, then a session-prompt automation into that
 * chat and a workspace-prompt automation, each run now; each run reads a file
 * through a tool, and the phone reads both automations, both runs and the transcript.
 */
export async function automationOwnedRunScenario(gateway: LockGateway) {
  const phone = await gateway.connect("phone");
  const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  const opened = await phone.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);

  const automationFile = (automationId: string) => join(gateway.tronHome, "gateway", "automations", `${automationId}.json`);
  const raw = async (automationId: string) => {
    return JSON.parse(await readFile(automationFile(automationId), "utf8")) as AutomationRecordFile;
  };
  const runNow = async (definition: Record<string, unknown>, label: string) => {
    const automation = await phone.request("automation.create", { commandId: gateway.commandId(), definition });
    expect(automation.ok, JSON.stringify(automation)).toBe(true);
    const automationId = automation.result.id as string;
    const run = await phone.request("automation.runNow", {
      commandId: gateway.commandId(), automationId, expectedRevision: automation.result.revision,
    });
    expect(run.ok, JSON.stringify(run)).toBe(true);
    const runId = run.result.runId as string;
    // Settled: the terminal run is the record's last run and no run is current.
    const settled = await waitFor(async () => {
      const record = await raw(automationId);
      return record.lastRun?.runId === runId && !record.currentRun ? record.lastRun : undefined;
    }, `the ${label} run's durable terminal`);
    await gateway.settled(settled.executionSessionId!);
    return { automationId, runId, executionSessionId: settled.executionSessionId!, state: settled.state, assistantCompletionId: settled.assistantCompletionId };
  };
  const definition = (target: Record<string, unknown>, text: string, name: string) => ({
    name, activation: "draft", target,
    trigger: { kind: "once", at: "2099-01-01T09:00:00.000Z" },
    action: { kind: "sessionPrompt", text },
  });

  gateway.script([
    async () => {
      await gateway.observeLiveOperation(phone, sessionId);
      return fauxAssistantMessage("Ready for scheduled checks.");
    },
    () => fauxAssistantMessage([fauxToolCall("read", { path: "notes.txt" }, { id: "lock-automation-read" })], { stopReason: "toolUse" }),
    () => fauxAssistantMessage("The scheduled check found: lock notes."),
    () => fauxAssistantMessage([fauxToolCall("read", { path: "notes.txt" }, { id: "lock-workspace-read" })], { stopReason: "toolUse" }),
    () => fauxAssistantMessage("The workspace check found: lock notes."),
  ]);
  // A chat exists for the catalog once its first turn is persisted; only then can it be a target.
  expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId, text: "get ready for scheduled checks" })).ok).toBe(true);
  await gateway.settled(sessionId);
  const existing = await runNow(definition({ kind: "existingSession", sessionId }, "run the scheduled notes check", "Lock session check"), "session prompt");
  const workspace = await runNow(definition({ kind: "workspace", cwd: gateway.cwd, sessionPolicy: "newPerRun" },
    "run the workspace notes check", "Lock workspace check"), "workspace prompt");

  const reads: Array<[string, Record<string, unknown>]> = [
    ["automation.get", { automationId: existing.automationId }],
    ["automation.run.get", { automationId: existing.automationId, runId: existing.runId }],
    ["automation.get", { automationId: workspace.automationId }],
    ["automation.run.get", { automationId: workspace.automationId, runId: workspace.runId }],
    ["session.transcript", { sessionId }],
  ];
  for (const [method, params] of reads) {
    const read = await phone.request(method, params);
    expect(read.ok, `${method} ${JSON.stringify(read)}`).toBe(true);
  }
  return { phone, sessionId, existing, workspace };
}

export const PUSH_RELAY_ORIGIN = "https://relay.lock.invalid";
const PUSH_SELECT_EXTENSION = `
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
`;

export interface PushRelayRequest { method: string; path: string; grantId: string | null; envelope: TraceValue }


/**
 * `notifications-push`: a registered phone; one chat runs to a completed, an
 * input-required, a failed and a stopped end while hidden, and to an
 * input-required and a completed end while presented; then a Home task worker,
 * admitted as the dispatcher admits it, runs to its end. `own` receives the
 * Gateway's and the notification owner's disposal.
 */
export async function notificationsPushScenario(own: (release: () => Promise<void>) => void) {
  const relayRequests: PushRelayRequest[] = [];
  let gateway!: LockGateway;
  let notifications!: NotificationService;
  gateway = await startLockGateway("notifications-push", {
    extensions: [{ name: "lock-select.ts", source: PUSH_SELECT_EXTENSION }],
    notifications: async (tronHome) => {
      // The relay boundary: every push the Gateway would send to Tron Push.
      const relay = new PushRelayClient(PUSH_RELAY_ORIGIN, async (url, init) => {
        relayRequests.push({
          method: String(init.method), path: new URL(url).pathname,
          grantId: (init.headers as Record<string, string> | undefined)?.["x-tron-grant-id"] ?? null,
          envelope: init.body ? JSON.parse(String(init.body)) as TraceValue : null,
        });
        return new Response(JSON.stringify({ status: "accepted_by_apns" }), { status: 200 }) as never;
      });
      // gateway-main's wiring, Home role resolved from the live registry.
      notifications = new NotificationService(new NotificationGrantStore(tronHome), relay, Date.now, () => {}, () => {}, () => {},
        (sessionId) => (gateway ? homeOwnerOf(gateway.registry) : undefined)?.chapterStateFor(sessionId).homeId !== undefined);
      await notifications.initialize();
      return notifications;
    },
  });
  own(() => gateway.dispose());
  own(async () => notifications.dispose());
  const sent = (count: number, label: string) => waitFor(() => relayRequests.length >= count, label);
  const document = async () => JSON.parse(await readFile(join(gateway.tronHome, "gateway", "notifications.json"), "utf8")) as {
    receipts: Array<{ result: string; grantIds: string[] }>;
    pending: unknown[];
  };

  const phone = await gateway.connect("phone", { clientRole: "mobile" });
  const responses: Record<string, { ok: boolean; result?: unknown; error?: unknown }> = {};
  const registered = await phone.request("push.registration.upsert", {
    commandId: gateway.commandId(), installationId: "lock-installation", grantId: "lock-grant-0001",
    secret: Buffer.alloc(32, 7).toString("base64url"), previewsEnabled: false, relayOrigin: PUSH_RELAY_ORIGIN,
    notifyWhenAskPresented: true, notifyWhenFinished: true, notifyWhenWaiting: true,
  });
  responses.registered = registered;

  const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  const opened = await phone.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  const subscriptionToken = opened.result.subscriptionToken as string;
  const slot = await gateway.registry.acquire(sessionId);
  // Pin the ordinary idle path before a run can supersede it. Terminal idle
  // snapshots may all coalesce into rebaselines, even on a loopback socket.
  await waitFor(() => slot.snapshot().configurationBlocker === null, "the initial session ownership to retire");
  const initialEvents = phone.events.length;
  slot.publishSnapshot();
  await waitFor(() => phone.events.slice(initialEvents).some((event) => event.sessionId === sessionId && event.topic === "session.snapshot"
    && (event.payload as { configurationBlocker?: unknown }).configurationBlocker === null),
  "the initial ordinary idle snapshot to reach the phone");
  const prompt = (text: string) => phone.send("session.prompt", { commandId: gateway.commandId(), sessionId, text });
  const answerSelect = async (client: LockClient, answered: number) => {
    const pending = await waitFor(() => {
      const shown = client.events.flatMap((event) => (event.payload as {
        extensionPresentation?: { pendingInteractions?: Array<{ id: string; hostEpoch: string; presentationRevision: number }> };
      })?.extensionPresentation?.pendingInteractions ?? []);
      return shown.filter((interaction, index) => shown.findIndex((other) => other.id === interaction.id) === index)[answered];
    }, "the pending select to reach the phone");
    return pending;
  };
  const respond = (pending: { id: string; hostEpoch: string; presentationRevision: number }) => phone.request("extension.respond", {
    commandId: gateway.commandId(), sessionId, interactionId: pending.id,
    hostEpoch: pending.hostEpoch, presentationRevision: pending.presentationRevision, value: "Keep",
  });

  // 1. Hidden: a completed run pushes "finished".
  gateway.script([() => fauxAssistantMessage("Finished the quiet run.")]);
  expect((await prompt("finish the quiet run")).ok).toBe(true);
  await gateway.settled(sessionId);
  await sent(1, "the completed-run push");

  // 2. Hidden: input required pushes "Input needed" before the answer; the run's end pushes again.
  gateway.script([
    () => fauxAssistantMessage([fauxToolCall("lock_select", {}, { id: "lock-select-hidden" })], { stopReason: "toolUse" }),
    () => fauxAssistantMessage("Keeping the hidden path."),
  ]);
  const hiddenRun = prompt("ask me while I am away");
  const hiddenAsk = await answerSelect(phone, 0);
  await sent(2, "the input-required push");
  responses.hiddenAnswer = await respond(hiddenAsk);
  expect((await hiddenRun).ok).toBe(true);
  await gateway.settled(sessionId);
  await sent(3, "the push after the answered run");

  // 3. Presented: the same ask and end are suppressed, not pushed.
  responses.presenting = await phone.request("session.presentation.set", { sessionId, subscriptionToken, revision: 1, visible: true });
  gateway.script([
    () => fauxAssistantMessage([fauxToolCall("lock_select", {}, { id: "lock-select-presented" })], { stopReason: "toolUse" }),
    () => fauxAssistantMessage("Keeping the presented path."),
  ]);
  const presentedRun = prompt("ask me while I am watching");
  responses.presentedAnswer = await respond(await answerSelect(phone, 1));
  expect((await presentedRun).ok).toBe(true);
  await gateway.settled(sessionId);
  await waitFor(async () => (await document()).receipts.filter((receipt) => receipt.result === "suppressed").length >= 2,
    "the presented ask and end to be suppressed");
  responses.hiding = await phone.request("session.presentation.set", { sessionId, subscriptionToken, revision: 2, visible: false });

  // 4. Hidden, renamed: a provider error pushes "stopped because of an error", titled by the name.
  responses.rename = await phone.request("session.rename", { commandId: gateway.commandId(), sessionId, name: "Renamed lock chat" });
  let failedProviderReached!: () => void;
  const failedProvider = new Promise<void>((resolve) => { failedProviderReached = resolve; });
  gateway.script([() => {
    failedProviderReached();
    return fauxAssistantMessage("partial", { stopReason: "error", errorMessage: "lock provider failure" });
  }]);
  const failureEvents = phone.events.length;
  // A slow writer must receive the idle snapshot as a rebaseline covering
  // unsent busy state. Otherwise compression versus receipt I/O decides which
  // topic carries the null configuration blocker, making the schema lock race.
  const releaseWrites = phone.holdWrites();
  try {
    const failedRun = prompt("fail this run");
    await awaitsWithin(failedProvider, "the failed provider request");
    await gateway.settled(sessionId);
    await waitFor(() => slot.snapshot().configurationBlocker === null, "the failed run's terminal ownership to retire");
    releaseWrites();
    expect((await failedRun).ok).toBe(true);
    await waitFor(() => phone.events.slice(failureEvents).some((event) => event.topic === "session.rebaseline"
      && (event.payload as { snapshot?: { configurationBlocker?: unknown } }).snapshot?.configurationBlocker === null),
    "the failed run's idle rebaseline to reach the phone");
  } finally {
    releaseWrites();
  }
  await sent(4, "the failed-run push");

  // 5. Hidden: a client abort pushes "was stopped".
  let reached!: () => void;
  const held = new Promise<void>((resolve) => { reached = resolve; });
  gateway.script([async (_context, options) => {
    reached();
    await new Promise<void>((resolve) => {
      const signal = options?.signal;
      if (!signal || signal.aborted) { resolve(); return; }
      signal.addEventListener("abort", () => resolve(), { once: true });
    });
    return fauxAssistantMessage("Aborted turn response.");
  }]);
  const abortable = await prompt("start a run to stop");
  expect(abortable.ok).toBe(true);
  await awaitsWithin(held, "the abortable provider request");
  expect((await phone.request("session.abort", { commandId: gateway.commandId(), sessionId, operationId: abortable.result.operationId })).ok).toBe(true);
  await gateway.settled(sessionId);
  await sent(5, "the stopped-run push");

  // 6. A Home task worker's end is never a generic chat push (its report owner decides).
  gateway.script([() => fauxAssistantMessage("Worker reply without a report."), () => fauxAssistantMessage("Worker still has no report.")]);
  const operationId = "task-lock-operation";
  const report = new HomeTaskReportOwner({ taskId: "lock-task", homeId: "lock-home", generation: 1, operationId }, async () => {});
  const dispatch = gateway.registry.delegation;
  const lease = await dispatch.createWorker(gateway.cwd, report);
  const workerTerminal = new Promise<unknown>((resolve) => {
    void lease.slot.prompt("do the lock task", [], undefined, undefined, undefined, {
      operationId, signal: report.signal, origin: { kind: "gateway", ownerId: "lock-task", title: "Home task", confidence: "boundary" },
      onTerminal: resolve,
    });
  });
  await awaitsWithin(workerTerminal, "the task worker's terminal");
  // The owner acknowledges settlement, as the dispatcher does; only then is the operation released.
  await dispatch.acknowledge(lease.slot.id, operationId, lease);
  report.retire();
  await gateway.settled(lease.slot.id);
  const workerRoles = (await gateway.canonical(lease.slot.id)).flatMap((entry) => {
    const role = (entry as { message?: { role?: string } }).message?.role;
    return role ? [role] : [];
  });

  // Every queued push has reached a final relay outcome before the inbox is read.
  await waitFor(async () => (await document()).pending.length === 0, "every queued push to settle at the relay");
  const inbox = await phone.request("notification.inbox.list", {});
  const stored = await document();
  return { gateway, relayRequests, responses, inbox, stored, workerRoles, sessionId };
}

export interface Opened { readonly sessionId: string; readonly subscriptionToken: string }

export async function createAndOpen(gateway: LockGateway, client: LockClient): Promise<Opened> {
  const created = await client.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  return openExisting(client, created.result.sessionId as string);
}

export async function openExisting(client: LockClient, sessionId: string): Promise<Opened> {
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return { sessionId, subscriptionToken: opened.result.subscriptionToken as string };
}


export const WAITING_COMMAND = `
  export default function (pi) {
    pi.registerCommand("lockask", {
      description: "Ask which lock path to take",
      handler: async (_args, ctx) => { await ctx.ui.select("Choose a lock path", ["Keep", "Change"]); },
    });
  }
`;

/** An extension tool that starts a declared asynchronous run: its status artifact
 * lives under the project's async run root, and the tool returns at once. */
export const DETACHED_RUN = `
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
`;


/**
 * `run-drain-blockers`: a detached extension run and an extension command awaiting
 * its select hold the administrative drain until the answer and the run's terminal
 * artifact; the drain status is read before, while waiting, after the answer and
 * at completion.
 */
export async function drainBlockersScenario(gateway: LockGateway) {
  const phone = await gateway.connect("phone");
  gateway.script([
    () => fauxAssistantMessage([fauxToolCall("lock_background", {}, { id: "lock-background-call" })], { stopReason: "toolUse" }),
    () => fauxAssistantMessage("The background run is under way."),
  ]);
  const asking = await createAndOpen(gateway, phone);
  const detached = await createAndOpen(gateway, phone);
  const roles = new Map([[asking.sessionId, "command"], [detached.sessionId, "detached"]]);
  // Each RPC's own work settles just after its response frame; wait for it, so
  // each status names only the blockers under test.
  const rpcSettled = () => waitFor(() => !gateway.registry.administrativeDrainSnapshot().blockers
    .some((blocker) => blocker.category === "rpc-mutation"), "the RPCs' own work to settle");

  // The detached session's turn starts the background run and ends; the run stays live.
  expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: detached.sessionId, text: "start the background run" })).ok).toBe(true);
  // The slot stays busy while it owns the run, so the turn's end is its settled operation.
  const detachedSlot = await gateway.registry.acquire(detached.sessionId);
  await waitFor(() => !detachedSlot.snapshot().operation && gateway.record().providerRequests.length === 2
    && detachedSlot.snapshot().extensionActivities?.some((activity) => activity.status === "running")
    && gateway.registry.administrativeDrainSnapshot().blockers.every((blocker) => blocker.category === "detached-extension-run"),
  "the detached turn and its receipts to settle with its run live");
  // The command session waits on the user's answer, with no agent run.
  const command = phone.send("session.prompt", { commandId: gateway.commandId(), sessionId: asking.sessionId, text: "/lockask" });
  const pending = await waitFor(() => {
    for (const event of phone.events) {
      // A command runs no agent turn, so its select arrives on the presentation topic alone.
      if (event.topic !== "session.extensionPresentation" || event.sessionId !== asking.sessionId) continue;
      const shown = (event.payload as { data?: { interactionList?: Array<{ id: string; hostEpoch: string; presentationRevision: number }> } })
        ?.data?.interactionList?.[0];
      if (shown) return shown;
    }
    return undefined;
  }, "the command's select to reach the phone");
  await rpcSettled();
  const statusBefore = await phone.request("gateway.drain.status", {});

  gateway.registry.beginAdministrativeDrain();
  const drained = gateway.registry.waitUntilIdle();
  await waitFor(() => gateway.registry.administrativeDrainSnapshot().phase === "waiting", "the drain to wait");
  await rpcSettled();
  const statusWaiting = await phone.request("gateway.drain.status", {});

  // The answer settles the command; the detached run still holds the drain.
  expect((await phone.request("extension.respond", {
    commandId: gateway.commandId(), sessionId: asking.sessionId, interactionId: pending.id,
    hostEpoch: pending.hostEpoch, presentationRevision: pending.presentationRevision, value: "Keep",
  })).ok).toBe(true);
  const commandResponse = await command;
  await waitFor(() => !gateway.registry.administrativeDrainSnapshot().blockers.some((blocker) => blocker.sessionId === asking.sessionId),
    "the answered command to leave the drain");
  await rpcSettled();
  const statusAfterAnswer = await phone.request("gateway.drain.status", {});

  // The run's terminal artifact ends it, and the drain completes.
  const endedAt = Date.now();
  await writeFile(join(gateway.cwd, ".pi", "subagents", "async-subagent-runs", "lock-background-run", "status.json"), JSON.stringify({
    runId: "lock-background-run", state: "complete", startedAt: endedAt - 1_000, endedAt, lastUpdate: endedAt + 1,
  }));
  const completed = await awaitsWithin(drained, "the drain to complete");
  const statusComplete = await phone.request("gateway.drain.status", {});
  const activities = detachedSlot.snapshot().extensionActivities ?? [];
  return { phone, asking, detached, roles, commandResponse, statusBefore, statusWaiting, statusAfterAnswer, completed, statusComplete, activities };
}

/** The extension the extension-UI scenario's chat loads: a tool whose `select` waits for the client. */
export const EXTENSION_UI_OPTIONS: LockGatewayOptions = { extensions: [{ name: "lock-select.ts", source: `
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
` }] };

/** `run-extension-ui`: an extension tool's select waits for the client's answer and resumes the turn with it. */
export async function extensionUiScenario(session: LockSession) {
  session.gateway.script([
    async () => {
      await session.gateway.observeLiveOperation(session.client, session.sessionId);
      return fauxAssistantMessage([fauxToolCall("lock_select", {}, { id: "lock-select" })], { stopReason: "toolUse" });
    },
    () => fauxAssistantMessage("Keeping the lock path."),
  ]);
  const running = session.prompt("ask me which path");
  // The client answers what it was shown: the interaction arrives on an event.
  const pending = await waitFor(() => {
    for (const event of session.client.events) {
      const shown = (event.payload as { extensionPresentation?: { pendingInteractions?: Array<{ id: string; hostEpoch: string; presentationRevision: number }> } })
        ?.extensionPresentation?.pendingInteractions?.[0];
      if (shown) return shown;
    }
    return undefined;
  }, "the pending select to reach the client");
  const answered = await session.client.request("extension.respond", {
    commandId: session.gateway.commandId(), sessionId: session.sessionId, interactionId: pending.id,
    hostEpoch: pending.hostEpoch, presentationRevision: pending.presentationRevision, value: "Keep",
  });
  expect(answered.ok, JSON.stringify(answered)).toBe(true);
  expect((await running).ok).toBe(true);
  return { pending, answered };
}
