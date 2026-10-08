import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";

const childProgram = fileURLToPath(new URL("../../test-support/home-ledger-crash-child.ts", import.meta.url));
const preload = fileURLToPath(new URL("../../test-support/home-ledger-crash-preload.mjs", import.meta.url));
const roots: string[] = [];
const children: Array<ReturnType<typeof spawn>> = [];
const report: Array<{ barrier: string; observed: string; signal: string }> = [];
const sessionId = "home-crash-session";
const now = "2026-10-07T00:00:00.000Z";

async function killChild(child: ReturnType<typeof spawn>): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, "exit");
  child.kill("SIGKILL");
  await exited;
}

function initialRecord() {
  return {
    version: 2,
    homeId: "home-crash-id",
    chapters: [{ sessionId, ordinal: 1, state: "active", createdAt: now }],
    bindingRevision: 1,
    generation: 1,
    policyRevision: 1,
    enabled: true,
    model: { provider: "faux", id: "chat" },
    createdAt: now,
    updatedAt: now,
  };
}

async function runCrashCut() {
  const mode = "after" as const;
  const root = await mkdtemp(join(tmpdir(), "tron-home-ledger-crash-"));
  roots.push(root);
  const tronHome = join(root, "tron");
  const recordPath = join(tronHome, "gateway", "home", "home.json");
  const marker = join(root, "barrier-reached");
  await mkdir(join(tronHome, "gateway", "home"), { recursive: true });
  await writeFile(recordPath, `${JSON.stringify(initialRecord(), null, 2)}\n`, { mode: 0o600 });
  const child = spawn(process.execPath, [
    "--experimental-transform-types", "--import", pathToFileURL(preload).href,
    childProgram, tronHome, sessionId, mode, marker,
  ], { stdio: ["pipe", "pipe", "pipe"] });
  children.push(child);
  let output = "";
  child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  try {
    try {
      await waitFor(async () => {
        try { return await readFile(marker, "utf8"); }
        catch {
          if (child.exitCode !== null || child.signalCode !== null) throw new Error(`crash child exited before barrier (code=${child.exitCode}, signal=${child.signalCode}): ${output}`);
          return undefined;
        }
      }, `child reached ${mode} ledger barrier`, { boundMs: 15_000 });
    } catch (error) {
      throw new Error(`${error instanceof Error ? error.message : String(error)}; child output: ${output}`);
    }
    const exited = once(child, "exit");
    child.kill("SIGKILL");
    const [, signal] = await exited as [number | null, NodeJS.Signals | null];
    expect(signal).toBe("SIGKILL");
    const recovered = JSON.parse(await readFile(recordPath, "utf8")) as {
      chapters: Array<{ state: string; ordinal: number }>;
      bindingRevision: number;
    };
    {
      expect(recovered.chapters).toHaveLength(2);
      expect(recovered.chapters[0]).toMatchObject({ state: "sealed", ordinal: 1 });
      expect(recovered.chapters[1]).toMatchObject({ state: "reserved", ordinal: 2 });
      expect(recovered.bindingRevision).toBe(1);
    }
    report.push({ barrier: mode, observed: recovered.chapters.map(chapter => chapter.state).join(","), signal: "SIGKILL" });
  } finally {
    await killChild(child);
  }
}

afterEach(async () => {
  for (const child of children.splice(0)) await killChild(child);
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

afterAll(async () => {
  const directory = join(process.cwd(), "test-results", "home-ledger-crash");
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "report.json"), `${JSON.stringify({ cases: report }, null, 2)}\n`);
});

describe("Home ledger real-process crash cuts", () => {
  it("recovers a real HomeOwner seal/reserve after SIGKILL at the visible-commit barrier", async () => {
    await runCrashCut();
  }, 30_000);
});
