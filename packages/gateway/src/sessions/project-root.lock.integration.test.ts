import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { projectRootTrustScenario } from "../../test-support/lock-scenarios.js";

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
 *   in the prompt, the root's compaction budgets apply, and the extension sees
 *   `cwd` and `projectDir` apart;
 * - revoking the root's decision reloads the chat without the Project layer.
 * `project-root.integration.test.ts` covers outside edits, linked worktrees and
 * MCP at the registry; this lock pins what clients and the model see.
 */

const MODULE = "gateway/session-catalog";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

describe("gateway/session-catalog project-root lock", () => {
  it("projectDir: a subdirectory chat of a trusted Git project loads the root's Project layer and keeps its cwd", async () => {
    const gateway = await startLockGateway("project-root-trust");
    gateways.push(gateway);
    const { root, project, nested, phone, systemPrompt, undecided, refused, decided, rootInspection, nestedInspection, created, sessionId, opened,
      chatSettings, projectSettings, revoked, transcript } = await projectRootTrustScenario(gateway);

    const recorded = gateway.record();
    const trace = {
      lock: "project-root-trust",
      exchanges: recorded.exchanges,
      // Whether an instant tool emits a progress frame before its result is host
      // timing; its settled result is in the transcript and JSONL.
      events: recorded.events.filter((event) => (event as { topic: string }).topic !== "session.toolProgress"),
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(sessionId),
      // The trust store is keyed by path; normalization rewrites values, so list its entries.
      files: { trust: normalizeTraceValue(Object.entries(JSON.parse(await readFile(join(gateway.agentDir, "trust.json"), "utf8")))
        .map(([path, trusted]) => ({ path, trusted })), gateway.normalization) },
      // The prompt hash already covers the whole text; these name what it must hold.
      observed: Object.fromEntries(["root-lock-skill", "nested-lock-skill", "ROOT-INSTRUCTIONS", "NESTED-INSTRUCTIONS"]
        .map((marker) => [marker, systemPrompt().includes(marker)])),
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
        expect(opened.result.session.compactionPolicy.currentBudgets).toMatchObject({ reserveTokens: 4_096, keepRecentTokens: 240 });
        expect(revoked.ok, JSON.stringify(revoked)).toBe(true);
        expect(recorded.providerRequests).toHaveLength(3);
        expect(recorded.providerRequests[2]!.tools).not.toContain("project_probe");
        expect(transcript.ok).toBe(true);
        expect(trace.observed).toEqual({ "root-lock-skill": true, "nested-lock-skill": false, "ROOT-INSTRUCTIONS": true, "NESTED-INSTRUCTIONS": true });
        const first = recorded.providerRequests[0]!;
        expect(first.tools).toContain("project_probe");
        expect(first.tools).not.toContain("nested_probe");
        const messages = JSON.stringify(recorded.providerRequests[1]!.messages);
        expect(messages).toContain(`cwd=${cwd} projectDir=${projectDir}`);
        expect(trace.files.trust).toContainEqual({ path: projectDir, trusted: false });
      },
    });
  });
});
