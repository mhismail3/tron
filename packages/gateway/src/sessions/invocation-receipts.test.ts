import { describe, expect, it } from "vitest";
import { INVOCATION_RECEIPT_TYPE, invocationProjection, invocationReceipts, makeInvocationReceipt, parseInvocationReceipt } from "./invocation-receipts.js";

const start = makeInvocationReceipt({
  version: 1, receiptId: "start:inv-1", receiptKind: "start", invocationId: "inv-1",
  operationId: "op-1", sessionId: "session-1", source: "extension", name: "goal",
  arguments: "count to 20", lifecycle: "staged", sequence: 1,
  origin: { kind: "extension", confidence: "boundary" }, createdAt: "2026-01-01T00:00:00.000Z",
});

describe("invocation receipts", () => {
  it("folds terminal state into the immutable start identity", () => {
    const values = invocationProjection([
      start,
      { ...start, receiptId: "accepted:inv-1", receiptKind: "transition", lifecycle: "accepted", sequence: 2, createdAt: "2026-01-01T00:00:00.500Z" },
      { ...start, receiptId: "terminal:inv-1", receiptKind: "terminal", lifecycle: "completed", sequence: 3, createdAt: "2026-01-01T00:00:01.000Z" },
    ]);
    expect(values).toHaveLength(1);
    expect(values[0]).toMatchObject({ invocationId: "inv-1", operationId: "op-1", name: "goal", lifecycle: "completed" });
  });

  it("rejects malformed and unbounded records", () => {
    expect(parseInvocationReceipt({ ...start, sequence: -1 })).toBeUndefined();
    expect(parseInvocationReceipt({ ...start, arguments: "x".repeat(65_000) })).toBeUndefined();
    expect(parseInvocationReceipt({ ...start, receiptKind: "future" })).toBeUndefined();
  });

  it("requires the Gateway writer marker and rejects unknown or invalid fields", () => {
    expect(parseInvocationReceipt({ ...start, writer: "extension" })).toBeUndefined();
    expect(parseInvocationReceipt({ ...start, forged: true })).toBeUndefined();
    expect(parseInvocationReceipt({ ...start, createdAt: "2026-01-01T00:00:00Z" })).toBeUndefined();
    expect(parseInvocationReceipt({ ...start, name: "x\u0000" })).toBeUndefined();
    expect(parseInvocationReceipt({ ...start, arguments: "🙂".repeat(20_000) })).toBeUndefined();
  });

  it("deduplicates identical IDs and rejects contradictory IDs or terminal rewrites", () => {
    const duplicate = { ...start };
    expect(invocationReceipts([
      { id: "a", type: "custom", customType: INVOCATION_RECEIPT_TYPE, data: start, parentId: null, timestamp: start.createdAt },
      { id: "b", type: "custom", customType: INVOCATION_RECEIPT_TYPE, data: duplicate, parentId: null, timestamp: start.createdAt },
    ] as any[])).toHaveLength(1);
    expect(() => invocationReceipts([
      { id: "a", type: "custom", customType: INVOCATION_RECEIPT_TYPE, data: start, parentId: null, timestamp: start.createdAt },
      { id: "b", type: "custom", customType: INVOCATION_RECEIPT_TYPE, data: { ...start, receiptId: start.receiptId, name: "other" }, parentId: null, timestamp: start.createdAt },
    ] as any[])).toThrow("contradictory");
    expect(() => invocationProjection([
      start,
      { ...start, receiptId: "accepted:inv-1", receiptKind: "transition", lifecycle: "accepted", sequence: 2, createdAt: "2026-01-01T00:00:00.500Z" },
      { ...start, receiptId: "terminal:inv-1", receiptKind: "terminal", lifecycle: "completed", sequence: 3, createdAt: "2026-01-01T00:00:01.000Z" },
      { ...start, receiptId: "terminal-2:inv-1", receiptKind: "terminal", lifecycle: "failed", sequence: 4, createdAt: "2026-01-01T00:00:02.000Z" },
    ])).toThrow("terminal");
    expect(() => invocationProjection([
      start,
      { ...start, receiptId: "start-2:inv-1", sequence: 2, createdAt: "2026-01-01T00:00:00.500Z" },
    ])).toThrow("more than one start");
    expect(() => invocationProjection([
      start,
      { ...start, receiptId: "accepted:inv-1", receiptKind: "transition", lifecycle: "accepted", operationId: "other", sequence: 2, createdAt: "2026-01-01T00:00:00.500Z" },
    ])).toThrow("ownership changed");
  });

  it("admits only bounded session-owned canonical receipt entries", () => {
    const entries = [
      { id: "a", type: "custom", customType: "tron.chat-invocation.v1", data: start, parentId: null, timestamp: start.createdAt },
      { id: "b", type: "custom", customType: "tron.chat-invocation.v1", data: { ...start, sessionId: "other" }, parentId: null, timestamp: start.createdAt },
    ] as any[];
    expect(invocationReceipts(entries, "session-1")).toEqual([start]);
  });
});
