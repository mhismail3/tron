import { describe, expect, it } from "vitest";
import {
  makeExtensionNotificationReceipt,
  parseExtensionNotificationReceipt,
} from "./extension-notification-receipts.js";

function receipt(overrides: Record<string, unknown> = {}) {
  return makeExtensionNotificationReceipt({
    version: 1,
    receiptId: "notification:one",
    sessionId: "session",
    message: "Goal created.",
    tone: "info",
    origin: {
      kind: "extension",
      ownerId: "extension:goal",
      title: "Pi Goal",
      confidence: "receipt",
    },
    invocationId: "invocation",
    operationId: "operation",
    sequence: 1,
    createdAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  } as Parameters<typeof makeExtensionNotificationReceipt>[0]);
}

describe("extension notification receipts", () => {
  it("accepts one bounded Gateway-authored notification", () => {
    expect(parseExtensionNotificationReceipt(receipt())).toMatchObject({
      message: "Goal created.", tone: "info", origin: { title: "Pi Goal" },
    });
  });

  it("rejects unknown writers, fields, controls, and oversized messages", () => {
    expect(parseExtensionNotificationReceipt({ ...receipt(), writer: "extension" })).toBeUndefined();
    expect(parseExtensionNotificationReceipt({ ...receipt(), extra: true })).toBeUndefined();
    expect(parseExtensionNotificationReceipt({ ...receipt(), message: "bad\u0000" })).toBeUndefined();
    expect(parseExtensionNotificationReceipt({ ...receipt(), message: "x".repeat(32 * 1_024 + 1) })).toBeUndefined();
  });
});
