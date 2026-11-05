import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import {
  automationOwnedRunScenario, compactionScenario, notificationsPushScenario, openLockSession, projectRootTrustScenario,
  promptStreamScenario, queueControlScenario,
} from "../../test-support/lock-scenarios.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, type TraceValue } from "../../test-support/scenario-lock.js";
import { sessionSettingChange } from "../../test-support/session-settings-change.js";

/**
 * Client event schemas (#2279): every client event topic the phone decodes, with
 * the union of the payload paths it carries (`clientEventTrace`), across the lock
 * scenarios that together reach every payload shape. `protocol-wire` pins the
 * handshake and each method's request and response; this lock pins the events,
 * so the behavior locks need not each record them.
 *
 * Scenarios (shared with their behavior locks, `test-support/lock-scenarios.ts`):
 * notifications-push (presentation, extension asks, a failed and a stopped run, a
 * task worker), run-compaction, project-root-trust (trust, resources and settings
 * changes), automation-owned-run, run-prompt-stream (thinking), run-queue-control
 * (queue edits and diagnostics), and a Session-scope settings change.
 * `session.toolProgress` from project-root-trust is excluded: whether an instant
 * tool emits a progress frame before its result is host timing; the other
 * scenarios reach that topic deterministically.
 */

const MODULE = "gateway/protocol";
const gateways: LockGateway[] = [];
const owned: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const release of owned.splice(0).reverse()) await release();
  // Sequentially, newest first: each Gateway restores the agent-dir environment it found.
  for (const gateway of gateways.splice(0).reverse()) await gateway.dispose();
});

type EventTrace = { topic: string; paths: string[] };

describe("gateway/protocol client event schemas", () => {
  it("client-event-schemas: every event topic and the payload paths it carries", async () => {
    const recorded: EventTrace[][] = [];
    const record = (gateway: LockGateway, exclude: readonly string[] = []) =>
      recorded.push((gateway.record().events as unknown as EventTrace[]).filter((event) => !exclude.includes(event.topic)));

    const push = await notificationsPushScenario((release) => { owned.push(release); });
    record(push.gateway);
    for (const [name, scenario] of [["run-compaction", compactionScenario], ["run-prompt-stream", promptStreamScenario],
      ["run-queue-control", queueControlScenario]] as const) {
      const session = await openLockSession(`client-events-${name}`);
      gateways.push(session.gateway);
      await scenario(session);
      await session.gateway.settled(session.sessionId);
      record(session.gateway);
    }
    {
      const gateway = await startLockGateway("client-events-project-root-trust");
      gateways.push(gateway);
      await projectRootTrustScenario(gateway);
      record(gateway, ["session.toolProgress"]);
    }
    {
      const gateway = await startLockGateway("client-events-automation-owned-run", { automations: true });
      gateways.push(gateway);
      await automationOwnedRunScenario(gateway);
      record(gateway);
    }
    {
      const session = await openLockSession("client-events-session-settings");
      gateways.push(session.gateway);
      const changed = await session.client.request("settings.change", sessionSettingChange("tools", {
        commandId: session.gateway.commandId(), sessionId: session.sessionId, tools: ["read"] }));
      expect(changed.ok, JSON.stringify(changed)).toBe(true);
      await session.gateway.settled(session.sessionId);
      record(session.gateway);
    }

    const union = new Map<string, Set<string>>();
    for (const events of recorded) for (const event of events) {
      const paths = union.get(event.topic) ?? new Set<string>();
      for (const path of event.paths) paths.add(path);
      union.set(event.topic, paths);
    }
    const events = [...union].sort(([a], [b]) => a.localeCompare(b)).map(([topic, paths]) => ({ topic, paths: [...paths].sort() }));
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, "client-event-schemas"), update: lockUpdateRequested(MODULE),
      trace: { lock: "client-event-schemas", events: events as unknown as TraceValue[] },
      validate: () => { expect(events.length, "every topic the scenarios reach").toBeGreaterThanOrEqual(12); },
    });
  }, 240_000);
});
