import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import {
  automationOwnedRunScenario, compactionScenario, notificationsPushScenario, openLockSession, projectRootTrustScenario,
  promptStreamScenario, queueControlScenario,
} from "../../../test-support/lock-scenarios.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, type TraceValue } from "../../../test-support/scenario-lock.js";
import { sessionSettingChange } from "../../../test-support/session-settings-change.js";

const MODULE = "gateway/e2e";
const owned: Array<() => Promise<void>> = [];
const own = (gateway: LockGateway) => { owned.push(() => gateway.dispose()); };
afterEach(async () => { for (const release of owned.splice(0).reverse()) await release(); });

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
      own(session.gateway);
      await scenario(session);
      await session.gateway.settled(session.sessionId);
      record(session.gateway);
    }
    {
      const gateway = await startLockGateway("client-events-project-root-trust");
      own(gateway);
      await projectRootTrustScenario(gateway);
      record(gateway, ["session.toolProgress"]);
    }
    {
      const gateway = await startLockGateway("client-events-automation-owned-run", { automations: true });
      own(gateway);
      await automationOwnedRunScenario(gateway);
      record(gateway);
    }
    {
      const session = await openLockSession("client-events-session-settings");
      own(session.gateway);
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
