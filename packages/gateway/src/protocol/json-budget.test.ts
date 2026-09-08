import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { GATEWAY_JSON_MAXIMUM_NODES, jsonNodeCount } from "./json-budget.js";
import { SESSION_SNAPSHOT_NODES, TRANSCRIPT_PAGE_NODES } from "../sessions/projection.js";

describe("encoded JSON structural budget", () => {
  it("matches the shared native contract and reserves envelope headroom", () => {
    const limits = JSON.parse(readFileSync(new URL("../../../protocol-fixtures/gateway-json-limits.json", import.meta.url), "utf8"));
    expect(GATEWAY_JSON_MAXIMUM_NODES).toBe(limits.maximumDynamicJSONNodes);
    expect(SESSION_SNAPSHOT_NODES).toBe(limits.snapshotNodes);
    expect(TRANSCRIPT_PAGE_NODES).toBe(limits.transcriptPageNodes);
    expect(TRANSCRIPT_PAGE_NODES).toBeLessThan(SESSION_SNAPSHOT_NODES);
    expect(SESSION_SNAPSHOT_NODES).toBeLessThan(GATEWAY_JSON_MAXIMUM_NODES);
  });

  it("counts wire values, skips absent object members, and includes array nulls", () => {
    expect(jsonNodeCount({ absent: undefined, array: [undefined, null, { value: 1 }] })).toBe(6);
    expect(jsonNodeCount(JSON.parse(JSON.stringify({ absent: undefined, array: [undefined, null, { value: 1 }] })))).toBe(6);
    expect(jsonNodeCount({ absent: undefined, array: [undefined, null, { value: 1 }] }, 100, true)).toBe(7);
  });

  it("admits the exact node boundary and stops on dense or very wide input", () => {
    expect(jsonNodeCount(Array(32_767).fill(0))).toBe(32_768);
    expect(jsonNodeCount(Array(32_768).fill(0))).toBe(32_769);
    expect(jsonNodeCount(Array(500_000).fill(0))).toBe(32_769);
    expect(jsonNodeCount({ a: [1, 2], b: [3, 4] }, 5)).toBe(6);
  });
});
