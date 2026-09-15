import { describe, expect, it } from "vitest";
import { buildPiArgs, cleanupTempDir, resolvePiLaunchToolPlan } from "./pi-args.js";

describe("Tron child bootstrap", () => {
  it.each([
    ["direct", { task: "inspect the change" }],
    ["async", { task: "inspect the change", runId: "async-1" }],
    ["workflow", { task: "workflow child", runId: "workflow-1" }],
    ["resume", { task: "resume retained child", runId: "resume-1" }],
    ["nested", { task: "nested child", runId: "nested-1", allowNestedSubagents: true }],
  ])("includes the owned bootstrap for %s child launches", (_mode, overrides) => {
    const temporaryDirs: string[] = [];
    const previousPrompt = process.env.TRON_CHILD_BOOTSTRAP_PROMPT;
    try {
      const result = buildPiArgs({
        baseArgs: ["--mode", "json", "-p"],
        ...overrides,
        sessionEnabled: false,
        inheritProjectContext: false,
        inheritGlobalContext: false,
        inheritSkills: false,
        tools: ["read"],
        cwd: process.cwd(),
      });
      if (result.tempDir) temporaryDirs.push(result.tempDir);
      const plan = resolvePiLaunchToolPlan({ tools: ["read"], cwd: process.cwd() });
      expect(plan.runtimeExtensions.some((entry) => entry.endsWith("/delegation/pi-subagents/index.js"))).toBe(true);
      expect(plan.runtimeExtensions.some((entry) => entry.endsWith("/extensions/tron-child-bootstrap-extension.js"))).toBe(true);
      expect(result.args).toContain("--extension");
      expect(result.args.some((entry) => entry.endsWith("/delegation/pi-subagents/index.js"))).toBe(true);
      expect(result.env.TRON_CHILD_BOOTSTRAP_PROMPT).toBeUndefined();
      process.env.TRON_CHILD_BOOTSTRAP_PROMPT = "wrong-runtime-context";
      const withPrompt = buildPiArgs({
        baseArgs: ["--mode", "json", "-p"],
        task: "prompted child",
        sessionEnabled: false,
        inheritProjectContext: false,
        inheritGlobalContext: false,
        inheritSkills: false,
        tools: ["read"],
        cwd: process.cwd(),
        tronBootstrapPrompt: "Tron workspace context",
      });
      if (withPrompt.tempDir) temporaryDirs.push(withPrompt.tempDir);
      expect(withPrompt.env.TRON_CHILD_BOOTSTRAP_PROMPT).toBe("Tron workspace context");
      expect(process.env.TRON_CHILD_BOOTSTRAP_PROMPT).toBe("wrong-runtime-context");
    } finally {
      if (previousPrompt === undefined) delete process.env.TRON_CHILD_BOOTSTRAP_PROMPT;
      else process.env.TRON_CHILD_BOOTSTRAP_PROMPT = previousPrompt;
      for (const temporaryDir of temporaryDirs) cleanupTempDir(temporaryDir);
    }
  });

  it("classifies TypeScript and JavaScript tool paths as extensions", () => {
    const plan = resolvePiLaunchToolPlan({ tools: ["fixture.ts", "fixture.js", "read"], cwd: process.cwd() });
    expect(plan.requestedBuiltinTools).toEqual(["read"]);
    expect(plan.toolExtensionPaths).toEqual(["fixture.ts", "fixture.js"]);
    expect(plan.effectiveToolAllowlist).toEqual(["read"]);
  });
});
