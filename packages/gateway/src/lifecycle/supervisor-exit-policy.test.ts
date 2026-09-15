import { describe, expect, it } from "vitest";
import { administrativeExitCode, handledSignalExitCode, SUPERVISOR_RELAUNCH_EXIT_CODE } from "./supervisor-exit-policy.js";

describe("supervisor exit policy", () => {
  it("keeps unsolicited handled signals relaunchable under supervision", () => {
    expect(handledSignalExitCode(true)).toBe(SUPERVISOR_RELAUNCH_EXIT_CODE);
    expect(handledSignalExitCode(false)).toBe(0);
  });
  it("only explicit drained shutdown exits successfully without relaunch", () => {
    expect(administrativeExitCode("shutdown")).toBe(0);
    expect(administrativeExitCode("restart")).toBe(SUPERVISOR_RELAUNCH_EXIT_CODE);
  });
});
