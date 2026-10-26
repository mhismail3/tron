import { writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { SettingsOutcomeMessage } from "../src/kernel/settings/tool-contract.js";

const [input, cut, marker] = process.argv.slice(2);
if (!input || !marker || (cut !== "before" && cut !== "after")) throw new Error("expected outcome crash fixture arguments");
const { path, outcome } = JSON.parse(await readFile(input, "utf8")) as { path: string; outcome: SettingsOutcomeMessage };
// The parent has disposed its Registry first: this process is the only writer.
// Use the pinned SDK's real append on an existing conversation, not fabricated
// JSONL or graceful Gateway disposal as a substitute for the crash boundary.
const manager = SessionManager.open(path);
if (cut === "after") manager.appendCustomMessageEntry(outcome.customType, outcome.content, outcome.display, outcome.details);
process.stdin.resume();
writeFileSync(marker, `${cut}\n`);
await new Promise<never>(() => {});
