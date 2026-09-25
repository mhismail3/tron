import { afterEach, describe, expect, it, vi } from "vitest";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, type Context } from "@earendil-works/pi-ai";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { DEFAULT_KNOWLEDGE_CONFIG } from "./knowledge-contract.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeObservationService, ModelRuntimeObservationModel, projectObservationEntry, type ObservationModel } from "./knowledge-observation.js";
import { KnowledgeService } from "./knowledge-service.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  vi.useRealTimers();
  await Promise.all(workspaces.splice(0).map(workspace => workspace.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture(model: ObservationModel, workRegistry?: GatewayWorkRegistry): Promise<{ store: KnowledgeStore; observer: KnowledgeObservationService }> {
  const root = await mkdtemp(join(tmpdir(), "tron-observer-")); roots.push(root);
  const workspace = new TronWorkspace(join(root, "home")); workspaces.push(workspace);
  const store = new KnowledgeStore(workspace);
  await store.configure("observer-config", {
    ...DEFAULT_KNOWLEDGE_CONFIG,
    eligibility: { ...DEFAULT_KNOWLEDGE_CONFIG.eligibility, sessionIds: ["session-1"] },
    observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true },
  });
  return { store, observer: new KnowledgeObservationService(store, model, workRegistry) };
}

const entries = [
  { type: "session", id: "session-header", timestamp: "2026-01-01T00:00:00Z" },
  { type: "message", id: "entry-1", timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: "Remember that the release is Friday." } },
  { type: "message", id: "entry-2", timestamp: "2026-01-01T00:00:02Z", message: { role: "assistant", content: [{ type: "text", text: "I will keep that date." }, { type: "thinking", thinking: "private reasoning omitted" }] } },
] as const;

const output = JSON.stringify({ observations: [{ text: "The release is planned for Friday.", attribution: "user", certainty: "qualified", observedAt: "2026-01-01T00:00:01Z" }] });

/** Waits for an observable condition. `waitFor` polls on real timers, so store
 * I/O still progresses between its polls while a test's fake clock stays under
 * the test's control; tests that would otherwise sleep advance it explicitly. */
async function waitFor(predicate: () => boolean | Promise<boolean>): Promise<void> {
  await vi.waitFor(async () => expect(await predicate()).toBe(true), { timeout: 3_000, interval: 10 });
}

