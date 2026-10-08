import { writeFileSync } from "node:fs";
import { mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { CommandReceiptStore, type CommandReceiptBinding } from "../src/transport/command-receipts.js";
import type { JsonValue } from "../src/protocol/types.js";
import { durableAtomicWriteJson } from "../src/util/durable-json.js";

const [root, cut, marker] = process.argv.slice(2);
if (!root || !marker || !["binding", "effects", "completion"].includes(cut!)) throw new Error("expected receipt crash fixture arguments");
const binding = (JSON.parse(await readFile(join(root, "home.json"), "utf8")) as { binding: CommandReceiptBinding }).binding;
const sessionDirectory = join(root, "sessions");
await mkdir(sessionDirectory, { recursive: true });
const freeze = async (): Promise<never> => {
  // Reuse the ledger harness's concrete parent-owned lifetime, not an unresolved
  // top-level promise (which alone permits Node to exit before SIGKILL).
  process.stdin.resume();
  writeFileSync(marker, `${cut}\n`);
  return new Promise<never>(() => {});
};
const store = new CommandReceiptStore(root, async (path, receipt, mode) => {
  await durableAtomicWriteJson(path, receipt, mode);
  const status = (receipt as { status: string }).status;
  if ((cut === "binding" && status === "pending") || (cut === "completion" && status === "completed")) await freeze();
});
await store.execute("device:receipt-crash", "home.prompt", "home-receipt-crash-command", async (): Promise<JsonValue> => {
  const manager = SessionManager.create(root, sessionDirectory);
  manager.newSession({ id: binding.physicalSessionId });
  manager.appendThinkingLevelChange("off");
  manager.appendMessage({ role: "user", content: "canonical input before receipt crash", timestamp: Date.now() });
  // First conversation flush is the pinned SDK's persistence boundary; no fake
  // JSONL, synthetic receipt file, or graceful disposal stands in for it.
  manager.appendMessage({ role: "assistant", content: [{ type: "text", text: "canonical response before receipt crash" }],
    api: "openai-completions", provider: "faux", model: "chat", stopReason: "stop", timestamp: Date.now(),
    usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
  if (cut === "effects") await freeze();
  return { logicalSessionId: "home", homeId: binding.homeId, bindingRevision: binding.bindingRevision,
    sessionId: binding.physicalSessionId, operationId: "accepted-before-crash" };
}, { resolveBinding: () => binding });
throw new Error("receipt crash child passed its owned cut without SIGKILL");
