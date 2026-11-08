import { resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import {
  automationOwnedRunScenario, compactionScenario, drainBlockersScenario, DETACHED_RUN, EXTENSION_UI_OPTIONS, extensionUiScenario,
  openLockSession, projectRootTrustScenario, promptStreamScenario, queueControlScenario, WAITING_COMMAND,
} from "../../../test-support/lock-scenarios.js";
import { compareWithGolden, lockUpdateRequested, type TraceValue } from "../../../test-support/scenario-lock.js";

/**
 * Tron's persisted session entries (#2279): every distinct Tron custom entry
 * (`tron.chat-invocation.v1`, `tron.settings.v1`, `tron.context-window.v1`,
 * `tron.extension-activity.v1`) the shared lock
 * scenarios write into canonical session JSONL, with its values, normalized as
 * `gateway.canonical` normalizes them. Each lock's faux provider is named after
 * the lock, so that name becomes `<lock>`. The behavior locks assert what a
 * scenario does; this lock pins the persisted format and values those entries
 * take, so a format change is reviewed once, here.
 *
 * Scenarios (`test-support/lock-scenarios.ts`): run-prompt-stream, run-compaction,
 * run-extension-ui, run-queue-control, project-root-trust, automation-owned-run
 * (both sessions) and run-drain-blockers. Home and delegation sessions keep their
 * entries in `home-contention-restart` and `delegation-subagent`.
 */

const GOLDEN = resolve(process.cwd(), "test-fixtures", "pi-sdk", "session-entries.golden.json");
/** Every release in creation order, run newest first: each Gateway restores the agent-dir environment it found. */
const owned: Array<() => Promise<void>> = [];
const own = (gateway: LockGateway) => { owned.push(() => gateway.dispose()); };
afterEach(async () => { for (const release of owned.splice(0).reverse()) await release(); });

describe("gateway/pi-sdk session entries", () => {
  it("session-entries: every Tron custom entry the shared scenarios persist", async () => {
    const entries = new Set<string>();
    const collect = async (gateway: LockGateway, ...sessionIds: string[]) => {
      for (const sessionId of sessionIds) {
        for (const entry of await gateway.canonical(sessionId)) {
          const custom = entry as { type?: string; customType?: string };
          if (custom.type !== "custom" || !custom.customType?.startsWith("tron.")) continue;
          entries.add(JSON.stringify(entry).replace(/tron-lock-[a-z0-9-]+/gu, "<lock>"));
        }
      }
    };

    for (const [name, scenario, options] of [
      ["prompt-stream", promptStreamScenario, undefined], ["compaction", compactionScenario, undefined],
      ["extension-ui", extensionUiScenario, EXTENSION_UI_OPTIONS], ["queue-control", queueControlScenario, undefined],
    ] as const) {
      const session = await openLockSession(`session-entries-${name}`, options);
      own(session.gateway);
      await (scenario as (session: typeof session) => Promise<unknown>)(session);
      await session.gateway.settled(session.sessionId);
      await collect(session.gateway, session.sessionId);
    }
    {
      const gateway = await startLockGateway("session-entries-project-root-trust");
      own(gateway);
      const { sessionId } = await projectRootTrustScenario(gateway);
      await collect(gateway, sessionId);
    }
    {
      const gateway = await startLockGateway("session-entries-automation-owned-run", { automations: true });
      own(gateway);
      const { sessionId, workspace } = await automationOwnedRunScenario(gateway);
      await collect(gateway, sessionId, workspace.executionSessionId);
    }
    {
      const gateway = await startLockGateway("session-entries-drain-blockers", {
        extensions: [{ name: "lock-ask.ts", source: WAITING_COMMAND }, { name: "lock-background.ts", source: DETACHED_RUN }],
      });
      own(gateway);
      const { detached } = await drainBlockersScenario(gateway);
      await collect(gateway, detached.sessionId);
    }

    const sorted = [...entries].sort().map((entry) => JSON.parse(entry) as TraceValue);
    await compareWithGolden({
      module: "gateway/e2e", goldenPath: GOLDEN,
      actualPath: resolve(process.cwd(), "test-results", "session-entries.actual.json"),
      diffPath: resolve(process.cwd(), "test-results", "session-entries.diff"),
      trace: { lock: "session-entries", entries: sorted }, update: lockUpdateRequested("gateway/e2e"),
      validate: () => {
        const types = new Set(sorted.map((entry) => (entry as { customType: string }).customType));
        expect([...types].sort()).toEqual(["tron.chat-invocation.v1", "tron.context-window.v1", "tron.extension-activity.v1", "tron.settings.v1"]);
      },
    });
  }, 240_000);
});
