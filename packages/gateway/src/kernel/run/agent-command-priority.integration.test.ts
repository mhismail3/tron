import { mkdtemp, rm } from "node:fs/promises";
import { getPriority } from "node:os";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { AGENT_COMMAND_NICENESS, DirectBashProcessOwner } from "./direct-bash-process-owner.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

it.skipIf(process.platform === "win32")("runs an agent command and its grandchild at the lowered niceness, leaving the Gateway and user commands at their own", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-agent-priority-"));
  roots.push(root);
  const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")), "agent-priority");
  const before = getPriority();
  const niceness = async (origin: "agent" | "user") => {
    let output = "";
    const result = await owner.shellOperations(origin).exec(
      `echo "shell=$(ps -o nice= -p $$)"; sh -c 'echo "grandchild=$(ps -o nice= -p $$)"'`,
      root,
      { onData: (data: Buffer) => { output += data.toString(); } },
    );
    expect(result.exitCode).toBe(0);
    return [output.match(/shell=\s*(-?\d+)/u)?.[1], output.match(/grandchild=\s*(-?\d+)/u)?.[1]];
  };
  const lowered = String(Math.min(20, before + AGENT_COMMAND_NICENESS));
  expect(await niceness("agent")).toEqual([lowered, lowered]);
  expect(await niceness("user")).toEqual([String(before), String(before)]);
  expect(getPriority()).toBe(before);
});
