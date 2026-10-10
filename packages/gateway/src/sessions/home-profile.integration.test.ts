/**
 * Tron Home's learned profile (#731), end to end: the `profile` tool called by a
 * faux Home model inside real activations, the real Knowledge store behind it,
 * the injected profile in the next activation's system prompt, and a delegated
 * worker receiving the brief that cites those items.
 *
 * Failure modes these cases exist for, written before the code they test:
 *  F1 learn writes a confirmed note, or one without its tag, provenance, or the
 *     triggering maintainer message's entry;
 *  F2 the next activation does not carry the item text verbatim, with its ID,
 *     under the stable heading;
 *  F3 refine, supersede or retire destroys the prior revision or leaves the old
 *     item active;
 *  F4 a retired or superseded item is still changed by profile actions;
 *  F5 an over-bound profile is injected partly (truncated) or whole;
 *  F6 the system prompt changes between activations while the profile is unchanged;
 *  F7 a native confirmation or edit, which models neither tags nor retirement,
 *     removes the item from the profile;
 *  F8 Knowledge observes a Home chapter;
 *  F9 a delegated worker's first message lacks the brief the profile informed;
 *  F10 an ordinary session receives the Home-only `profile` tool.
 *
 * The retained artifact is `test-results/home-profile/report.json`.
 */
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentSystemPrompt, type FauxProviderHandle, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { TrustService } from "../admin/trust-service.js";
import { homeChapterObservationExcluded } from "../home/home-owner.js";
import type { KnowledgeRecord } from "../knowledge/knowledge-contract.js";
import { KnowledgeObservationService, type ObservationModel } from "../knowledge/knowledge-observation.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { RuntimeRegistry } from "./runtime-registry.js";

const PROVIDER = "tron-home-profile";
const MODEL_ID = "chat";
const MEMORY_PROVIDER = "tron-home-profile-memory";
const MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: "compactor" };
const MODEL = { provider: PROVIDER, id: MODEL_ID };
const REPORT_PATH = "test-results/home-profile/report.json";
/** The instruction head every Home request carries; a worker's request never does. */
const HOME_MARKER = "## Tron Home";
const PROFILE_HEADING = "## Learned profile";

const report: { generatedAt: string; cases: Array<Record<string, unknown>> } = { generatedAt: new Date().toISOString(), cases: [] };
const roots: string[] = [];
const registries: RuntimeRegistry[] = [];

afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "home-profile"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`home-profile: ${report.cases.length} cases -> ${REPORT_PATH}\n`);
});

function recordCase(name: string, data: Record<string, unknown>): void {
  report.cases.push({ name, ...data });
}

// ---- fixture --------------------------------------------------------------------

type HomeSlot = Awaited<ReturnType<RuntimeRegistry["acquire"]>>;
interface Captured { home: boolean; systemPrompt: string; messages: Array<Record<string, unknown>>; blob: string }
interface Context { systemPrompt: string; messages: Array<Record<string, unknown>> }
type Step = (context: Context) => ReturnType<typeof fauxAssistantMessage>;

interface Fixture {
  registry: RuntimeRegistry;
  knowledge: KnowledgeService;
  store: KnowledgeStore;
  project: string;
  sessionId: string;
  slot: HomeSlot;
  /** Scripted replies, consumed in order per side (Home or worker). */
  home: Step[];
  worker: Step[];
  captured: Captured[];
}

