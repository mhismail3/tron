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

export interface LockSession {
  readonly gateway: LockGateway;
  readonly client: LockClient;
  readonly sessionId: string;
  prompt(text: string, extra?: Record<string, unknown>): Promise<{ ok: boolean; result?: any; error?: any }>;
}

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

export async function compactionScenario(session: LockSession): Promise<{ compacted: { ok: boolean; result?: any } }> {
  const long = "lock context ".repeat(80);
  session.gateway.script([
    async () => {
      await session.gateway.observeLiveOperation(session.client, session.sessionId);
      return fauxAssistantMessage(`First answer. ${long}`);
    },
    () => fauxAssistantMessage(`Second answer. ${long}`),
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

export function gate(): { opened: Promise<void>; open(): void; reached: Promise<void>; reach(): void } {
  let open = (): void => {};
  let reach = (): void => {};
  const opened = new Promise<void>((resolve) => { open = resolve; });
  const reached = new Promise<void>((resolve) => { reach = resolve; });
  return { opened, open: () => open(), reached, reach: () => reach() };
}

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

  first.open();
  await gateway.settled(sessionId);
  const retriedResponse = await retried;

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


export async function projectRootTrustScenario(gateway: LockGateway) {
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

export async function automationOwnedRunScenario(gateway: LockGateway) {
  const phone = await gateway.connect("phone");
  const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  const opened = await phone.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);

  const automationFile = (automationId: string) => join(gateway.tronHome, "state", "automations", `${automationId}.json`);
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


export async function notificationsPushScenario(own: (release: () => Promise<void>) => void) {
  const relayRequests: PushRelayRequest[] = [];
  let gateway!: LockGateway;
  let notifications!: NotificationService;
  gateway = await startLockGateway("notifications-push", {
    extensions: [{ name: "lock-select.ts", source: PUSH_SELECT_EXTENSION }],
    notifications: async (tronHome) => {
      const relay = new PushRelayClient(PUSH_RELAY_ORIGIN, async (url, init) => {
        relayRequests.push({
          method: String(init.method), path: new URL(url).pathname,
          grantId: (init.headers as Record<string, string> | undefined)?.["x-tron-grant-id"] ?? null,
          envelope: init.body ? JSON.parse(String(init.body)) as TraceValue : null,
        });
        return new Response(JSON.stringify({ status: "accepted_by_apns" }), { status: 200 }) as never;
      });
      notifications = new NotificationService(new NotificationGrantStore(tronHome), relay, async () => ({ inputNeeded: true, finished: true, waiting: true }), Date.now, () => {}, () => {}, () => {},
        (sessionId) => (gateway ? homeOwnerOf(gateway.registry) : undefined)?.chapterStateFor(sessionId).homeId !== undefined);
      await notifications.initialize();
      return notifications;
    },
  });
  own(() => gateway.dispose());
  own(async () => notifications.dispose());
  const sent = (count: number, label: string) => waitFor(() => relayRequests.length >= count, label);
  const document = async () => JSON.parse(await readFile(join(gateway.tronHome, "state", "notifications.json"), "utf8")) as {
    receipts: Array<{ result: string; grantIds: string[] }>;
    pending: unknown[];
  };

  const phone = await gateway.connect("phone", { clientRole: "mobile" });
  const responses: Record<string, { ok: boolean; result?: unknown; error?: unknown }> = {};
  const registered = await phone.request("push.registration.upsert", {
    commandId: gateway.commandId(), installationId: "lock-installation", grantId: "lock-grant-0001",
    secret: Buffer.alloc(32, 7).toString("base64url"), previewsEnabled: false, relayOrigin: PUSH_RELAY_ORIGIN
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

  gateway.script([() => fauxAssistantMessage("Finished the quiet run.")]);
  expect((await prompt("finish the quiet run")).ok).toBe(true);
  await gateway.settled(sessionId);
  await sent(1, "the completed-run push");

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

  responses.rename = await phone.request("session.rename", { commandId: gateway.commandId(), sessionId, name: "Renamed lock chat" });
  let failedProviderReached!: () => void;
  const failedProvider = new Promise<void>((resolve) => { failedProviderReached = resolve; });
  gateway.script([() => {
    failedProviderReached();
    return fauxAssistantMessage("partial", { stopReason: "error", errorMessage: "lock provider failure" });
  }]);
  const failureEvents = phone.events.length;
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
  await dispatch.acknowledge(lease.slot.id, operationId, lease);
  report.retire();
  await gateway.settled(lease.slot.id);
  const workerRoles = (await gateway.canonical(lease.slot.id)).flatMap((entry) => {
    const role = (entry as { message?: { role?: string } }).message?.role;
    return role ? [role] : [];
  });

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


export async function drainBlockersScenario(gateway: LockGateway) {
  const phone = await gateway.connect("phone");
  gateway.script([
    () => fauxAssistantMessage([fauxToolCall("lock_background", {}, { id: "lock-background-call" })], { stopReason: "toolUse" }),
    () => fauxAssistantMessage("The background run is under way."),
  ]);
  const asking = await createAndOpen(gateway, phone);
  const detached = await createAndOpen(gateway, phone);
  const roles = new Map([[asking.sessionId, "command"], [detached.sessionId, "detached"]]);
  const rpcSettled = () => waitFor(() => !gateway.registry.administrativeDrainSnapshot().blockers
    .some((blocker) => blocker.category === "rpc-mutation"), "the RPCs' own work to settle");

  expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: detached.sessionId, text: "start the background run" })).ok).toBe(true);
  const detachedSlot = await gateway.registry.acquire(detached.sessionId);
  await waitFor(() => !detachedSlot.snapshot().operation && gateway.record().providerRequests.length === 2
    && detachedSlot.snapshot().extensionActivities?.some((activity) => activity.status === "running")
    && gateway.registry.administrativeDrainSnapshot().blockers.every((blocker) => blocker.category === "detached-extension-run"),
  "the detached turn and its receipts to settle with its run live");
  const command = phone.send("session.prompt", { commandId: gateway.commandId(), sessionId: asking.sessionId, text: "/lockask" });
  const pending = await waitFor(() => {
    for (const event of phone.events) {
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

  expect((await phone.request("extension.respond", {
    commandId: gateway.commandId(), sessionId: asking.sessionId, interactionId: pending.id,
    hostEpoch: pending.hostEpoch, presentationRevision: pending.presentationRevision, value: "Keep",
  })).ok).toBe(true);
  const commandResponse = await command;
  await waitFor(() => !gateway.registry.administrativeDrainSnapshot().blockers.some((blocker) => blocker.sessionId === asking.sessionId),
    "the answered command to leave the drain");
  await rpcSettled();
  const statusAfterAnswer = await phone.request("gateway.drain.status", {});

  const endedAt = Date.now();
  await writeFile(join(gateway.cwd, ".pi", "subagents", "async-subagent-runs", "lock-background-run", "status.json"), JSON.stringify({
    runId: "lock-background-run", state: "complete", startedAt: endedAt - 1_000, endedAt, lastUpdate: endedAt + 1,
  }));
  const completed = await awaitsWithin(drained, "the drain to complete");
  const statusComplete = await phone.request("gateway.drain.status", {});
  const activities = detachedSlot.snapshot().extensionActivities ?? [];
  return { phone, asking, detached, roles, commandResponse, statusBefore, statusWaiting, statusAfterAnswer, completed, statusComplete, activities };
}

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

export async function extensionUiScenario(session: LockSession) {
  session.gateway.script([
    async () => {
      await session.gateway.observeLiveOperation(session.client, session.sessionId);
      return fauxAssistantMessage([fauxToolCall("lock_select", {}, { id: "lock-select" })], { stopReason: "toolUse" });
    },
    () => fauxAssistantMessage("Keeping the lock path."),
  ]);
  const running = session.prompt("ask me which path");
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
