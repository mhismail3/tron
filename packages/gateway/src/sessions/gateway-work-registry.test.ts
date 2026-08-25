import { describe, expect, it, vi } from "vitest";
import { GatewayWorkRegistry } from "./gateway-work-registry.js";

describe("GatewayWorkRegistry", () => {
  it("transfers one exact token without a release/reacquire gap", async () => {
    let now = 1_000;
    const registry = new GatewayWorkRegistry("epoch", 8, () => now, () => now);
    const work = registry.begin({ kind: "prompt-preflight", sessionId: "session", hostEpoch: "host" });
    expect(registry.facts()).toMatchObject([{ token: work.token, kind: "prompt-preflight" }]);
    registry.beginDrain();
    now += 1;
    work.transition("foreground-agent-operation");
    expect(registry.facts()).toMatchObject([{ token: work.token, kind: "foreground-agent-operation", progressMonotonicMs: 1_001 }]);
    let idle = false;
    const settled = registry.waitUntilSettled().then(() => { idle = true; });
    await Promise.resolve();
    expect(idle).toBe(false);
    work.settle();
    await settled;
    expect(registry.size).toBe(0);
  });

  it("closes external admission while allowing exact derived settlement work", () => {
    const registry = new GatewayWorkRegistry("epoch", 2);
    registry.beginDrain();
    expect(() => registry.begin({ kind: "slot-admission", hostEpoch: "epoch" })).toThrow(/draining/u);
    const receipt = registry.beginDerived({ kind: "terminal-receipt-persistence", hostEpoch: "epoch" });
    expect(registry.size).toBe(1);
    receipt.settle();
  });

  it("closes derived settlement admission once drain completion is committed", () => {
    const registry = new GatewayWorkRegistry("epoch", 4);
    registry.beginDrain();
    const receipt = registry.beginDerived({ kind: "terminal-receipt-persistence", hostEpoch: "epoch" });
    receipt.settle();
    registry.completeDrain();
    expect(() => registry.beginDerived({ kind: "terminal-receipt-persistence", hostEpoch: "epoch" }))
      .toThrow(/completed/u);
  });

  it("does not release a terminal receipt blocker before persistence settles", async () => {
    const registry = new GatewayWorkRegistry("epoch", 4);
    let persist!: () => void;
    const persistence = new Promise<void>((resolve) => { persist = resolve; });
    const receipt = registry.beginDerived({ kind: "terminal-receipt-persistence", sessionId: "session", hostEpoch: "host" });
    void persistence.finally(receipt.settle);
    registry.beginDrain();
    let idle = false;
    const waiting = registry.waitUntilSettled().then(() => { idle = true; });
    await Promise.resolve();
    expect(idle).toBe(false);
    persist();
    await waiting;
    expect(idle).toBe(true);
  });

  it("fences cancellation and waits for owner settlement", async () => {
    const cancellation = vi.fn(async () => {});
    const registry = new GatewayWorkRegistry("epoch", 4);
    const work = registry.begin({ kind: "administrative-provider-package-operation", hostEpoch: "epoch", cancellation });
    registry.beginDrain();
    await Promise.all([registry.requestCancellation(), registry.requestCancellation()]);
    expect(cancellation).toHaveBeenCalledTimes(1);
    let settled = false;
    const idle = registry.waitUntilSettled().then(() => { settled = true; });
    await Promise.resolve();
    expect(settled).toBe(false);
    work.settle();
    await idle;
  });

  it("partitions the hard bound so either admission pool cannot consume the other", () => {
    const registry = new GatewayWorkRegistry("epoch", 2);
    const receipt = registry.beginDerived({ kind: "terminal-receipt-persistence", hostEpoch: "epoch" });
    expect(() => registry.beginDerived({ kind: "terminal-receipt-persistence", hostEpoch: "epoch" })).toThrow(/bounded capacity/u);
    const accepted = registry.begin({ kind: "foreground-agent-operation", hostEpoch: "epoch" });
    expect(registry.size).toBe(2);
    expect(() => registry.begin({ kind: "slot-admission", hostEpoch: "epoch" })).toThrow(/bounded capacity/u);
    accepted.settle();
    receipt.settle();
  });

  it("reserves independent 1,024-entry production pools and reuses transferred tokens", () => {
    const registry = new GatewayWorkRegistry("epoch", 2_048);
    const derived = Array.from({ length: 1_024 }, () => registry.beginDerived({
      kind: "terminal-receipt-persistence", hostEpoch: "epoch",
    }));
    expect(() => registry.beginDerived({ kind: "terminal-receipt-persistence", hostEpoch: "epoch" })).toThrow(/bounded capacity/u);
    const normal = Array.from({ length: 1_024 }, () => registry.begin({
      kind: "foreground-agent-operation", hostEpoch: "epoch",
    }));
    expect(() => registry.begin({ kind: "slot-admission", hostEpoch: "epoch" })).toThrow(/bounded capacity/u);
    normal[0]!.transition("terminal-receipt-persistence");
    expect(registry.size).toBe(2_048);
    for (const work of [...normal, ...derived]) work.settle();
  });

  it("has a hard entry bound and never expires work by age", () => {
    let now = 0;
    const registry = new GatewayWorkRegistry("epoch", 1, () => now, () => now);
    const work = registry.begin({ kind: "foreground-agent-operation", hostEpoch: "epoch" });
    now = Number.MAX_SAFE_INTEGER;
    expect(registry.facts()).toHaveLength(1);
    expect(() => registry.begin({ kind: "slot-admission", hostEpoch: "epoch" })).toThrow(/bounded capacity/u);
    work.settle();
  });
});
