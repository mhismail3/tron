import { execFileSync } from "node:child_process";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { execFileSyncWithStallCapture } from "../../../test-support/native-exec-stall-capture.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

async function directory(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "tron-native-exec-stall-"));
  roots.push(root);
  return root;
}

const watchers = (root: string) => execFileSync("/bin/sh", ["-c", `pgrep -f "${root}" || true`], { encoding: "utf8" }).trim();

it("records the parent, the stalled child's stdin and host load when a native exec outlives its threshold", async () => {
  const root = await directory();
  // A child that holds its stdin unread until the stall record exists, then echoes it:
  // the capture is taken while the child is exactly as stalled as #2226's was.
  const child = join(root, "stalled-child");
  const script = `while [ -z "$(ls ${root}/records/*.log 2>/dev/null)" ]; do sleep 0.05; done; cat`;
  const output = execFileSyncWithStallCapture("/bin/sh", ["-c", script, child], { input: "delivered", encoding: "utf8", timeout: 10_000 },
    { label: "stalled", thresholdMs: 200, directory: join(root, "records") });
  // The call itself is unchanged: same input, same output.
  expect(output).toBe("delivered");
  const [name] = await readdir(join(root, "records"));
  const record = await readFile(join(root, "records", name!), "utf8");
  expect(record).toContain("native exec stall: alive past 0.200 s");
  expect(record).toMatch(/^load: \{ [\d.]+ [\d.]+ [\d.]+ \}$/mu);
  expect(record).toContain(`\n${String(process.pid).padStart(5)} `);
  expect(record).toMatch(/== child stdio\n[\s\S]*\n\S+\s+\d+\s+\S+\s+0u?\s+unix/u);
  expect(record).toContain("== parent unix sockets");
  expect(record).toContain("== child sample");
  expect(record).toContain("== parent sample");
  expect(watchers(root)).toBe("");
});

it("leaves no record and no watcher when a native exec answers within its threshold", async () => {
  const root = await directory();
  expect(execFileSyncWithStallCapture("/bin/cat", [], { input: "fast", encoding: "utf8", timeout: 10_000 },
    { label: "fast", thresholdMs: 5_000, directory: join(root, "records") })).toBe("fast");
  expect(await readdir(join(root, "records"))).toEqual([]);
  expect(watchers(root)).toBe("");
});
