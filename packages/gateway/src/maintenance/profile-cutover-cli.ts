import { createInterface } from "node:readline";
import { join } from "node:path";
import { ProfileCutover, PROFILE_BACKUP_NAME, PROFILE_CUTOVER_BINDING, type CutoverLifecycle } from "./profile-cutover.js";

const [home, maintenance, mode] = process.argv.slice(2);
if (!home || !maintenance || !["apply", "rollback", "plan"].includes(mode ?? "")) throw new Error("Internal cutover arguments required");
const backup = join(home, "workspace/files", PROFILE_BACKUP_NAME);
const operation = join(maintenance, "profile-cutover", PROFILE_CUTOVER_BINDING.candidate.slice(0, 16));
const input = createInterface({ input: process.stdin });
const replies = input[Symbol.asyncIterator]();
let sequence = 0;
async function call(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
  const id = ++sequence; process.stdout.write(JSON.stringify({ call: method, id, params }) + "\n");
  const next = await replies.next(); if (next.done) throw new Error("Maintainer lifecycle controller disconnected");
  const reply = JSON.parse(next.value) as { id: number; result?: unknown; error?: string };
  if (reply.id !== id || reply.error) throw new Error(reply.error ?? "Cutover controller receipt mismatch");
  return reply.result;
}
try {
  const owner = await ProfileCutover.prepare(home, backup, operation, PROFILE_CUTOVER_BINDING);
  const plan = { backup, operation, source: PROFILE_CUTOVER_BINDING.source, manifest: PROFILE_CUTOVER_BINDING.manifest,
    candidate: PROFILE_CUTOVER_BINDING.candidate, before: "60 legacy heads; 89 command fences; 291 Changes rows", after: "60 exact current heads in Profile.json; legacy preserved; Changes unchanged",
    rollback: "scripts/tron profile cutover --rollback", rollbackResult: "Restore backup bytes/rows and restart; current runtime returns the original legacy-Profile offline refusal" };
  process.stdout.write(JSON.stringify({ plan }) + "\n");
  if (mode !== "plan") {
    const lifecycle: CutoverLifecycle = { stop: async () => { await call("stop"); }, start: async () => { await call("start"); },
      rpc: (method, params) => call("rpc", { method, params }) };
    const result = await owner.run(lifecycle, mode === "rollback");
    process.stdout.write(JSON.stringify({ result }) + "\n");
  }
} catch (error) {
  console.error(error); // full diagnostics stay in the private controller log
  const causes: string[] = [];
  for (let count = 0; count < 3 && error instanceof Error; count++, error = error.cause) {
    causes.push(error.message.split("\n")[0]!.slice(0, 1_000));
  }
  process.stdout.write(JSON.stringify({ error: causes.join("; caused by ") || "Unknown cutover failure" }) + "\n");
  process.exitCode = 1;
} finally { input.close(); }
