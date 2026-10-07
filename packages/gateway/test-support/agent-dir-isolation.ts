import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll } from "vitest";

// Pi resolves default auth, models and settings from PI_CODING_AGENT_DIR. An
// agent-launched test run inherits the host's real agent directory, so any
// fixture that omits an explicit store would read the maintainer's real
// credentials (#556 exposed this as real OpenAI discovery attempts). Every
// worker gets its own empty agent directory instead.
const agentDir = mkdtempSync(join(tmpdir(), "gateway-test-agent-"));
process.env.PI_CODING_AGENT_DIR = agentDir;
afterAll(() => rmSync(agentDir, { recursive: true, force: true }));