describe("KnowledgeObservationService", () => {
  it("supplies the configured model with the exact observation JSON contract", async () => {
    const completeSimple = vi.fn(async (_model: unknown, _context: Context, _options: unknown) => fauxAssistantMessage(output));
    const model = fauxProvider({ provider: "observer-output-contract" }).getModel();
    const adapter = new ModelRuntimeObservationModel({ completeSimple } as unknown as ModelRuntime, model);
    const signal = new AbortController().signal;
    const sourceText = "[2026-01-01T00:00:01Z] user: The release is Friday.";
    expect(await adapter.infer({ sessionId: "session-1", range: { sessionId: "session-1", fromEntryId: "entry-1", toEntryId: "entry-1", entryIds: ["entry-1"], entryDigest: "a".repeat(64) }, sourceText, outcome: "completed", signal, maxOutputChars: 8_000 })).toBe(output);
    expect(completeSimple).toHaveBeenCalledTimes(1);
    const [selected, context, options] = completeSimple.mock.calls[0]!;
    expect(selected).toBe(model);
    const schemaExample = JSON.parse(context.systemPrompt!.split("\n").find(line => line.startsWith('{"observations":['))!);
    expect(Object.keys(schemaExample.observations[0]).sort()).toEqual(["attribution", "certainty", "observedAt", "text"]);
    expect(context.systemPrompt).toContain("user, assistant, tool, system, or unknown");
    expect(context.systemPrompt).toContain("certain, qualified, or uncertain");
    expect(context.systemPrompt).toContain('{"observations":[]}');
    expect(context.messages[0]?.content).toBe(sourceText);
    expect(options).toMatchObject({ signal, maxTokens: 2_000 });
  });

  it("does not publish after disposal during an admitted inference", async () => {
    let observer!: KnowledgeObservationService;
    const work = new GatewayWorkRegistry();
    const infer = vi.fn(async () => { observer.dispose(); return output; });
    const { store, observer: created } = await fixture({ infer }, work); observer = created;
    observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 1);
    await waitFor(() => work.size === 0);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
  });

  it("does not merge distinct terminal envelopes while an older inference is busy", async () => {
    vi.useFakeTimers();
    let release!: (value: string) => void;
    const blocked = new Promise<string>(resolve => { release = resolve; });
    const infer = vi.fn(async (input) => input.range.invocationIds?.includes("invocation-a") ? blocked : output.replace("planned for Friday", "failed turn"));
    const { store, observer } = await fixture({ infer });
    const first = { type: "message", id: "turn-a", timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: "first turn" } };
    const second = { type: "message", id: "turn-b", timestamp: "2026-01-01T00:00:02Z", message: { role: "user", content: "failed turn" } };
    observer.admit({ sessionId: "session-1", entries: [first], outcome: "completed", invocationId: "invocation-a" });
    await waitFor(() => infer.mock.calls.length === 1);
    observer.admit({ sessionId: "session-1", entries: [second], outcome: "failed", invocationId: "invocation-c" });
    await vi.advanceTimersByTimeAsync(25);
    expect(infer).toHaveBeenCalledTimes(1);
    release(output);
    await waitFor(() => infer.mock.calls.length === 2);
    expect(infer.mock.calls[1]?.[0].outcome).toBe("failed");
    expect(infer.mock.calls[1]?.[0].range.invocationIds).toEqual(["invocation-c"]);
    await waitFor(async () => (await store.status()).coverageCount === 2);
    observer.dispose();
    await vi.advanceTimersByTimeAsync(1_000);
  });

  it("rejects a model result that arrives after the configured attempt deadline", async () => {
    const infer = vi.fn(async (input: { signal: AbortSignal }) => {
      await new Promise<void>(resolve => input.signal.addEventListener("abort", () => resolve(), { once: true }));
      return output;
    });
    const { store, observer } = await fixture({ infer });
    const config = await store.config();
    await store.configure("observer-short-deadline", { ...config, observation: { ...config.observation, timeoutMs: 1_000, maxAttempts: 1 } });
    observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
    await waitFor(async () => (await store.pendingObservationCoverage()).some(coverage => coverage.disposition === "failed"));
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
    expect((await store.pendingObservationCoverage()).at(-1)?.disposition).toBe("failed");
    observer.dispose();
  });

  it("keeps work ownership through a timed-out attempt and active retry", async () => {
    const work = new GatewayWorkRegistry();
    let calls = 0;
    let release!: (value: string) => void;
    const retry = new Promise<string>(resolve => { release = resolve; });
    const infer = vi.fn(async (input: { signal: AbortSignal }) => {
      calls += 1;
      if (calls === 1) {
        await new Promise<void>(resolve => input.signal.addEventListener("abort", () => resolve(), { once: true }));
        throw new Error("timed out");
      }
      return retry;
    });
    const { store, observer } = await fixture({ infer }, work);
    const config = await store.config();
    await store.configure("observer-retry-deadline", { ...config, observation: { ...config.observation, timeoutMs: 1_000, maxAttempts: 2 } });
    observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
    await waitFor(() => calls === 2);
    expect(work.size).toBe(1);
    work.beginDrain();
    await work.requestCancellation();
    release(output);
    await waitFor(() => work.size === 0);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
    observer.dispose();
  });

  it("reserves terminal outcome space and redacts quoted credentials and URL userinfo", async () => {
    const infer = vi.fn(async (input) => {
      expect(input.sourceText).toMatch(/\[terminal outcome: completed\]$/);
      expect(input.sourceText).toContain("safe tail");
      expect(input.sourceText).not.toContain("quoted-secret");
      expect(input.sourceText).not.toContain("user:password@");
      return output;
    });
    const { store, observer } = await fixture({ infer });
    const sensitiveText = `{"password":"quoted-secret"} https://user:password@example.test/private safe tail ${"x".repeat(760)}`;
    const projected = projectObservationEntry({ type: "message", id: "redaction-entry", timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: sensitiveText } });
    expect(projected?.text).toContain("[redacted]");
    const config = await store.config();
    await store.configure("observer-terminal-bound", { ...config, observation: { ...config.observation, maxInputChars: 1_000 } });
    observer.admit({ sessionId: "session-1", entries: [{ type: "message", id: "redaction-entry", timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: sensitiveText } }], outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 1);
    await waitFor(async () => (await store.list({ kind: "observation" })).records.length === 1);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(1);
    observer.dispose();
  });

  it("does not publish a truncated canonical entry as successful coverage", async () => {
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer });
    const long = { type: "message", id: "long-entry", timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: "x".repeat(21_000) } };
    const config = await store.config();
    await store.configure("observer-small-input", { ...config, observation: { ...config.observation, maxInputChars: 1_000 } });
    observer.admit({ sessionId: "session-1", entries: [long], outcome: "completed" });
    await waitFor(async () => (await store.status()).coverageCount === 1);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
    expect((await store.observationCoverageForScope("session-1")).at(-1)?.disposition).toBe("unavailable");
    observer.dispose();
  });

  it("retains the exact terminal cut when durable admission fails, then admits it once", async () => {
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer });
    const failure = vi.spyOn(store, "setCoverage").mockRejectedValueOnce(new Error("observer store unavailable"));
    observer.admit({ sessionId: "session-1", entries: [...entries], outcome: "completed", invocationId: "admission-retry-invocation" });
    await waitFor(() => failure.mock.calls.length >= 1);
    // The failed admission must not leak the cut to the model...
    expect(infer).not.toHaveBeenCalled();
    // ...and must not be dropped: the retained cut is admitted after the store recovers.
    await waitFor(async () => (await store.list({ kind: "observation" })).records.length === 1);
    expect(infer).toHaveBeenCalledTimes(1);
    observer.dispose();
  });

  it("does not persist exclusion when the privacy read fails, then retries the exact cut", async () => {
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer });
    const scopeRead = vi.spyOn(store, "scopeExcluded").mockRejectedValueOnce(new Error("privacy store unavailable"));
    observer.admit({ sessionId: "session-1", entries: [...entries], outcome: "completed", invocationId: "scope-read-retry" });
    await waitFor(() => scopeRead.mock.calls.length >= 1);
    expect(infer).not.toHaveBeenCalled();
    await waitFor(async () => (await store.status()).coverage.observedCount === 1);
    expect((await store.status()).coverage.excludedCount).toBe(0);
    expect(infer).toHaveBeenCalledTimes(1);
    observer.dispose();
  });

  it("does not requeue or write after disposal wins an in-flight privacy read", async () => {
    let release!: (value: boolean) => void;
    const blocked = new Promise<boolean>(resolve => { release = resolve; });
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer });
    const scopeRead = vi.spyOn(store, "scopeExcluded").mockReturnValueOnce(blocked);
    observer.admit({ sessionId: "session-1", entries: [...entries], outcome: "completed", invocationId: "dispose-scope-read" });
    await waitFor(() => scopeRead.mock.calls.length === 1);
    const coverageWrites = vi.spyOn(store, "setCoverage");
    observer.dispose();
    release(false);
    await Promise.resolve();
    await Promise.resolve();
    expect(coverageWrites).not.toHaveBeenCalled();
    expect(infer).not.toHaveBeenCalled();
  });

  it("retains the exact cut when an excluded coverage record cannot be written, then records it once", async () => {
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer });
    // A scope-excluded range is never sent to the model, but its disposition is
    // still coverage authority: a failed write must be retried, not dropped.
    await store.setScopeExclusion("observer-exclusion-fence", { sessionId: "session-1" }, true, "privacy");
    const failure = vi.spyOn(store, "setCoverage").mockRejectedValueOnce(new Error("observer store unavailable"));
    observer.admit({ sessionId: "session-1", entries: [...entries], outcome: "completed", invocationId: "excluded-retry-invocation" });
    await waitFor(() => failure.mock.calls.length >= 1);
    expect(infer).not.toHaveBeenCalled();
    await waitFor(async () => (await store.observationCoverageForScope("session-1"))
      .some((coverage) => coverage.disposition === "excluded"));
    expect(infer).not.toHaveBeenCalled();
    observer.dispose();
  });

  it("admits a cut that exactly fills the model input including its terminal newline", async () => {
    const maxInputChars = 1_000;
    const infer = vi.fn(async (input) => {
      expect(input.sourceText.length).toBeLessThanOrEqual(maxInputChars);
      return output;
    });
    const { store, observer } = await fixture({ infer });
    const prefix = "[2026-01-01T00:00:01Z] user: ";
    const terminal = "[terminal outcome: completed]";
    // Exactly the remaining budget once the unconditional terminal newline and
    // outcome suffix are reserved.
    const exactLength = maxInputChars - prefix.length - 1 - terminal.length;
    const config = await store.config();
    await store.configure("observer-exact-bound", { ...config, observation: { ...config.observation, maxInputChars } });
    observer.admit({ sessionId: "session-1", entries: [{ type: "message", id: "boundary-entry", timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: "x".repeat(exactLength) } }], outcome: "completed", invocationId: "boundary-invocation" });
    await waitFor(() => infer.mock.calls.length === 1);
    expect(infer.mock.calls[0]![0].sourceText.length).toBe(maxInputChars);

    // One character more cannot hold the complete cut, so it is recorded as
    // explicitly unavailable instead of publishing a truncated prompt.
    observer.admit({ sessionId: "session-1", entries: [{ type: "message", id: "boundary-overflow-entry", timestamp: "2026-01-01T00:00:02Z", message: { role: "user", content: "x".repeat(exactLength + 1) } }], outcome: "completed", invocationId: "boundary-overflow-invocation" });
    await waitFor(async () => (await store.observationCoverageForScope("session-1")).some(coverage => coverage.disposition === "unavailable"));
    expect(infer).toHaveBeenCalledTimes(1);
    observer.dispose();
  });

  it("redacts machine-local paths at the model boundary without rewriting URLs", () => {
    const projected = projectObservationEntry({
      type: "message",
      id: "machine-path-entry",
      timestamp: "2026-01-01T00:00:01Z",
      message: {
        role: "bashExecution",
        command: "cat /tmp/secret/notes.txt",
        output: [
          "/Volumes/Work/private/report.md",
          "~/Documents/keys.pem",
          "C:\\Users\\me\\secret.txt",
          "see https://example.test/tmp/public for docs",
        ].join("\n"),
      },
    });
    const text = projected!.text;
    expect(text).not.toContain("/tmp/secret");
    expect(text).not.toContain("/Volumes/Work");
    expect(text).not.toContain("~/Documents");
    expect(text).not.toContain("secret.txt");
    // A URL authority keeps its path: the root is not preceded by a path boundary.
    expect(text).toContain("https://example.test/tmp/public");
  });

  it("bounds prospective admission and rejects new cuts rather than evicting admitted cuts", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-observer-shed-")); roots.push(root);
    const workspace = new TronWorkspace(join(root, "home")); workspaces.push(workspace);
    const store = new KnowledgeStore(workspace);
    await store.configure("observer-shed-config", {
      ...DEFAULT_KNOWLEDGE_CONFIG,
      eligibility: { ...DEFAULT_KNOWLEDGE_CONFIG.eligibility, sessionIds: ["session-1"] },
      observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true },
    });
    let release: (() => void) | undefined;
    const infer = vi.fn(async () => new Promise<string>((resolve) => { release = () => resolve(output); }));
    const shed: number[] = [];
    const observer = new KnowledgeObservationService(store, { infer }, undefined, (fact) => shed.push(fact.dropped));
    const admissions: boolean[] = [];
    for (let index = 0; index < 70; index += 1) {
      admissions.push(observer.admit({
        sessionId: "session-1",
        entries: [{ type: "message", id: `shed-entry-${index}`, timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: `turn ${index}` } }],
        outcome: "completed",
        invocationId: `shed-invocation-${index}`,
      }));
    }
    // The active cut consumes its reservation too. Only the new excess cuts are
    // rejected; no asynchronous gap-write backlog can bypass the queue limit.
    expect(admissions.slice(0, 64)).toEqual(Array(64).fill(true));
    expect(admissions.slice(64)).toEqual(Array(6).fill(false));
    expect(shed.reduce((total, dropped) => total + dropped, 0)).toBe(6);
    observer.dispose();
    release?.();
  });

  it("rejects an oversized retained payload before copying or serializing it into the observation queue", async () => {
    const infer = vi.fn(async () => output);
    const diagnostics: number[] = [];
    const { store, observer: unused } = await fixture({ infer });
    unused.dispose();
    const observer = new KnowledgeObservationService(store, { infer }, undefined, fact => diagnostics.push(fact.dropped));
    const accepted = observer.admit({ sessionId: "session-1", outcome: "completed", entries: [{
      type: "message", id: "oversized-retained-entry", timestamp: "2026-01-01T00:00:01Z",
      message: { role: "user", content: "x".repeat(6 * 1_024 * 1_024) },
    }] });
    expect(accepted).toBe(false);
    expect(diagnostics).toEqual([1]);
    expect(infer).not.toHaveBeenCalled();
    expect((await store.status()).coverageCount).toBe(0);
    observer.dispose();
  });

  it("owns pre-inference store reads until they settle after disposal", async () => {
    const work = new GatewayWorkRegistry();
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer }, work);
    const config = await store.config();
    let release!: () => void;
    const waiting = new Promise<void>(resolve => { release = resolve; });
    const read = vi.spyOn(store, "config").mockImplementationOnce(async () => { await waiting; return config; });
    try {
      observer.admit({ sessionId: "session-1", entries: [...entries], outcome: "completed" });
      expect(work.size).toBe(1);
      observer.dispose();
      expect(work.size).toBe(1);
      release();
      await work.waitUntilSettled();
      expect(work.size).toBe(0);
      expect((await store.status()).coverageCount).toBe(0);
      expect(infer).not.toHaveBeenCalled();
    } finally { release(); read.mockRestore(); observer.dispose(); }
  });

  it("coalesces and durably deduplicates canonical no-tool turns without forwarding thinking", async () => {
    vi.useFakeTimers();
    const infer = vi.fn(async (input) => {
      expect(input.sourceText).not.toContain("private reasoning omitted");
      return output;
    });
    const { store, observer } = await fixture({ infer });
    observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 1);
    await waitFor(async () => (await store.list({ kind: "observation" })).records.length === 1);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(1);
    const tool = await new KnowledgeService(store, observer).tool({ action: "search", query: "release", limit: 8 });
    expect(tool.text).toContain("release");
    expect(JSON.stringify(tool.details).length).toBeLessThan(8_000);
    observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
    await vi.advanceTimersByTimeAsync(50);
    expect(infer).toHaveBeenCalledTimes(1);
    const nextEntries = [...entries, { type: "message", id: "entry-3", timestamp: "2026-01-01T00:00:03Z", message: { role: "user", content: "The date is still Friday." } }];
    observer.admit({ sessionId: "session-1", entries: nextEntries, outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 2);
    await waitFor(async () => (await store.list({ kind: "observation" })).records.length === 2);
    expect(infer.mock.calls[1]?.[0].sourceText).toContain("The date is still Friday");
    expect(infer.mock.calls[1]?.[0].sourceText).not.toContain("release is Friday");
    observer.dispose();
    await vi.advanceTimersByTimeAsync(25);
  });

  it("does not replay a committed second chunk when a later snapshot includes all chunks", async () => {
    vi.useFakeTimers();
    const infer = vi.fn(async (input) => output.replace("planned for Friday", input.sourceText.includes("entry-3") ? "the date is still Friday" : "planned for Friday"));
    const { store, observer } = await fixture({ infer });
    observer.admit({ sessionId: "session-1", entries: [entries[0], entries[1]], outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 1);
    const third = { type: "message", id: "entry-3", timestamp: "2026-01-01T00:00:03Z", message: { role: "user", content: "The date is still Friday." } } as const;
    observer.admit({ sessionId: "session-1", entries: [entries[0], entries[1], third], outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 2);
    observer.admit({ sessionId: "session-1", entries: [entries[0], entries[1], third], outcome: "completed" });
    // The already-covered snapshot adds no inference. The next snapshot proves
    // that positively: its cut must hold only the new entry, so a replay of the
    // committed chunks would land in this call instead of entry-4 alone.
    const fourth = { type: "message", id: "entry-4", timestamp: "2026-01-01T00:00:04Z", message: { role: "user", content: "The date moved to Monday." } };
    observer.admit({ sessionId: "session-1", entries: [entries[0], entries[1], third, fourth], outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 3);
    expect(infer.mock.calls[2]?.[0].sourceText).toContain("The date moved to Monday");
    expect(infer.mock.calls[2]?.[0].sourceText).not.toContain("The date is still Friday");
    observer.dispose();
    await vi.advanceTimersByTimeAsync(25);
  });

  it("treats empty allowlists as an excluded, incomplete scope", async () => {
    vi.useFakeTimers();
    const root = await mkdtemp(join(tmpdir(), "tron-observer-scope-")); roots.push(root);
    const workspace = new TronWorkspace(join(root, "home")); workspaces.push(workspace);
    const store = new KnowledgeStore(workspace);
    await store.configure("observer-scope-config", { ...DEFAULT_KNOWLEDGE_CONFIG, observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true } });
    const infer = vi.fn(async () => output);
    const observer = new KnowledgeObservationService(store, { infer });
    observer.admit({ sessionId: "unselected-session", entries, outcome: "completed" });
    await waitFor(async () => (await store.status()).coverageCount === 1);
    expect(infer).not.toHaveBeenCalled();
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
    observer.dispose();
    await vi.advanceTimersByTimeAsync(25);
  });

  it("observes new sessions across projects only with an explicit global grant", async () => {
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer });
    try {
      const config = await store.config();
      await store.configure("observer-global-config", { ...config, eligibility: { ...config.eligibility, allSessions: true, sessionIds: [], projectIds: [] } });
      observer.admit({ sessionId: "new-project-session", projectId: "another-project", entries, outcome: "completed" });
      observer.admit({ sessionId: "new-unscoped-session", entries, outcome: "completed" });
      await waitFor(async () => (await store.status()).coverage.observedCount === 2);
      expect(infer).toHaveBeenCalledTimes(2);
      expect((await store.list({ kind: "observation" })).records.map(record => record.provenance.sessionId).sort()).toEqual(["new-project-session", "new-unscoped-session"]);
    } finally { observer.dispose(); }
  });

  it("keeps explicit session and project exclusions authoritative under global scope", async () => {
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer });
    try {
      const config = await store.config();
      await store.configure("observer-global-exclusions", { ...config, eligibility: {
        allSessions: true, sessionIds: ["private-session"], projectIds: ["private-project"],
        excludedSessionIds: ["private-session"], excludedProjectIds: ["private-project"],
      } });
      observer.admit({ sessionId: "private-session", entries, outcome: "completed" });
      observer.admit({ sessionId: "another-session", projectId: "private-project", entries, outcome: "completed" });
      await waitFor(async () => (await store.status()).coverage.excludedCount === 2);
      expect(infer).not.toHaveBeenCalled();
      expect((await store.list()).records).toHaveLength(0);
    } finally { observer.dispose(); }
  });

  it.each(["session", "branch", "project"] as const)("does not send a stored %s exclusion to the model", async kind => {
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer });
    try {
      const config = await store.config();
      await store.configure("observer-global-scope-fence", { ...config, eligibility: { ...config.eligibility, allSessions: true } });
      const scope = kind === "session" ? { sessionId: "session-1" }
        : kind === "branch" ? { sessionId: "session-1", branchId: "private-branch" } : { projectId: "private-project" };
      await store.setScopeExclusion("observer-private-scope", scope, true);
      observer.admit({ sessionId: "session-1", branchId: "private-branch", projectId: "private-project", entries, outcome: "completed" });
      await waitFor(async () => (await store.status()).coverage.excludedCount === 1);
      expect(infer).not.toHaveBeenCalled();
      expect((await store.list()).records).toHaveLength(0);
    } finally { observer.dispose(); }
  });

  it("does not infer if a privacy change wins serialized pending admission", async () => {
    const infer = vi.fn(async () => output);
    const { store, observer } = await fixture({ infer });
    const setCoverage = store.setCoverage.bind(store);
    let rejected = false;
    const admission = vi.spyOn(store, "setCoverage").mockImplementation(async input => {
      if (input.coverage.disposition === "pending") {
        await store.setScopeExclusion("observer-admission-exclusion", { sessionId: "session-1" }, true);
        try { return await setCoverage(input); } catch (error) { rejected = true; throw error; }
      }
      return setCoverage(input);
    });
    try {
      observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
      await waitFor(() => rejected);
      // Join the attempted admission rather than interpreting zero records as
      // proof that private text did not cross the inference boundary.
      await Promise.allSettled(admission.mock.results.map(result => result.value));
      expect(infer).not.toHaveBeenCalled();
      expect((await store.list()).records).toHaveLength(0);
    } finally { observer.dispose(); admission.mockRestore(); }
  });

  it("retires an in-flight global result when selection becomes narrower", async () => {
    let release!: (value: string) => void;
    const blocked = new Promise<string>(resolve => { release = resolve; });
    const infer = vi.fn(async () => blocked);
    const { store, observer } = await fixture({ infer });
    try {
      const config = await store.config();
      const global = await store.configure("observer-global-before-narrowing", { ...config, eligibility: { ...config.eligibility, allSessions: true, sessionIds: [] } });
      observer.admit({ sessionId: "new-session", entries, outcome: "completed" });
      await waitFor(() => infer.mock.calls.length === 1);
      await store.configure("observer-selected-after-global", { ...global, eligibility: { sessionIds: ["different-session"], projectIds: [], excludedSessionIds: [], excludedProjectIds: [] } });
      release(output);
      await waitFor(async () => (await store.status()).coverage.excludedCount === 1);
      const coverage = await store.observationCoverageForScope("new-session");
      expect(coverage).toHaveLength(1);
      expect(coverage[0]?.range.entryIds).toEqual(["entry-1", "entry-2"]);
      expect((await store.status()).coverage.remainingCount).toBe(0);
      expect((await store.list()).records).toHaveLength(0);
      expect(infer).toHaveBeenCalledTimes(1);
    } finally { release(output); observer.dispose(); }
  });

  it("retries a durable failed cut with a new expected coverage revision", async () => {
    let attempts = 0;
    const infer = vi.fn(async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("temporary provider failure");
      return output;
    });
    const { store, observer } = await fixture({ infer });
    observer.admit({ sessionId: "session-1", entries, outcome: "failed", invocationId: "failed-retry-invocation" });
    await waitFor(async () => (await store.pendingObservationCoverage()).some(coverage => coverage.disposition === "failed"));
    observer.admit({ sessionId: "session-1", entries, outcome: "failed", invocationId: "failed-retry-invocation" });
    await waitFor(async () => (await store.status()).coverage.observedCount === 1);
    expect(infer).toHaveBeenCalledTimes(2);
    observer.dispose();
  });

  it("recovers a durable pending cut after the original admission is disposed", async () => {
    let releaseFirst!: () => void;
    const first = new Promise<void>(resolve => { releaseFirst = resolve; });
    const initial = vi.fn(async (input: { signal: AbortSignal }) => {
      await new Promise<void>(resolve => input.signal.addEventListener("abort", () => resolve(), { once: true }));
      await first;
      throw new Error("disposed provider");
    });
    const root = await mkdtemp(join(tmpdir(), "tron-observer-pending-recovery-")); roots.push(root);
    const workspace = new TronWorkspace(join(root, "home")); workspaces.push(workspace);
    const store = new KnowledgeStore(workspace);
    await store.configure("pending-recovery-config", {
      ...DEFAULT_KNOWLEDGE_CONFIG,
      eligibility: { ...DEFAULT_KNOWLEDGE_CONFIG.eligibility, sessionIds: ["session-1"] },
      observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true },
    });
    const pendingObserver = new KnowledgeObservationService(store, { infer: initial });
    pendingObserver.admit({ sessionId: "session-1", entries, outcome: "completed", invocationId: "pending-recovery-invocation" });
    await waitFor(async () => (await store.pendingObservationCoverage()).some(coverage => coverage.disposition === "pending"));
    pendingObserver.dispose();
    releaseFirst();
    const recovered = vi.fn(async () => output);
    const recoveryObserver = new KnowledgeObservationService(store, { infer: recovered });
    recoveryObserver.admit({ sessionId: "session-1", entries, outcome: "completed", invocationId: "pending-recovery-invocation" });
    await waitFor(async () => (await store.status()).coverage.observedCount === 1);
    expect(recovered).toHaveBeenCalledTimes(1);
    recoveryObserver.dispose();
  });

  it("records failed model inference as a non-success coverage disposition", async () => {
    vi.useFakeTimers();
    const { store, observer } = await fixture({ infer: async () => { throw new Error("synthetic provider failure"); } });
    observer.admit({ sessionId: "session-1", entries, outcome: "failed" });
    await waitFor(async () => (await store.status()).coverageCount === 1);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
    observer.dispose();
    await vi.advanceTimersByTimeAsync(25);
  });

  it("does not publish a late result after configuration revision changes", async () => {
    vi.useFakeTimers();
    let release!: () => void;
    const blocked = new Promise<string>(resolve => { release = () => resolve(output); });
    const infer = vi.fn(async () => blocked);
    const { store, observer } = await fixture({ infer });
    observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 1);
    const config = await store.config();
    await store.configure("observer-reconfigure", { ...config, observation: { ...config.observation, maxOutputChars: config.observation.maxOutputChars - 1 } });
    release();
    await waitFor(async () => (await store.status()).coverageCount === 1);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
    observer.dispose();
    await vi.advanceTimersByTimeAsync(25);
  });
});
