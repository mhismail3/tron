import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { acquireAgentRuntimeLock, acquireAgentRuntimeLocks } from "./agent-runtime-lock.js";

describe("agent runtime lock", () => {
  it("allows one Gateway owner and rejects a concurrent owner", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-agent-lock-"));
    const release = await acquireAgentRuntimeLock(root);
    await expect(acquireAgentRuntimeLock(root)).rejects.toMatchObject({ code: "conflict" });
    await release();
    const secondRelease = await acquireAgentRuntimeLock(root);
    await secondRelease();
  });

  it("acquires a shared external session directory as part of ownership", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-agent-lock-shared-"));
    const shared = join(root, "shared-sessions");
    const release = await acquireAgentRuntimeLocks([join(root, "agent-a"), shared]);
    await expect(acquireAgentRuntimeLocks([join(root, "agent-b"), shared])).rejects.toMatchObject({ code: "conflict" });
    await release();
  });
});