async function fixture(label: string, observation?: ObservationModel): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-profile-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  const project = join(root, "project");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(project, { recursive: true })]);
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
  const faux = fauxProvider({ provider: PROVIDER, models: [{ id: MODEL_ID }], tokensPerSecond: 1_000_000, tokenSize: { min: 10, max: 10 } });
  const memoryFaux = fauxProvider({ provider: MEMORY_PROVIDER, models: [{ id: MEMORY_MODEL.id, reasoning: false }] });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  runtime.registerNativeProvider(memoryFaux.provider);
  const trust = new TrustService(agentDir);
  await trust.set(project, true);
  const registry = new RuntimeRegistry({
    agentDir,
    tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => runtime,
    trust,
    broadcast: () => {},
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    homeMemorySummarizer: () => ({ summarizer: async () => fauxAssistantMessage("HOME-PROFILE-LINE") }),
  });
  registries.push(registry);
  await registry.initialize();
  await waitFor(() => (registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut() || undefined, "catalog cut", { boundMs: 30_000 });
  await registry.catalog("all");

  // The Gateway's own observation exclusion, installed the way gateway-main installs it.
  const store = new KnowledgeStore(registry.knowledgeWorkspace(), () => {});
  const knowledge = new KnowledgeService(store, new KnowledgeObservationService(store, observation, undefined, undefined,
    homeChapterObservationExcluded(() => registry.homeOwner())));
  registry.setKnowledgeService(knowledge);

  // Task recovery runs after listen, as in gateway-main; delegation is refused before it.
  await registry.recoverHomeTasks();
  const designation = await registry.homeOwner().designate({ model: MODEL }, () => MODEL);
  await registry.homeOwner().configureMemory({ model: MEMORY_MODEL });
  const slot = await registry.acquire(designation.sessionId);
  const state: Fixture = { registry, knowledge, store, project, sessionId: designation.sessionId, slot, home: [], worker: [], captured: [] };
  // One route answers every provider request. Home and worker requests are told
  // apart by the Home instruction head, so each script is independent of interleaving.
  faux.setResponses(Array.from({ length: 256 }, () => async (context: TranscriptContext) => {
    // The provider's transcript carries the request's system prompt as its head message.
    const systemPrompt = getCurrentSystemPrompt(context.messages);
    const messages = context.messages as unknown as Array<Record<string, unknown>>;
    const home = systemPrompt.includes(HOME_MARKER);
    state.captured.push({
      home, systemPrompt, messages,
      blob: JSON.stringify(context.messages, (key, value) => key === "timestamp" ? 0 : value),
    });
    const step = (home ? state.home : state.worker).shift();
    if (!step) throw new Error(`no scripted ${home ? "Home" : "worker"} reply for this request`);
    return step({ systemPrompt, messages });
  }));
  return state;
}

/** One Home activation driven by `steps`. Returns the first Home request it made
 * (the prompt it carried) and its last one (the transcript it closed with). */
async function homeActivation(f: Fixture, input: string, steps: Step[]): Promise<{ first: Captured; last: Captured }> {
  f.home.push(...steps);
  const before = f.captured.length;
  await f.slot.prompt(input);
  await waitFor(() => (f.slot.snapshot().configurationBlocker === null && f.home.length === 0) || undefined, "Home activation settled", { boundMs: 30_000 });
  const homeRequests = f.captured.slice(before).filter((request) => request.home);
  const first = homeRequests[0];
  const last = homeRequests.at(-1);
  if (!first || !last) throw new Error("the activation made no Home request");
  return { first, last };
}

type ProfileDetails =
  | { status: "saved"; action: "learn" | "refine" | "supersede" | "retire"; id: string; revisionId: string; kind?: string; reason?: string }
  | { status: "refused"; action: string; reason: string };

/** The `profile` tool results a request carries, oldest first. */
function profileResults(messages: Array<Record<string, unknown>>): ProfileDetails[] {
  return messages
    .filter((message) => message.role === "toolResult" && message.toolName === "profile")
    .map((message) => message.details as ProfileDetails);
}

/** A scripted Home reply that calls `profile` with `args`. */
function profileCall(args: Parameters<typeof fauxToolCall>[1], id: string): Step {
  return () => fauxAssistantMessage(fauxToolCall("profile", args, { id }), { stopReason: "toolUse" });
}
const say = (text: string): Step => () => fauxAssistantMessage(text);

/** The profile section of a system prompt, from its heading to the end. */
function profileSection(systemPrompt: string): string {
  const start = systemPrompt.indexOf(PROFILE_HEADING);
  return start < 0 ? "" : systemPrompt.slice(start);
}

/** The entry of the maintainer message that started the latest activation. */
function latestMaintainerEntryId(f: Fixture): string {
  const entries = f.slot.canonicalSessionEntries() as Array<{ id: string; type: string; message?: { role?: string } }>;
  const user = entries.filter((entry) => entry.type === "message" && entry.message?.role === "user").at(-1);
  if (!user) throw new Error("no maintainer message entry");
  return user.id;
}

async function profileNotes(f: Fixture): Promise<Array<KnowledgeRecord & { kind: "note" }>> {
  const records = (await f.store.list({ kind: "note", scope: "personal", includeSuppressed: true })).records;
  return records.filter((record): record is KnowledgeRecord & { kind: "note" } => record.kind === "note" && record.content.tags?.includes("home-profile") === true);
}

