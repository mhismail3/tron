import { describe, expect, it } from "vitest";
import { invocationProjection, makeInvocationReceipt } from "./invocation-receipts.js";

let serial = 0;
const at = (second: number) => new Date(Date.parse("2026-11-09T12:00:00.000Z") + second * 1_000).toISOString();
const receipt = (invocationId: string, fields: Record<string, unknown>) => makeInvocationReceipt({
  receiptId: `receipt-${serial++}`, version: 1, invocationId, operationId: `op-${invocationId}`, sessionId: "session",
  source: "plain", sequence: 1, createdAt: at(serial), ...fields } as never);
const origin = { kind: "user", confidence: "receipt" } as const;
const start = (id: string, fields: Record<string, unknown> = {}) => receipt(id, { receiptKind: "start", lifecycle: "staged", origin, ...fields });
const move = (id: string, lifecycle: string, fields: Record<string, unknown> = {}) => receipt(id, { receiptKind: "transition", lifecycle, ...fields });
const settle = (id: string, lifecycle: string, fields: Record<string, unknown> = {}) => receipt(id, { receiptKind: "terminal", lifecycle, ...fields });
const bind = (id: string, canonicalEntryId: string, fields: Record<string, unknown> = {}) => receipt(id, { receiptKind: "binding", canonicalEntryId, ...fields });

describe("invocation projection", () => {
  it("folds each invocation to its lifecycle, entry, flag and latest time, with the start's identity", () => {
    const a = start("a");
    const skill = start("b", { source: "skill", name: "review", arguments: "now", submittedText: "please", sequence: 2 });
    const last = bind("a", "entry-a");
    const history = [a, move("a", "accepted"), skill, move("a", "running"), move("b", "running", { source: "skill" }), settle("a", "completed", { retryable: false }), last];
    expect(invocationProjection(history)).toStrictEqual([
      { version: 1, invocationId: "a", operationId: "op-a", source: "plain", lifecycle: "completed", origin, sequence: 1, updatedAt: last.createdAt,
        retryable: false, canonicalEntryId: "entry-a" },
      { version: 1, invocationId: "b", operationId: "op-b", source: "skill", name: "review", arguments: "now", submittedText: "please",
        resourceInvocations: [{ source: "skill", name: "review", arguments: "now" }], lifecycle: "running", origin, sequence: 2, updatedAt: history[4]!.createdAt },
    ]);
    expect(invocationProjection([])).toStrictEqual([]);
  });

  it("writes a projection's fields in a fixed order, the entry and the flag in the order their receipts came", () => {
    const keys = (history: Parameters<typeof invocationProjection>[0]) => Object.keys(invocationProjection(history)[0]!);
    const head = ["version", "invocationId", "operationId", "source", "lifecycle", "origin", "sequence", "updatedAt"];
    expect(keys([start("a"), settle("a", "failed", { retryable: true }), bind("a", "e")])).toStrictEqual([...head, "retryable", "canonicalEntryId"]);
    expect(keys([start("a"), bind("a", "e"), settle("a", "failed", { retryable: true })])).toStrictEqual([...head, "canonicalEntryId", "retryable"]);
    expect(keys([start("a"), settle("a", "failed"), bind("a", "e"), settle("a", "failed", { retryable: true })])).toStrictEqual([...head, "canonicalEntryId", "retryable"]);
    expect(keys([start("a"), settle("a", "failed", { retryable: true }), bind("a", "e"), settle("a", "failed", { retryable: false })])).toStrictEqual([...head, "retryable", "canonicalEntryId"]);
    expect(keys([start("a", { source: "prompt", name: "p", resources: [{ source: "prompt", name: "p" }, { source: "skill", name: "s" }] })]))
      .toStrictEqual(["version", "invocationId", "operationId", "source", "name", "resourceInvocations", "lifecycle", "origin", "sequence", "updatedAt"]);
  });

  it("orders the result by start sequence, ties in start order", () => {
    const history = [start("late", { sequence: 9 }), start("first", { sequence: 1 }), start("second", { sequence: 1 }), start("middle", { sequence: 4 })];
    expect(invocationProjection(history).map(projection => projection.invocationId)).toStrictEqual(["first", "second", "middle", "late"]);
  });

  it("keeps a settled invocation settled: the same terminal again changes only the flag and the time, and a binding may follow", () => {
    const again = settle("a", "interrupted", { retryable: true });
    const bound = bind("a", "e");
    const projected = invocationProjection([start("a"), move("a", "running"), settle("a", "interrupted", { retryable: false }), again, bound])[0]!;
    expect(projected).toMatchObject({ lifecycle: "interrupted", retryable: true, canonicalEntryId: "e", updatedAt: bound.createdAt });
    expect(invocationProjection([start("a"), move("a", "queued"), move("a", "running"), move("a", "waitingForInput"), move("a", "running"), move("a", "settling")])[0]!.lifecycle).toBe("settling");
  });

  it("refuses a history at its first contradictory receipt, by name", () => {
    const refusals: Array<[string, () => unknown[]]> = [
      ["invocation has more than one start receipt", () => [start("a"), start("a")]],
      ["invocation receipt has no start receipt", () => [move("a", "running")]],
      ["invocation receipt has no start receipt", () => [start("a"), bind("b", "e")]],
      ["invocation receipt ownership changed", () => [start("a"), move("a", "running", { operationId: "another" })]],
      ["invocation receipt ownership changed", () => [start("a"), settle("a", "completed", { source: "skill" })]],
      ["canonical entry has more than one invocation binding", () => [start("a"), start("b"), bind("a", "e"), bind("b", "e")]],
      ["invocation has more than one canonical binding", () => [start("a"), bind("a", "e"), bind("a", "f")]],
      ["invocation receipt resource name changed", () => [start("a", { source: "skill", name: "review" }), settle("a", "completed", { source: "skill", name: "other" })]],
      ["invocation receipt resource name changed", () => [start("a"), settle("a", "completed", { name: "review" })]],
      ["invocation receipt origin changed", () => [start("a"), settle("a", "completed", { origin: { kind: "extension", confidence: "receipt" } })]],
      ["contradictory terminal invocation receipt", () => [start("a"), settle("a", "completed"), settle("a", "failed")]],
      ["illegal invocation transition", () => [start("a"), move("a", "queued"), move("a", "retrying")]],
      ["illegal invocation transition", () => [start("a"), settle("a", "completed"), move("a", "running")]],
      ["invocation receipt ownership changed", () => [start("a"), move("a", "running", { operationId: "another" }), start("a")]],
      ["invocation receipt ownership changed", () => [start("a"), start("b"), bind("a", "e"), bind("b", "e", { operationId: "another" })]],
      ["canonical entry has more than one invocation binding", () => [start("a"), start("b"), bind("a", "e"), bind("b", "f"), bind("b", "e")]],
    ];
    for (const [message, history] of refusals) expect(() => invocationProjection(history() as never), message).toThrow(new Error(message));
  });

  it("accepts a terminal's own name and origin when they are the start's, however the origin's fields are ordered", () => {
    const named = start("a", { source: "skill", name: "review", origin: { kind: "extension", confidence: "adapter", title: "Tool" } });
    const history = [named, settle("a", "completed", { source: "skill", name: "review", origin: { title: "Tool", confidence: "adapter", kind: "extension" } })];
    expect(invocationProjection(history)[0]).toMatchObject({ lifecycle: "completed", name: "review", origin: { kind: "extension", confidence: "adapter", title: "Tool" } });
  });
});
