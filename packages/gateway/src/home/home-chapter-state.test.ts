/** Failure modes covered before introducing the Slot seal seam:
 * - a sealed physical chapter must reject a mutation before its owner invokes SDK work;
 * - an active/unsealed chapter must preserve today's mutation behavior;
 * - the default installation provider must remain inert until chapter records exist.
 */
import { describe, expect, it } from "vitest";
import { assertChapterWritable, unsealedHomeChapterState, type HomeChapterState } from "./home-chapter-state.js";

describe("Home physical chapter mutation boundary", () => {
  it("allows ordinary/unsealed runtimes while the chapter feature is inactive", () => {
    expect(unsealedHomeChapterState("session-1")).toEqual({ sessionId: "session-1", sealed: false });
    expect(() => assertChapterWritable(unsealedHomeChapterState("session-1"))).not.toThrow();
  });

  it("returns a typed refusal for a sealed physical target", () => {
    const sealed: HomeChapterState = { sessionId: "session-2", sealed: true };
    expect(() => assertChapterWritable(sealed)).toThrowError(expect.objectContaining({
      code: "conflict",
      details: { reason: "sealed-chapter", sessionId: "session-2" },
    }));
  });
});
