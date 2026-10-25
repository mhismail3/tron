import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { TrustService } from "../src/kernel/resources/trust-service.js";
import { settingsDependencies } from "./settings-dependencies.js";

// A real owner in a separate process. The parent kills only this child at the
// external-effect/before-settlement cut; the action's preview deliberately stays
// unchanged so re-planning alone cannot prevent replay.
const [root, mode] = process.argv.slice(2);
if (!root || (mode !== "apply" && mode !== "recover")) throw new Error("root and apply|recover required");
const agentDir = join(root, "agent");
await mkdir(agentDir, { recursive: true });
const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
const { settingsChanges } = settingsDependencies({ agentDir, tronHome: join(root, "tron"), modelRuntime: runtime, trust: new TrustService(agentDir) });
const actor = { kind: "agent" as const, id: "crash-requester", sessionId: "crash-requester" };
settingsChanges.registerAction("fixture.append", {
  plan: async () => ({ title: "Append the effect", target: { kind: "global" }, items: [{ label: "Effect", value: "Append one line" }] }),
  apply: async () => {
    await appendFile(join(root, "effects.txt"), "effect\n");
    if (mode === "apply") {
      process.stdout.write("effect-ready\n");
      await new Promise<void>(resolve => { process.stdin.once("data", () => resolve()); });
    }
    return { summary: "Appended the effect" };
  },
});
const requestPath = join(root, "request.json");
const request = mode === "apply"
  ? (await settingsChanges.requestAction("fixture.append", {}, { actor, reason: "Crash recovery proof" })).approval!
  : JSON.parse(await readFile(requestPath, "utf8")) as { requestId: string; digest: string };
if (mode === "apply") await writeFile(requestPath, JSON.stringify(request));
let decision: string;
try {
  decision = (await settingsChanges.decide(request.requestId, { digest: request.digest, approved: true, decidedBy: { kind: "ui", id: "fixture" } })).status;
} catch (error) { decision = error instanceof Error ? error.message : String(error); }
const outcome = await settingsChanges.takeOutcomes(actor.sessionId);
process.stdout.write(`RESULT:${JSON.stringify({ decision, outcome, effects: await readFile(join(root, "effects.txt"), "utf8") })}\n`);
await settingsChanges.dispose();
