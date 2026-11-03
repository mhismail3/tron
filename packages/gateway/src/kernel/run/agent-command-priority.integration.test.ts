import { mkdtemp, rm } from "node:fs/promises";
import { getPriority } from "node:os";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { AGENT_COMMAND_NICENESS, DirectBashProcessOwner } from "./direct-bash-process-owner.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

// Agent commands saturating the host must not starve the Gateway's interactive
// requests: the shell and every descendant run lowered, the Gateway does not.
it.skipIf(process.platform === "win32")("runs an agent command and its grandchild at the lowered niceness, leaving the Gateway's own", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-agent-priority-"));
  roots.push(root);
  const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")), "agent-priority");
  const before = getPriority();
  let output = "";
  const result = await owner.shellOperations().exec(
    `echo "shell=$(ps -o nice= -p $$)"; sh -c 'echo "grandchild=$(ps -o nice= -p $$)"'`,
    root,
    { onData: (data: Buffer) => { output += data.toString(); } },
  );
  expect(result.exitCode).toBe(0);
  const expected = Math.min(19, before + AGENT_COMMAND_NICENESS);
  expect(output.match(/shell=\s*(-?\d+)/u)?.[1]).toBe(String(expected));
  expect(output.match(/grandchild=\s*(-?\d+)/u)?.[1]).toBe(String(expected));
  expect(getPriority()).toBe(before);
});