async function noteAt(f: Fixture, id: string, revisionId?: string): Promise<KnowledgeRecord & { kind: "note" }> {
  const record = await f.knowledge.invoke({ operation: "knowledge.read", request: { id, ...(revisionId ? { revisionId } : {}), includeSuppressed: true } }) as KnowledgeRecord | null;
  if (!record || record.kind !== "note") throw new Error(`no note ${id}`);
  return record;
}

// ---- cases ----------------------------------------------------------------------

describe("Tron Home learned profile", () => {
  it("F1/F2: learn writes one unconfirmed, tagged note with its evidence, and the next activation carries it verbatim", async () => {
    const f = await fixture("learn");
    const turn = await homeActivation(f, "Please remember: I prefer short replies.", [
      profileCall({ action: "learn", kind: "preference", text: "I prefer short replies." }, "call-learn-1"),
      say("Saved."),
    ]);
    // The tool call is visible in the transcript, and its result states what was saved.
    const [saved] = profileResults(turn.last.messages);
    expect(saved).toMatchObject({ status: "saved", action: "learn", kind: "preference" });
    expect(JSON.stringify(turn.last.messages)).toContain("I prefer short replies.");

    const [note] = await profileNotes(f);
    expect(note).toBeDefined();
    expect(saved).toMatchObject({ id: note!.id, revisionId: note!.revisionId });
    expect(note!.scope).toBe("personal");
    expect(note!.content.title).toBe("I prefer short replies.");
    expect(note!.content.confirmed).toBe(false);
    expect(note!.content.tags).toEqual(["home-profile", "kind-preference"]);
    expect(note!.provenance).toEqual({
      actor: "agent",
      source: "home",
      sessionId: f.sessionId,
      evidence: [{ sessionEntry: { sessionId: f.sessionId, entryId: latestMaintainerEntryId(f) } }],
    });

    const next = await homeActivation(f, "What do you know about me?", [say("Short.")]);
    const section = profileSection(next.first.systemPrompt);
    expect(section.startsWith(PROFILE_HEADING)).toBe(true);
    expect(section).toContain(`note ${note!.id}`);
    expect(section).toContain("preference, inferred");
    expect(section).toContain("I prefer short replies.");
    recordCase("learn-and-next-activation", { noteId: note!.id, tags: note!.content.tags });
  }, 120_000);

  it("F6: the system prompt is byte-identical across activations while the profile is unchanged", async () => {
    const f = await fixture("stable");
    const before = await homeActivation(f, "hello", [say("hi")]);
    const again = await homeActivation(f, "hello again", [say("hi again")]);
    expect(again.first.systemPrompt).toBe(before.first.systemPrompt);

    // A profile change moves the prompt once; the activation after it is stable again.
    await homeActivation(f, "Remember: answer in English.", [
      profileCall({ action: "learn", kind: "preference", text: "Answer in English." }, "call-stable-1"),
      say("Saved."),
    ]);
    const changed = await homeActivation(f, "one more", [say("ok")]);
    expect(changed.first.systemPrompt).not.toBe(before.first.systemPrompt);
    const settled = await homeActivation(f, "and again", [say("ok")]);
    expect(settled.first.systemPrompt).toBe(changed.first.systemPrompt);
    recordCase("prompt-stability", { stableWhileUnchanged: true, movesOnChange: true });
  }, 120_000);

  it("F3: refine keeps the prior revision and replaces the injected text; supersede and retire leave injection", async () => {
    const f = await fixture("lifecycle");
    await homeActivation(f, "remember a", [
      profileCall({ action: "learn", kind: "preference", text: "Use metric units." }, "call-life-1"),
      say("saved"),
    ]);
    const [original] = await profileNotes(f);
    const originalRevision = original!.revisionId;

    const refine = await homeActivation(f, "refine it", [
      profileCall({ action: "refine", id: original!.id, text: "Use metric units everywhere." }, "call-life-2"),
      say("refined"),
    ]);
    expect(profileResults(refine.last.messages)).toEqual([expect.objectContaining({ status: "saved", action: "refine", id: original!.id })]);
    const refined = await noteAt(f, original!.id);
    expect(refined.revisionId).not.toBe(originalRevision);
    expect(refined.content.title).toBe("Use metric units everywhere.");
    expect(refined.content.confirmed).toBe(false);
    expect(refined.content.tags).toEqual(["home-profile", "kind-preference"]);
    expect((await noteAt(f, original!.id, originalRevision)).content.title).toBe("Use metric units.");
    const afterRefine = await homeActivation(f, "after refine", [say("ok")]);
    const refinedSection = profileSection(afterRefine.first.systemPrompt);
    expect(refinedSection).toContain("Use metric units everywhere.");
    expect(refinedSection.split(original!.id).length - 1).toBe(1);

    const supersede = await homeActivation(f, "replace it", [
      profileCall({ action: "supersede", id: original!.id, kind: "preference", text: "Use metric units, and state conversions." }, "call-life-3"),
      say("superseded"),
    ]);
    const [replaced] = profileResults(supersede.last.messages);
    expect(replaced).toMatchObject({ status: "saved", action: "supersede" });
    const afterSupersede = await homeActivation(f, "after supersede", [say("ok")]);
    expect(afterSupersede.first.systemPrompt).not.toContain(`note ${original!.id}`);
    expect(afterSupersede.first.systemPrompt).toContain("Use metric units, and state conversions.");
    const replacement = await noteAt(f, (replaced as { id: string }).id);
    expect(replacement.relations).toEqual([{ type: "supersedes", recordId: original!.id, revisionId: refined.revisionId }]);
    // The superseded record stays readable as history.
    expect((await noteAt(f, original!.id)).content.title).toBe("Use metric units everywhere.");

    const retire = await homeActivation(f, "retire it", [
      profileCall({ action: "retire", id: replacement.id, reason: "The maintainer changed topic." }, "call-life-4"),
      say("retired"),
    ]);
    expect(profileResults(retire.last.messages)).toEqual([expect.objectContaining({ status: "saved", action: "retire", id: replacement.id })]);
    const afterRetire = await homeActivation(f, "after retire", [say("ok")]);
    expect(afterRetire.first.systemPrompt).not.toContain(`note ${replacement.id}`);
    const retired = await noteAt(f, replacement.id);
    expect(retired.content.retired).toBe(true);
    expect(retired.provenance.reason).toBe("The maintainer changed topic.");
    recordCase("refine-supersede-retire", { refinedRevisionKept: true, supersededLeftInjection: true, retiredLeftInjection: true });
  }, 120_000);

  it("F4: a retired item cannot be refined, and a superseded item cannot be superseded again", async () => {
    const f = await fixture("refusals");
    await homeActivation(f, "remember two", [
      profileCall({ action: "learn", kind: "fact", text: "The office is in Lisbon." }, "call-refuse-1"),
      profileCall({ action: "learn", kind: "fact", text: "The team is in Porto." }, "call-refuse-2"),
      say("saved"),
    ]);
    const byText = (text: string) => (async () => (await profileNotes(f)).find((note) => note.content.title === text))();
    const lisbon = await byText("The office is in Lisbon.");
    const porto = await byText("The team is in Porto.");
    await homeActivation(f, "the office moved", [
      profileCall({ action: "supersede", id: lisbon!.id, kind: "fact", text: "The office is in Madrid." }, "call-refuse-3"),
      say("superseded"),
    ]);
    // The superseded item is refused; its replacement stays active.
    const again = await homeActivation(f, "supersede it again", [
      profileCall({ action: "supersede", id: lisbon!.id, kind: "fact", text: "The office is in Rome." }, "call-refuse-4"),
      say("refused"),
    ]);
    expect(profileResults(again.last.messages)).toEqual([expect.objectContaining({ status: "refused", action: "supersede" })]);
    const profileAfterSupersede = await profileNotes(f);
    expect(profileAfterSupersede.map((note) => note.content.title).sort()).toEqual(["The office is in Madrid.", "The office is in Lisbon.", "The team is in Porto."].sort());

    // A retired item is refused by refine, and its revision does not move.
    await homeActivation(f, "retire the team", [
      profileCall({ action: "retire", id: porto!.id, reason: "stale" }, "call-refuse-5"),
      say("retired"),
    ]);
    const revisionBefore = (await noteAt(f, porto!.id)).revisionId;
    const refusal = await homeActivation(f, "refine a retired item", [
      profileCall({ action: "refine", id: porto!.id, text: "Changed." }, "call-refuse-6"),
      say("refused"),
    ]);
    const [result] = profileResults(refusal.last.messages);
    expect(result).toMatchObject({ status: "refused", action: "refine" });
    expect((await noteAt(f, porto!.id)).revisionId).toBe(revisionBefore);
    expect((await noteAt(f, porto!.id)).content.title).toBe("The team is in Porto.");
    recordCase("superseded-and-retired-refused", { supersedeRefused: true, refineRefused: true, revisionUnchanged: true });
  }, 120_000);

  it("F7: a native confirmation keeps the item in the profile, now marked confirmed", async () => {
    const f = await fixture("native");
    await homeActivation(f, "remember", [
      profileCall({ action: "learn", kind: "delegation-default", text: "Delegate reviews to a cheaper model." }, "call-native-1"),
      say("saved"),
    ]);
    const [item] = await profileNotes(f);
    // The native owner edits from its typed draft, which models neither tags nor retirement.
    const { tags: _tags, ...typedContent } = item!.content;
    await f.knowledge.invoke({ operation: "knowledge.note.update", request: {
      commandId: "native-confirm-0001",
      recordId: item!.id,
      expectedRevision: item!.revisionId,
      confirmedByUser: true,
      record: { kind: "note", scope: item!.scope, provenance: item!.provenance, relations: item!.relations, content: { ...typedContent, confirmed: true } },
    } });
    const next = await homeActivation(f, "after confirm", [say("ok")]);
    expect(next.first.systemPrompt).toContain(`note ${item!.id}`);
    expect(next.first.systemPrompt).toContain("delegation-default, confirmed");
    expect((await noteAt(f, item!.id)).content.tags).toEqual(["home-profile", "kind-delegation-default"]);

    // A native correction, from the same typed model, keeps the item too, now corrected.
    const confirmed = await noteAt(f, item!.id);
    await f.knowledge.invoke({ operation: "knowledge.correction", request: {
      commandId: "native-correct-0001",
      confirmedByUser: true,
      recordId: item!.id,
      expectedRevision: confirmed.revisionId,
      replacement: { kind: "note", scope: confirmed.scope, provenance: confirmed.provenance, relations: confirmed.relations,
        content: { title: "Delegate reviews to a cheaper model, by default.", role: "workflow", confirmed: true } },
      relation: { type: "corrects", recordId: item!.id, revisionId: confirmed.revisionId },
    } });
    const corrected = await homeActivation(f, "after correction", [say("ok")]);
    expect(corrected.first.systemPrompt).toContain("Delegate reviews to a cheaper model, by default.");
    expect(corrected.first.systemPrompt.split(item!.id).length - 1).toBe(1);
    expect((await noteAt(f, item!.id)).content.tags).toEqual(["home-profile", "kind-delegation-default"]);
    recordCase("native-confirm-keeps-profile", { injectedMarkedConfirmed: true, correctionKeepsProfile: true });
  }, 120_000);

  it("F5: an over-bound profile is not injected at all, and the section tells Home to consolidate", async () => {
    const f = await fixture("bound");
    const ids: string[] = [];
    for (let index = 0; index < 40; index += 1) {
      const { record } = await f.knowledge.invoke({ operation: "knowledge.note.create", request: {
        commandId: `bound-note-${String(index).padStart(4, "0")}-seed`,
        record: {
          kind: "note", scope: "personal", provenance: { actor: "agent", source: "home", sessionId: f.sessionId, evidence: [] }, relations: [],
          content: { title: `Bound item ${index} ${"x".repeat(280)}`, role: "preference", confirmed: false, tags: ["home-profile", "kind-preference"] },
        },
      } }) as { record: KnowledgeRecord };
      ids.push(record.id);
    }
    const next = await homeActivation(f, "over the bound", [say("ok")]);
    const section = profileSection(next.first.systemPrompt);
    expect(section).toContain("consolidate");
    for (const word of ["refine", "supersede", "retire"]) expect(section).toContain(word);
    // No item text, whole or partial, is injected over the bound.
    expect(section).not.toContain("Bound item");
    expect(section).not.toContain("xxxxxxxxxx");
    // The notice names items by ID so Home can consolidate them, within the same bound.
    expect(ids.some((id) => section.includes(id))).toBe(true);
    expect(Buffer.byteLength(section, "utf8")).toBeLessThan(16 * 1024);
    recordCase("over-bound-refused", { items: ids.length, sectionBytes: Buffer.byteLength(section, "utf8") });
  }, 120_000);

  it("F9: a delegated worker receives the brief, which cites the profile item it applied", async () => {
    const f = await fixture("delegate");
    await homeActivation(f, "remember", [
      profileCall({ action: "learn", kind: "delegation-default", text: "Prefer the cheaper model for reviews." }, "call-deleg-1"),
      say("saved"),
    ]);
    const [item] = await profileNotes(f);
    // The worker's replies are queued before the delegating activation can start it.
    f.worker.push(() => fauxAssistantMessage(fauxToolCall("report", { resultId: "profile-result-0001", outcome: "final", text: "Reviewed.", evidence: ["checked"] }, { id: "worker-report-0001" }), { stopReason: "toolUse" }));
    f.worker.push(say("done"));
    // The model composes the brief from the injected profile, as the operating
    // context instructs: this script lists each applied item in the brief.
    const delegate: Step = (context) => {
      const cited = profileSection(context.systemPrompt).split("\n").filter((line) => line.includes(`note ${item!.id}`));
      expect(cited).toHaveLength(1);
      const intent = ["Review the change.", "", "Preferences applied:", ...cited.map((line) => `- ${line.replace(/^- /, "")}`)].join("\n");
      return fauxAssistantMessage(fauxToolCall("delegate", { taskId: "profile-task-0001", intent, target: f.project }, { id: "delegate-call-0001" }), { stopReason: "toolUse" });
    };
    await homeActivation(f, "review it", [delegate, say("delegated")]);
    await waitFor(() => f.captured.some((request) => !request.home && request.blob.includes("Preferences applied")) || undefined, "the worker's first request", { boundMs: 60_000 });
    const worker = f.captured.find((request) => !request.home && request.blob.includes("Preferences applied"))!;
    expect(worker.blob).toContain(`note ${item!.id}`);
    expect(worker.blob).toContain("Prefer the cheaper model for reviews.");
    recordCase("brief-carries-preferences", { noteId: item!.id });
  }, 120_000);

  it("F8: Knowledge does not observe a Home chapter, while an ordinary session with the same grant is observed", async () => {
    const infer = vi.fn(async (_input: { sourceText: string }) => JSON.stringify({ observations: [{
      text: "The maintainer prefers concise answers.", attribution: "user", certainty: "certain", observedAt: "2026-01-01T00:00:01Z",
    }] }));
    const f = await fixture("observation", { infer });
    const config = await f.store.config();
    await f.store.configure("home-profile-observation-grant", {
      ...config,
      eligibility: { ...config.eligibility, allSessions: true as const },
      observation: { ...config.observation, enabled: true, model: `${PROVIDER}/${MODEL_ID}` },
    });
    await homeActivation(f, "HOME-ONLY-SENTENCE I prefer concise answers.", [say("Understood.")]);
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    f.worker.push(say("ordinary reply"));
    await ordinary.prompt("ORDINARY-SENTENCE I prefer concise answers.");
    await waitFor(async () => (await f.store.list({ kind: "observation" })).records.length === 1 || undefined, "the ordinary session observation", { boundMs: 30_000 });
    expect(infer).toHaveBeenCalledTimes(1);
    const observed = infer.mock.calls[0]![0].sourceText;
    expect(observed).toContain("ORDINARY-SENTENCE");
    expect(observed).not.toContain("HOME-ONLY-SENTENCE");
    // A disabled Home's chapters remain Home history and stay excluded.
    const homeSessionId = (await f.registry.homeOwner().status()).sessionId!;
    await f.registry.homeOwner().disable();
    expect(homeChapterObservationExcluded(() => f.registry.homeOwner())(homeSessionId)).toBe(true);
    expect(homeChapterObservationExcluded(() => f.registry.homeOwner())(ordinary.id)).toBe(false);
    recordCase("home-chapter-not-observed", { observedInferences: infer.mock.calls.length });
  }, 120_000);

  it("F10: an ordinary session never receives the profile tool", async () => {
    const f = await fixture("ordinary");
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const context = await ordinary.context() as unknown as { availableTools: Array<{ name: string }> };
    const names = context.availableTools.map((tool) => tool.name);
    expect(names).not.toContain("profile");
    recordCase("ordinary-has-no-profile-tool", { tools: names.length });
  }, 120_000);
});
