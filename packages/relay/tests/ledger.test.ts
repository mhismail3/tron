import { describe, expect, test } from "vitest";

import { replayResult } from "../src/ledger";

describe("durable retry coalescing", () => {
  test("admits an unseen provider request", () => {
    expect(replayResult(undefined)).toBeUndefined();
  });

  test("replays terminal APNs acceptance", () => {
    expect(
      replayResult({
        state: "terminal",
        response_json: JSON.stringify({
          status: "accepted_by_apns",
          apnsId: "provider-id",
        }),
      }),
    ).toEqual({ status: "accepted_by_apns", apnsId: "provider-id" });
  });

  test("blocks an ambiguously interrupted attempt instead of resending", () => {
    expect(
      replayResult({ state: "in_progress", response_json: null }),
    ).toEqual({
      status: "ambiguous",
      reason: "provider_outcome_unknown",
    });
  });

  test("allows an explicitly retryable result to be attempted again", () => {
    expect(
      replayResult({
        state: "retryable",
        response_json: JSON.stringify({ status: "retryable" }),
      }),
    ).toBeUndefined();
  });
});
