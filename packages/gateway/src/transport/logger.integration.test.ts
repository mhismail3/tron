import { mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayLogger } from "./logger.js";
import { RotatingJsonl } from "./rotating-jsonl.js";

const roots: string[] = [];
afterEach(async () => {
  vi.unstubAllEnvs();
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

async function logsDirectory(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "tron-logger-"));
  roots.push(root);
  return join(root, "logs");
}

const lines = async (path: string) => (await readFile(path, "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line) as { message?: string; n?: number });

describe("Gateway log streams on disk", () => {
  it("rotates the Gateway log at its segment bound and reloads the newest records across segments in order", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    const directory = await logsDirectory();
    const path = join(directory, "gateway.jsonl");
    const logger = new GatewayLogger(path);
    const text = "m".repeat(1_900);
    let written = 0;
    while (!(await stat(`${path}.1`).catch(() => undefined))) {
      logger.log("info", `${written} ${text}`, { event: "test.fill" });
      written += 1;
    }
    for (let extra = 0; extra < 300; extra += 1) logger.log("info", `${written++} ${text}`, { event: "test.fill" });

    const rotated = await stat(`${path}.1`);
    expect(rotated.size).toBeLessThanOrEqual(5 * 1_024 * 1_024);
    expect(rotated.size).toBeGreaterThan(5 * 1_024 * 1_024 - 4_096);
    expect(rotated.mode & 0o777).toBe(0o600);
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    expect((await stat(directory)).mode & 0o777).toBe(0o700);
    const active = await lines(path);
    const previous = await lines(`${path}.1`);
    expect(previous[0]!.message!.startsWith("0 ")).toBe(true);
    expect(Number(active[0]!.message!.split(" ")[0])).toBe(Number(previous.at(-1)!.message!.split(" ")[0]) + 1);
    expect(active.at(-1)!.message!.startsWith(`${written - 1} `)).toBe(true);
    expect(active.length).toBeLessThan(1_000);

    const reloaded = new GatewayLogger(path).recent(1_000).map((record) => Number(record.message.split(" ")[0]));
    expect(reloaded).toEqual(Array.from({ length: 1_000 }, (_unused, index) => written - 1_000 + index));
  });

  it("keeps a fixed number of segments, newest first, and drops the oldest", async () => {
    const directory = await logsDirectory();
    const path = join(directory, "requests.jsonl");
    const stream = new RotatingJsonl(path, 64, 3);
    for (let n = 0; n < 12; n += 1) stream.append({ n, pad: "p".repeat(20) });
    expect((await readdir(directory)).sort()).toEqual(["requests.jsonl", "requests.jsonl.1", "requests.jsonl.2"]);
    const kept = [...await lines(`${path}.2`), ...await lines(`${path}.1`), ...await lines(path)].map((record) => record.n);
    expect(kept).toEqual(Array.from({ length: kept.length }, (_unused, index) => 12 - kept.length + index));
    expect(kept.length).toBeLessThan(12);
    for (const name of ["requests.jsonl", "requests.jsonl.1", "requests.jsonl.2"]) {
      expect((await stat(join(directory, name))).size).toBeLessThanOrEqual(64);
    }

    const resumed = new RotatingJsonl(path, 64, 3);
    resumed.append({ n: 12, pad: "p".repeat(20) });
    resumed.append({ n: 13, pad: "p".repeat(20) });
    const after = [...await lines(`${path}.2`), ...await lines(`${path}.1`), ...await lines(path)].map((record) => record.n);
    expect(after.at(-1)).toBe(13);
    expect(after).toEqual(Array.from({ length: after.length }, (_unused, index) => 14 - after.length + index));
  });
});
