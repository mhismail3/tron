import { describe, expect, it } from "vitest";
import { handledSignalExitCode, SUPERVISOR_RELAUNCH_EXIT_CODE } from "./supervisor-exit-policy.js";

describe("supervisor exit policy", () => {
  it("keeps handled signals relaunchable under supervision", () => {
    expect(handledSignalExitCode(true, false)).toBe(SUPERVISOR_RELAUNCH_EXIT_CODE);
    expect(handledSignalExitCode(true, true)).toBe(SUPERVISOR_RELAUNCH_EXIT_CODE);
  });

  it("keeps foreground signals clean unless a restart is pending", () => {
    expect(handledSignalExitCode(false, false)).toBe(0);
    expect(handledSignalExitCode(false, true)).toBe(SUPERVISOR_RELAUNCH_EXIT_CODE);
  });
});
