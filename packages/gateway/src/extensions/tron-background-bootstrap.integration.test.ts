import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

const gateway = fileURLToPath(new URL("../../", import.meta.url));
const runner = path.join(gateway, "dist/delegation/pi-subagents/src/runs/background/subagent-runner.js");

// Exercise the built runner and real SDK CLI, not a launch-plan surrogate. Only
// the model is fake; its request observes the fully assembled child prompt/tools.
async function runFixture(root: string, config: object): Promise<string> {
  const input = path.join(root, "config.json");
  await writeFile(input, JSON.stringify(config));
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [runner, input], {
      cwd: root,
      detached: true,
      env: {
        HOME: root,
        TMPDIR: path.join(root, "tmp"),
        PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin`,
        PI_CODING_AGENT_DIR: path.join(root, "agent"),
        PI_SUBAGENTS_TEMP_ROOT: path.join(root, "pi-subagents-temp"),
        TRON_DATA_DIR: path.join(root, "tron"),
        // An explicit runner context must beat an unrelated inherited value.
        TRON_CHILD_BOOTSTRAP_PROMPT: "WRONG_PARENT_CONTEXT",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      // This group belongs exclusively to the fixture, including its SDK child.
      if (child.pid) {
        try { process.kill(-child.pid, "SIGKILL"); } catch { /* Already settled. */ }
      }
    }, 20_000);
    child.stdout.on("data", (chunk) => { output = (output + String(chunk)).slice(-64_000); });
    child.stderr.on("data", (chunk) => { output = (output + String(chunk)).slice(-64_000); });
    child.once("error", (error) => { clearTimeout(timer); reject(error); });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (timedOut || code !== 0) reject(new Error(`Runner ${timedOut ? "timed out" : `exited ${code}`}: ${output}`));
      else resolve(output);
    });
  });
}

it.each(["single", "parallel"] as const)("carries a run-owned bootstrap through the real %s background runner", async (mode) => {
  const root = await mkdtemp(path.join(tmpdir(), "tron-background-bootstrap-"));
  try {
    await Promise.all(["tmp", "agent", "async", "artifacts"].map((name) => mkdir(path.join(root, name))));
    const proof = path.join(root, "proof.jsonl");
    const extension = path.join(root, "faux.mjs");
    const ai = path.join(gateway, "node_modules/@earendil-works/pi-ai/dist/index.js");
    await writeFile(extension, `
      import { appendFileSync } from "node:fs";
      import { fauxProvider, fauxAssistantMessage } from ${JSON.stringify(ai)};
      export default function(pi) {
        const faux = fauxProvider();
        faux.setResponses([fauxAssistantMessage("fixture complete")]);
        pi.registerProvider({ ...faux.provider,
          streamSimple(model, context, options) {
            appendFileSync(${JSON.stringify(proof)}, JSON.stringify({
              prompt: context.systemPrompt,
              tools: (context.tools ?? []).map(tool => tool.name)
            }) + "\\n");
            return faux.provider.streamSimple(model, context, options);
          }
        });
      }
    `);
    const step = {
      agent: "fixture", task: "Reply briefly.", model: "faux/faux-1",
      extensions: [extension], tools: [],
      inheritGlobalContext: false, inheritProjectContext: false, inheritSkills: false,
      completionGuard: false, maxSubagentDepth: 0,
    };
    await runFixture(root, {
      id: `bootstrap-${mode}`,
      sessionId: "fixture-parent",
      tronBootstrapPrompt: `You are Tron. RUN_OWNED_${mode}`,
      steps: mode === "single" ? [step] : [{ parallel: [step, { ...step, agent: "fixture-two" }], concurrency: 2 }],
      cwd: root,
      placeholder: "{previous}",
      resultPath: path.join(root, "result.json"),
      asyncDir: path.join(root, "async"),
      artifactsDir: path.join(root, "artifacts"),
      artifactConfig: { enabled: false },
      piPackageRoot: path.join(gateway, "node_modules/@earendil-works/pi-coding-agent"),
      piArgv1: path.join(gateway, "node_modules/@earendil-works/pi-coding-agent/dist/cli.js"),
    });
    const result = JSON.parse(await readFile(path.join(root, "async/status.json"), "utf8"));
    expect(result, JSON.stringify(result)).toMatchObject({ state: "complete" });
    const requests = (await readFile(proof, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    expect(requests).toHaveLength(mode === "single" ? 1 : 2);
    for (const request of requests) {
      expect(request.prompt).toContain(`RUN_OWNED_${mode}`);
      expect(request.prompt).not.toContain("WRONG_PARENT_CONTEXT");
      expect(request.tools).not.toContain("bash");
      expect(request.tools).not.toContain("subagent");
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}, 30_000);
