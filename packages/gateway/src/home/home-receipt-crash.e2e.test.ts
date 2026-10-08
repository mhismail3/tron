import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterAll, describe, expect, it, vi } from "vitest";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";

const childProgram = fileURLToPath(new URL("../../test-support/home-receipt-crash-child.ts", import.meta.url));
const preload = fileURLToPath(new URL("../../test-support/home-ledger-crash-preload.mjs", import.meta.url));
const binding = { homeId: "receipt-crash-home", bindingRevision: 1, physicalSessionId: "receipt-crash-chapter" };
const result = { logicalSessionId: "home", homeId: binding.homeId, bindingRevision: 1,
  sessionId: binding.physicalSessionId, operationId: "accepted-before-crash" };
const report: Array<Record<string, unknown>> = [];

afterAll(async () => {
  const directory = join(process.cwd(), "test-results", "home-receipt-crash");
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "report.json"), `${JSON.stringify({ cases: report }, null, 2)}\n`);
});

describe("Home receipts at real-process crash cuts", () => {
  it.each(["binding", "effects", "completion"] as const)("retains the exact command target after SIGKILL at %s", async cut => {
    const root = await mkdtemp(join(tmpdir(), "tron-home-receipt-crash-"));
    try {
      const marker = join(root, "barrier");
      const ledgerPath = join(root, "home.json");
      const receiptDirectory = join(root, "gateway", "command-receipts");
      await writeFile(ledgerPath, JSON.stringify({ enabled: true, binding }));
      const child = spawn(process.execPath, ["--experimental-transform-types", "--import", pathToFileURL(preload).href,
        childProgram, root, cut, marker], { stdio: ["pipe", "pipe", "pipe"] });
      let output = "";
      child.stdout.on("data", (data: Buffer) => { output += data.toString(); });
      child.stderr.on("data", (data: Buffer) => { output += data.toString(); });
      const exit = once(child, "exit");
      let store: CommandReceiptStore | undefined;
      try {
        await waitFor(async () => {
          try { return await readFile(marker, "utf8"); }
          catch {
            if (child.exitCode !== null || child.signalCode !== null) throw new Error(`crash child exited before ${cut}: ${output}`);
            return undefined;
          }
        }, `${cut} receipt barrier`, { boundMs: 10_000 });
        child.kill("SIGKILL");
        const [, signal] = await awaitsWithin(exit, "crash child termination") as [number | null, NodeJS.Signals | null];
        expect(signal).toBe("SIGKILL");
        const receiptFiles = (await readdir(receiptDirectory)).filter(name => /^[A-Za-z0-9_-]{43}\.json$/.test(name));
        expect(receiptFiles).toHaveLength(1);
        const receiptPath = join(receiptDirectory, receiptFiles[0]!);
        const receiptBytes = await readFile(receiptPath, "utf8");
        expect(JSON.parse(receiptBytes)).toMatchObject({ version: 2, binding,
          status: cut === "completion" ? "completed" : "pending" });
        const canonicalFiles = (await readdir(join(root, "sessions"))).filter(name => name.endsWith(".jsonl"));
        expect(canonicalFiles).toHaveLength(cut === "binding" ? 0 : 1);
        const canonicalPath = canonicalFiles[0] ? join(root, "sessions", canonicalFiles[0]) : undefined;
        const canonicalBytes = canonicalPath ? await readFile(canonicalPath, "utf8") : undefined;
        if (canonicalBytes) {
          const entries = canonicalBytes.trimEnd().split("\n").map(line => JSON.parse(line));
          expect(entries[0]).toMatchObject({ type: "session", id: binding.physicalSessionId });
          expect(entries.filter(entry => entry.type === "message" && entry.message.role === "user")).toHaveLength(1);
        }
        // Only current route facts change; the old command's durable binding must not.
        await writeFile(ledgerPath, JSON.stringify({ enabled: false,
          binding: { ...binding, bindingRevision: 2, physicalSessionId: "successor-chapter" } }));
        store = new CommandReceiptStore(root);
        const resolveBinding = vi.fn(async () => JSON.parse(await readFile(ledgerPath, "utf8")).binding);
        const effect = vi.fn(async () => { throw new Error("crashed Home command replayed effects"); });
        const replay = store.execute("device:receipt-crash", "home.prompt", "home-receipt-crash-command", effect, { resolveBinding });
        if (cut === "completion") await expect(replay).resolves.toEqual(result);
        else await expect(replay).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
        expect(resolveBinding).not.toHaveBeenCalled();
        expect(effect).not.toHaveBeenCalled();
        expect(await readFile(receiptPath, "utf8")).toBe(receiptBytes);
        if (canonicalPath) expect(await readFile(canonicalPath, "utf8")).toBe(canonicalBytes);
        report.push({ cut, signal, receipt: cut === "completion" ? "completed" : "pending",
          canonicalConversations: canonicalFiles.length, replayed: false, originalTargetRetained: true });
      } finally {
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        await awaitsWithin(exit, "owned child cleanup");
        await store?.dispose();
      }
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }, 20_000);
});
