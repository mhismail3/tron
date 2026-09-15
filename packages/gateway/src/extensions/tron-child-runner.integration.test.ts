import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { spawn } from "node:child_process";
import { describe, expect, it } from "vitest";
import { pathToFileURL } from "node:url";

const piAi = pathToFileURL(join(process.cwd(), "node_modules/@earendil-works/pi-ai/dist/index.js")).href;
const codingAgent = pathToFileURL(join(process.cwd(), "node_modules/@earendil-works/pi-coding-agent/dist/index.js")).href;
const childProgram = `
import { InMemoryCredentialStore, fauxAssistantMessage, fauxProvider, fauxText } from ${JSON.stringify(piAi)};
import { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } from ${JSON.stringify(codingAgent)};
import { createTronChildBootstrapExtension } from ${JSON.stringify(new URL("./tron-child-bootstrap-extension.ts", import.meta.url).href)};
const root = process.env.TRON_CHILD_TEST_ROOT;
if (!root) throw new Error("missing isolated child root");
const faux = fauxProvider({ provider: "tron-child-fixture", models: [{ id: "fixture", reasoning: false }], tokensPerSecond: 100000 });
faux.setResponses([fauxAssistantMessage([fauxText("child-ok")])]);
const modelRuntime = await ModelRuntime.create({ modelsPath: null, credentials: new InMemoryCredentialStore(), refreshOnCreate: false });
modelRuntime.registerNativeProvider(faux.provider);
const settingsManager = SettingsManager.inMemory();
const loader = new DefaultResourceLoader({ cwd: root, agentDir: root, settingsManager, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [{ name: "tron-child-bootstrap", factory: createTronChildBootstrapExtension() }] });
await loader.reload();
const manager = SessionManager.inMemory();
const { session } = await createAgentSession({ cwd: root, agentDir: root, sessionManager: manager, modelRuntime, settingsManager, resourceLoader: loader, model: faux.getModel(), tools: [] });
await session.prompt("synthetic child task");
const entry = manager.getBranch().find((item) => item.type === "message" && item.message.role === "assistant");
const text = entry && entry.type === "message" && Array.isArray(entry.message.content) ? entry.message.content.filter((part) => part.type === "text").map((part) => part.text).join(" ") : "";
process.stdout.write(JSON.stringify({ text, bootstrap: session.systemPrompt.includes("Tron child context") }));
await session.dispose();
`;

describe("isolated Tron child runner", () => {
  it("executes a fake-provider child with Tron bootstrap and isolated roots", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-child-runner-"));
    const script = join(root, "child.mjs");
    await writeFile(script, childProgram, { mode: 0o600 });
    try {
      const result = await new Promise<{ code: number | null; stdout: string; stderr: string }>((resolve, reject) => {
        const child = spawn(process.execPath, ["--experimental-strip-types", script], {
          cwd: process.cwd(),
          env: {
            HOME: root,
            TMPDIR: join(root, "tmp"),
            PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
            PI_CODING_AGENT_DIR: join(root, "agent"),
            PI_SUBAGENTS_TEMP_ROOT: join(root, "pi-subagents-temp"),
            TRON_DATA_DIR: join(root, "tron"),
            TRON_CHILD_TEST_ROOT: root,
            TRON_CHILD_BOOTSTRAP_PROMPT: "Tron child context",
            PI_SUBAGENT_CHILD: "1",
          },
          stdio: ["ignore", "pipe", "pipe"],
        });
        let stdout = "";
        let stderr = "";
        let settled = false;
        let timedOut = false;
        const timer = setTimeout(() => {
          if (settled) return;
          timedOut = true;
          child.kill("SIGKILL");
        }, 15_000);
        child.stdout.on("data", (chunk) => { stdout += chunk; });
        child.stderr.on("data", (chunk) => { stderr += chunk; });
        child.once("error", (error) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          reject(error);
        });
        child.once("close", (code) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (timedOut) reject(new Error(`isolated child timed out: ${stderr}`));
          else resolve({ code, stdout, stderr });
        });
      });
      expect(result.code, result.stderr).toBe(0);
      expect(JSON.parse(result.stdout)).toEqual({ text: "child-ok", bootstrap: true });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }, 20_000);
});
