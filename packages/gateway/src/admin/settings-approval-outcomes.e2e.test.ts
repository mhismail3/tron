import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type AssistantMessage, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { settingsDependencies, setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { disposeFixtures, fixture as homeTaskFixture } from "../../test-support/home-task-fixture.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { UploadStore } from "../machine/upload-store.js";
import { DEFAULT_MAX_UPLOAD_BYTES } from "../config.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { displayOwnerOf, homeOwnerOf } from "../../test-support/gateway-registry.js";
import { APPROVAL_TTL_MS } from "../kernel/settings/settings-approvals.js";
import { SETTINGS_OUTCOME_MESSAGE, type SettingsOutcomeMessage } from "../kernel/settings/tool-contract.js";

/**
 * Home asks for approval in the chat and hears every outcome (#1642, decision
 * 4e6e8f54), at the real Gateway boundary: a designated Home on a faux model calls
 * the `settings` tool, the maintainer decides through `settings.decide`, and the
 * outcome reaches the requester as one `tron.settings-outcome.v1` message with
 * structured details; expiry runs at its deadline with no read. Retained at `test-results/settings-approval-outcomes.json`.
 */
const ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../test-results/settings-approval-outcomes.json");
const transcript: Array<{ case: string; steps: Array<Record<string, unknown>> }> = [];
afterEach(async () => { await disposeFixtures(); });
afterAll(async () => {
  await mkdir(dirname(ARTIFACT), { recursive: true });
  await writeFile(ARTIFACT, `${JSON.stringify(transcript, null, 2)}\n`);
});

function phone(): ClientContext {
  return { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
}

let command = 0;
const commandId = () => `approval-outcomes-${String(++command).padStart(4, "0")}`;
const textOf = (message: { content: unknown }) => typeof message.content === "string" ? message.content
  : (message.content as Array<{ text?: string }>).map(part => part.text ?? "").join("");
const RETRIES = (value: number) => ({ key: "run.retry.maxRetries", layer: "global", op: "set", value });

async function gateway() {
  const f = await homeTaskFixture();
  let clock = Date.now();
  const scheduled: Array<{ run: () => void; ms: number; cancelled: boolean }> = [];
  const { settingsModel, settingsChanges } = settingsDependencies({ agentDir: f.agentDir, tronHome: f.tronHome, trust: f.trust, modelRuntime: f.gateway,
    sessions: f.registry, home: () => homeOwnerOf(f.registry), registry: f.registry, now: () => new Date(clock),
    schedule: (run, ms) => { const timer = { run, ms, cancelled: false }; scheduled.push(timer); return { cancel: () => { timer.cancelled = true; } }; } });
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  const service = new GatewayService({ display: displayOwnerOf(f.registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: f.tronHome, agentDir: f.agentDir },
    modelRuntime: f.gateway, trust: f.trust, settingsModel, settingsChanges, sessions: f.registry, home: homeOwnerOf(f.registry),
    receipts: new CommandReceiptStore(f.tronHome), uploads: new UploadStore(f.tronHome, DEFAULT_MAX_UPLOAD_BYTES),
    notifications: { enqueue: async () => "queued" }, broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);

  // Home's model: each prompt the test sends names its one tool call; every other
  // request (a tool result, or a turn the Gateway started) answers in words.
  const calls = new Map<string, { name: string; args: Record<string, unknown> }>();
  const results = new Map<string, { isError: boolean; text: string; details: unknown }>();
  /** Every Home request that no user prompt started: the wake turns, with what started them. */
  const wakes: Array<{ trigger: string }> = [];
  const respond = async (context: TranscriptContext): Promise<AssistantMessage> => {
    const last = context.messages.at(-1)!;
    const prompts = context.messages.filter(message => message.role === "user").map(textOf);
    if (last.role === "toolResult") {
      const prompt = [...calls.keys()].findLast(text => prompts.includes(text));
      if (prompt) results.set(prompt, { isError: last.isError === true, text: textOf(last), details: last.details });
      return fauxAssistantMessage("Done.");
    }
    // This turn's own input: a test prompt (an outcome before it may ride along), or what the Gateway started it with.
    const turn = context.messages.slice(context.messages.findLastIndex(message => message.role === "assistant") + 1).map(textOf);
    const call = calls.get(turn.find(text => calls.has(text)) ?? "");
    if (call) return fauxAssistantMessage([fauxToolCall(call.name, call.args)], { stopReason: "toolUse" });
    wakes.push({ trigger: textOf(last) });
    return fauxAssistantMessage("Noted.");
  };
  f.faux.setResponses(Array.from({ length: 60 }, () => respond as never));
  const home = await f.registry.acquire(f.home.sessionId);
  const settled = () => waitFor(() => home.snapshot().configurationBlocker === null && home.snapshot().phase === "idle" || undefined, "Home idle");
  const homeSays = async (prompt: string, name: string, args: Record<string, unknown>) => {
    calls.set(prompt, { name, args });
    await home.prompt(prompt);
    const result = await waitFor(() => results.get(prompt), `Home result: ${prompt}`);
    await settled();
    return result;
  };
  /** The settings outcome messages Home's canonical session holds, in order. */
  const outcomes = () => home.canonicalSessionEntries().flatMap(entry => entry.type === "custom_message" && entry.customType === SETTINGS_OUTCOME_MESSAGE
    ? [{ content: String(entry.content), details: entry.details as SettingsOutcomeMessage["details"] }] : []);
  const approvals = async () => (await service.invoke(phone(), "settings.approvals", {}) as unknown as { requests: Array<{ requestId: string; digest: string }> }).requests;
  const decide = (requestId: string, digest: string, approved: boolean) =>
    service.invoke(phone(), "settings.decide", { commandId: commandId(), requestId, digest, approved }) as Promise<Record<string, unknown>>;
  /** An ordinary project chat on the same faux model; it hears outcomes on its next turn. */
  const chat = async () => {
    const slot = await f.registry.create(f.cwd);
    await slot.setModel(f.model.provider, f.model.id);
    return {
      slot,
      says: async (prompt: string, name: string, args: Record<string, unknown>) => {
        calls.set(prompt, { name, args });
        await slot.prompt(prompt);
        const result = await waitFor(() => results.get(prompt), `chat result: ${prompt}`);
        await waitFor(() => slot.snapshot().configurationBlocker === null && slot.snapshot().phase === "idle" || undefined, "chat idle");
        return result;
      },
      outcomes: () => slot.canonicalSessionEntries().flatMap(entry => entry.type === "custom_message" && entry.customType === SETTINGS_OUTCOME_MESSAGE
        ? [{ content: String(entry.content), details: entry.details as SettingsOutcomeMessage["details"] }] : []),
    };
  };
  return { ...f, service, settingsChanges, home, homeSays, settled, outcomes, approvals, decide, wakes, scheduled, chat,
    advance: (ms: number) => { clock += ms; } };
}

describe("settings approval outcomes", () => {
  it("a chat hears its approved change on its next turn, applied, with readable details", async () => {
    const f = await gateway();
    // The maintainer raised retries' floor, so the chat's change waits for his tap.
    await f.service.invoke(phone(), "settings.change", { commandId: commandId(), target: { kind: "global" },
      changes: [{ key: "permissions.floor", layer: "global", op: "set", value: "approve", qualifiers: { key: "run.retry.maxRetries" } }] });
    const chat = await f.chat();
    const asked = await chat.says("Raise retries", "settings", { action: "change", reason: "Flaky provider today", changes: [RETRIES(5)] });
    expect(asked.details).toMatchObject({ status: "pending", tier: "approve" });
    const [request] = await f.approvals();
    await expect(f.decide(request!.requestId, request!.digest, true)).resolves.toMatchObject({ status: "approved" });
    await chat.says("Anything new?", "settings", { action: "resolve", keys: ["run.retry.maxRetries"] });
    const heard = chat.outcomes();
    expect(heard).toHaveLength(1);
    expect(heard[0]!.content).toBe(`Settings request ${request!.requestId}: Retries (run.retry.maxRetries) at the Global layer: Default (3 retries) → 5 retries was approved by the maintainer and applied.`);
    expect(heard[0]!.details).toMatchObject({ version: 1, requests: [{ requestId: request!.requestId, status: "approved", requester: { kind: "agent" }, reason: "Flaky provider today",
      items: [{ key: "run.retry.maxRetries", label: "Retries", layer: "global", before: "Default (3 retries)", after: "5 retries" }] }] });
    // Heard once.
    await chat.says("And now?", "settings", { action: "resolve", keys: ["run.retry.maxRetries"] });
    expect(chat.outcomes()).toHaveLength(1);
    transcript.push({ case: "approved outcome told", steps: [{ outcome: heard[0]! }] });
  }, 90_000);

  it("a request is held for the tap whatever its tier, its dry run says so, and only the maintainer may ask nothing of himself", async () => {
    const f = await gateway();
    const actor = { kind: "agent" as const, id: "chat", sessionId: "chat" };
    const dry = await f.settingsChanges.change({ kind: "global" }, [RETRIES(5) as never], { actor, reason: "Flaky", request: true, dryRun: true });
    expect(dry).toMatchObject({ dryRun: true, status: "pending", tier: "approve", changes: [{ status: "pending", tier: "approve" }] });
    expect(await f.approvals()).toEqual([]);
    const held = await f.settingsChanges.change({ kind: "global" }, [RETRIES(5) as never], { actor, reason: "Flaky", request: true });
    expect(held).toMatchObject({ status: "pending", tier: "approve" });
    const [request] = await f.approvals();
    expect(request).toMatchObject({ requestId: held.approval!.requestId, changes: [{ key: "run.retry.maxRetries", tier: "approve", tierBasis: { floor: "quiet", requested: true } }] });
    await expect(f.settingsChanges.change({ kind: "global" }, [RETRIES(6) as never], { actor: { kind: "ui", id: "phone" }, request: true }))
      .rejects.toMatchObject({ code: "invalid_request" });
  }, 60_000);

  it("a pending request expires at its 24-hour deadline with no read, and its requester hears it", async () => {
    const f = await gateway();
    await f.service.invoke(phone(), "settings.change", { commandId: commandId(), target: { kind: "global" },
      changes: [{ key: "permissions.floor", layer: "global", op: "set", value: "approve", qualifiers: { key: "run.retry.maxRetries" } }] });
    const chat = await f.chat();
    await chat.says("Raise retries overnight", "settings", { action: "change", reason: "Overnight batch", changes: [RETRIES(7)] });
    const deadline = f.scheduled.filter(timer => !timer.cancelled).at(-1)!;
    expect(deadline.ms).toBeGreaterThan(APPROVAL_TTL_MS - 60_000);
    expect(deadline.ms).toBeLessThanOrEqual(APPROVAL_TTL_MS);
    const record = async () => (await f.settingsChanges.history({ key: "run.retry.maxRetries" })).entries.map(entry => entry.status);
    f.advance(APPROVAL_TTL_MS + 1);
    // The deadline alone expires it: no approvals read, decision or turn runs first.
    expect(await record()).not.toContain("expired");
    deadline.run();
    await waitFor(async () => (await record()).includes("expired") || undefined, "expired at the deadline");
    await chat.says("Anything new?", "settings", { action: "resolve", keys: ["run.retry.maxRetries"] });
    expect(chat.outcomes().map(outcome => outcome.details.requests[0]!.status)).toEqual(["expired"]);
    expect(chat.outcomes()[0]!.content).toMatch(/expired after 24 hours without a decision; it was not applied\.$/);
  }, 90_000);

  it("Home cannot decide its own request, and settings names keys by one id rule", async () => {
    const f = await gateway();
    const held = await f.settingsChanges.change({ kind: "global" }, [RETRIES(6) as never],
      { actor: { kind: "home", id: f.home.id, sessionId: f.home.id }, reason: "Flaky provider", request: true });
    const [request] = await f.approvals();
    expect(request!.requestId).toBe(held.approval!.requestId);
    // The tool offers no decision, and the decision owner refuses any actor but the maintainer.
    const decided = await f.homeSays("Approve it yourself", "settings", { action: "decide", requestId: request!.requestId });
    expect(decided.isError).toBe(true);
    await expect(f.settingsChanges.decide(request!.requestId, { digest: request!.digest, approved: true,
      decidedBy: { kind: "home", id: f.home.id, sessionId: f.home.id } })).rejects.toMatchObject({ code: "invalid_request", message: expect.stringMatching(/Only the maintainer decides/) });
    expect(await f.approvals()).toHaveLength(1);

    // resolve returns `model.thinking[role=chat]`; the plain id is refused with that id named, by resolve, dry run and change alike.
    const resolvedPlain = await f.homeSays("Read plain thinking", "settings", { action: "resolve", keys: ["model.thinking"] });
    expect(resolvedPlain).toMatchObject({ isError: true, text: expect.stringContaining("use model.thinking[role=chat]") });
    for (const dryRun of [true, false]) {
      const changed = await f.homeSays(`Change plain thinking ${dryRun}`, "settings", { action: "change", reason: "Cheaper", ...(dryRun ? { dryRun } : {}),
        changes: [{ key: "model.thinking", layer: "session", op: "set", value: "low", qualifiers: { role: "chat" } }] });
      expect(dryRun ? JSON.parse(changed.text.slice(changed.text.indexOf("\n") + 1)).changes[0].error.message : changed.text).toContain("use model.thinking[role=chat]");
    }
    // A qualifier that contradicts the id's fixed instance names a different setting.
    const contradicted = await f.homeSays("Change worker thinking via chat id", "settings", { action: "change", reason: "Cheaper", dryRun: true,
      changes: [{ key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low", qualifiers: { role: "worker" } }] });
    expect(contradicted.text).toContain("role=worker is a different setting");
  }, 90_000);
  it("an approval action shares the queue: its preview is approved exactly, applies once, is told, supersedes on a moved state and is never undone", async () => {
    const f = await gateway();
    let state = "absent";
    const applied: unknown[] = [];
    f.settingsChanges.registerAction("project.test", {
      plan: async params => ({ title: `Create project ${(params as { name: string }).name}`, target: { kind: "global" },
        items: [{ label: "Folder", value: `~/Workspace/${(params as { name: string }).name}` }, { label: "Now", value: state }] }),
      apply: async params => { applied.push(params); state = "present"; return { summary: "Created the folder and ran git init on main" }; },
    });
    expect(() => f.settingsChanges.registerAction("project.test", { plan: async () => { throw new Error("unused"); }, apply: async () => ({ summary: "" }) })).toThrow(/already declared/);
    const actor = { kind: "home" as const, id: f.home.id, sessionId: f.home.id };
    const asked = await f.settingsChanges.requestAction("project.test", { name: "demo" }, { actor, reason: "The maintainer asked for a demo project" });
    expect(asked).toMatchObject({ status: "pending", tier: "approve", changes: [], action: { title: "Create project demo" } });
    const listed = (await f.service.invoke(phone(), "settings.approvals", {}) as unknown as { requests: Array<Record<string, unknown> & { requestId: string; digest: string }> }).requests;
    expect(listed).toEqual([expect.objectContaining({ requestId: asked.approval!.requestId, requester: "Home", changes: [],
      action: { subject: "project.test", title: "Create project demo", items: [{ label: "Folder", value: "~/Workspace/demo" }, { label: "Now", value: "absent" }] } })]);
    await expect(f.decide(listed[0]!.requestId, listed[0]!.digest, true)).resolves.toMatchObject({ status: "approved", action: { title: "Create project demo" } });
    expect(applied).toEqual([{ name: "demo" }]);
    await f.homeSays("Anything new?", "settings", { action: "resolve", keys: ["run.retry.maxRetries"] });
    expect(f.outcomes().at(-1)!.details.requests).toEqual([expect.objectContaining({ status: "approved", items: [],
      action: { subject: "project.test", title: "Create project demo", summary: "Created the folder and ran git init on main" } })]);
    expect(f.outcomes().at(-1)!.content).toContain("Create project demo was approved by the maintainer and applied (Created the folder and ran git init on main)");

    // The state the preview showed moved before the tap: superseded, never applied.
    state = "absent";
    const again = await f.settingsChanges.requestAction("project.test", { name: "demo" }, { actor, reason: "Again" });
    state = "present";
    await expect(f.decide(again.approval!.requestId, again.approval!.digest, true)).rejects.toMatchObject({ code: "conflict", message: expect.stringMatching(/superseded/) });
    expect(applied).toHaveLength(1);
    const entries = (await f.settingsChanges.history({ key: "project.test" })).entries;
    expect(entries.map(entry => entry.status).sort()).toEqual(["approved", "pending", "pending", "superseded"]);
    expect(entries.find(entry => entry.status === "approved")).toMatchObject({ refersTo: asked.approval!.requestId, action: true });
    // The Changes log names the action by its preview title.
    const logged = (await f.service.invoke(phone(), "settings.history", { key: "project.test" }) as unknown as { entries: Array<{ status: string; presentation: { label: string; display: { after: string } } }> }).entries;
    expect(logged.find(entry => entry.status === "approved")!.presentation).toMatchObject({ label: "Create project demo", display: { after: "Done" } });
    await expect(f.settingsChanges.undo(asked.approval!.requestId, { actor: { kind: "ui", id: "phone" } })).rejects.toMatchObject({ code: "conflict", message: expect.stringMatching(/not undoable/) });
    transcript.push({ case: "approval action", steps: [{ asked, listed: listed[0]!, entries: entries.map(entry => entry.status) }] });
  }, 90_000);
});
