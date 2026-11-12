// Purpose: Exercise pinned SDK session, status, config and process-proof producers in disposable homes.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { dirname, join, relative } from "node:path";
import { pathToFileURL } from "node:url";
import { createServer } from "node:net";

const [action, repo, temporary, home] = process.argv.slice(2);
const gateway = join(repo, "packages/gateway");
const peers = ["@earendil-works/pi-coding-agent", "@earendil-works/pi-ai", "@earendil-works/pi-tui", "@earendil-works/pi-agent-core", "@sinclair/typebox"];
registerHooks({ resolve(specifier, context, nextResolve) { return nextResolve(specifier, peers.some(name => specifier === name || specifier.startsWith(name + "/")) ? { ...context, parentURL: pathToFileURL(join(gateway, "package.json")).href } : context); } });
const { SessionManager } = await import("@earendil-works/pi-coding-agent");
const source = join(temporary, "pinned-sdk/package");
if (action === "create" || action === "hold") {
  const pin = JSON.parse(readFileSync(join(gateway, "pi-subagents-pin.json"), "utf8"));
  const archive = join(gateway, pin.closure.path);
  assert.equal(createHash("sha512").update(readFileSync(archive)).digest("hex"), pin.closure.sha512);
  mkdirSync(dirname(source), { recursive: true });
  execFileSync("tar", ["-xzf", archive, "-C", dirname(source)]);
}
const load = path => import(pathToFileURL(join(source, path)).href);
const { writePrivateAtomicJson } = await load("src/shared/atomic-json.ts");
const { statusWithLifecycleProjection } = await load("src/runs/shared/async-status-persistence.ts");
const { initializeProcessTerminal, finalizeProcessTerminal, readProcessTerminal, writeProcessTerminalCandidate } = await load("src/runs/background/process-terminal.ts");
const { validateSubagentRunConfig } = await load("src/runs/background/subagent-runner-bootstrap.ts");
const { readStatus } = await load("src/shared/utils.ts");
const { resolveLaunchBinding } = await load("src/shared/launch-contract.ts");
const { createRunFanoutBudget } = await load("src/runs/shared/run-fanout-budget.ts");
const { writeAsyncResultFile } = await load("src/runs/background/result-files.ts");
const { readAsyncRecoveryDescriptor, resolveAsyncRunLocation, resolveAsyncResumeTarget } = await load("src/runs/background/async-resume.ts");
const manifestPath = join(temporary, "sdk-fixture.json");
if (action.startsWith("handoff-")) {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const { writeParallelHandoffGroup } = await load("src/runs/shared/parallel-handoff.ts");
  writeParallelHandoffGroup({ manifestPath: join(home, manifest.asyncDir, "handoff.json"), runId: manifest.runId, mode: "single", source: "async", cwd: manifest.originalCwd, stepIndex: 0, flatStartIndex: 0, setup: { cwd: manifest.originalCwd, baseCommit: "a".repeat(40), worktrees: [] }, diffs: [], results: [], ...(action === "handoff-complete" ? { cleanup: { state: "complete", pruned: true, tasks: [] } } : {}) });
  console.log(JSON.stringify(manifest));
} else if (action === "create" || action === "hold") {
  const cwd = join(home, "gateway/home/workspace");
  mkdirSync(cwd, { recursive: true, mode: 0o700 });
  const manager = SessionManager.create(cwd);
  manager.appendMessage({ role: "user", content: [{ type: "text", text: cwd }], timestamp: Date.now() });
  manager.appendMessage({ role: "assistant", content: [{ type: "text", text: "fixture" }], api: "openai-responses", provider: "fixture", model: "fixture", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() });
  const session = manager.getSessionFile();
  assert.ok(session);
  assert.ok(readFileSync(session).length > 0);
  const runId = randomUUID();
  const runnerProcessInstanceId = randomUUID();
  const asyncDir = join(home, "internal/subagents/async-subagent-runs", runId);
  mkdirSync(asyncDir, { recursive: true, mode: 0o700 });
  const outputFile = join(asyncDir, "output-0.log");
  writeFileSync(outputFile, cwd);
  const configPath = join(home, "internal/subagents", `async-cfg-${runId}.json`);
  const extensionBindings = { "fixture/1": { path: cwd, cwd } };
  const agentFilePath = join(home, "internal/subagents/fixture-agent.md");
  writeFileSync(agentFilePath, "fixture", { mode: 0o600 });
  const agent = { name: "fixture", filePath: agentFilePath, systemPrompt: cwd, systemPromptMode: "replace", inheritProjectContext: false, inheritGlobalContext: false, inheritSkills: false };
  const binding = resolveLaunchBinding({ agent, task: cwd, systemPrompt: cwd, toolPlan: { effectiveToolAllowlist: [], excludeTools: [], extensionArgs: [], effectiveMcpTools: [] }, outputPath: outputFile, extensionBindings });
  const runFanoutBudget = createRunFanoutBudget(runId, 2);
  writePrivateAtomicJson(join(asyncDir, "run-fanout-budget.json"), runFanoutBudget);
  const resultPath = join(home, "internal/subagents/async-subagent-results", runId + ".json");
  const config = { id: runId, asyncDir, resultPath, cwd, placeholder: "fixture", sessionDir: dirname(session), runnerProcessInstanceId, launchBarrierToken: randomUUID(), runFanoutBudget, steps: [{ agent: "fixture", task: cwd, inheritProjectContext: false, inheritGlobalContext: false, inheritSkills: false, cwd, sessionFile: session, outputFile, outputPath: outputFile, launchBindingTask: cwd, extensionBindings, ...binding }] };
  writePrivateAtomicJson(join(asyncDir, "recovery-descriptor.json"), { version: 1, sourceRunId: runId, agent: "fixture", sessionFile: session, cwd, systemPromptMode: "replace", systemPrompt: cwd, outputMode: "inline", inheritProjectContext: false, inheritGlobalContext: false, inheritSkills: false, share: false, maxSubagentDepth: 0, outputPath: outputFile, artifactsDir: asyncDir, agentFilePath, memory: { scope: "user", path: agentFilePath }, sessionDir: dirname(session), runFanoutBudget, extensionBindings, launchContractDigest: binding.launchContractDigest });
  validateSubagentRunConfig(config);
  writePrivateAtomicJson(configPath, config);
  writePrivateAtomicJson(join(asyncDir, "status.json"), statusWithLifecycleProjection({ runId, sessionId: manager.getSessionId(), state: "complete", mode: "single", cwd, sessionRoot: dirname(session), sessionDir: dirname(session), sessionFile: session, outputFile, startedAt: Date.now(), steps: [{ index: 0, agent: "fixture", status: "complete", sessionFile: session, artifactPaths: { outputPath: outputFile } }] }));
  initializeProcessTerminal(asyncDir, runId, runnerProcessInstanceId);
  writeProcessTerminalCandidate(asyncDir, { version: 1, runId, runnerProcessInstanceId, writers: { "0": [] }, expectedWriters: { "0": 0 }, sessionFile: session });
  const manifest = { binding, session: relative(home, session), sessionId: manager.getSessionId(), runId, asyncDir: relative(home, asyncDir), config: relative(home, configPath), originalCwd: cwd };
  writeFileSync(manifestPath, JSON.stringify(manifest));
  const child = spawn(process.execPath, ["-e", action === "hold" ? "process.stdin.once('data',()=>process.exit(0))" : ""], { stdio: ["pipe", "ignore", "inherit"] });
  const closed = new Promise((resolve, reject) => { child.once("error", reject); child.once("close", (code, signal) => resolve({ code, signal })); });
  if (action === "hold") {
    console.log(JSON.stringify(manifest));
    await new Promise(resolve => process.stdin.once("data", resolve));
    child.stdin.end("release");
    process.stdin.pause();
  }
  const { code, signal } = await closed;
  assert.equal(code, 0);
  const proof = finalizeProcessTerminal(asyncDir, runId, { processInstanceId: runnerProcessInstanceId, closeObservedAt: Date.now(), exitCode: code, signal });
  assert.equal(proof.state, "observed", JSON.stringify(proof));
  const published = writeAsyncResultFile(resultPath, { id: runId, runId, sessionId: manager.getSessionId(), agent: "fixture", mode: "single", state: "complete", success: true, cwd, asyncDir, sessionFile: session, launchContractDigest: binding.launchContractDigest, results: [{ agent: "fixture", sessionFile: session, savedOutputPath: outputFile, artifactPaths: { outputPath: outputFile }, output: cwd }] });
  assert.equal(published.state, "public");
  if (action === "create") console.log(JSON.stringify(manifest));
} else {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const moved = action !== "old";
  const cwd = moved ? join(home, "state/home/workspace") : manifest.originalCwd;
  const sessionFile = SessionManager.findById(cwd, manifest.sessionId);
  assert.ok(sessionFile, "SDK default-cwd discovery must find the same session ID");
  const manager = SessionManager.open(sessionFile);
  assert.equal(manager.getSessionId(), manifest.sessionId);
  assert.equal(manager.getCwd(), cwd);
  assert.ok(manager.getEntries().some(entry => entry.type === "message" && entry.message.role === "user" && entry.message.content[0].text === manifest.originalCwd));
  if (action === "append") manager.appendMessage({ role: "user", content: [{ type: "text", text: "new runtime history" }], timestamp: Date.now() });
  const asyncDir = join(home, moved ? manifest.asyncDir.replace("internal/subagents/", "state/subagents/") : manifest.asyncDir);
  const status = readStatus(asyncDir);
  assert.equal(status.runId, manifest.runId);
  assert.equal(status.cwd, cwd);
  assert.equal(status.outputFile, join(asyncDir, "output-0.log"));
  assert.equal(status.sessionFile, manager.getSessionFile());
  assert.equal(status.sessionRoot, dirname(manager.getSessionFile()));
  assert.equal(status.sessionDir, dirname(manager.getSessionFile()));
  assert.equal(status.steps[0].sessionFile, manager.getSessionFile());
  assert.equal(status.steps[0].artifactPaths.outputPath, status.outputFile);
  assert.equal(readFileSync(status.outputFile, "utf8"), manifest.originalCwd);
  assert.equal(readProcessTerminal(asyncDir, { runId: manifest.runId }).state, "observed");
  const config = JSON.parse(readFileSync(join(home, moved ? manifest.config.replace("internal/subagents/", "state/subagents/") : manifest.config), "utf8"));
  validateSubagentRunConfig(config);
  assert.equal(config.steps[0].definitionDigest, manifest.binding.definitionDigest);
  assert.equal(config.steps[0].launchContractDigest, manifest.binding.launchContractDigest);
  assert.deepEqual(config.steps[0].extensionBindings, { "fixture/1": { path: manifest.originalCwd, cwd: manifest.originalCwd } });
  const descriptor = readAsyncRecoveryDescriptor(asyncDir);
  assert.equal(descriptor.cwd, cwd);
  assert.equal(descriptor.memory.path, join(home, moved ? "state/subagents/fixture-agent.md" : "internal/subagents/fixture-agent.md"));
  assert.equal(descriptor.sessionFile, manager.getSessionFile());
  assert.equal(descriptor.launchContractDigest, manifest.binding.launchContractDigest);
  assert.equal(readFileSync(descriptor.agentFilePath, "utf8"), "fixture");
  const resultsDir = join(home, moved ? "state/subagents/async-subagent-results" : "internal/subagents/async-subagent-results");
  const location = resolveAsyncRunLocation({ id: manifest.runId }, dirname(asyncDir), resultsDir);
  assert.equal(location.asyncDir, asyncDir);
  const result = JSON.parse(readFileSync(location.resultPath, "utf8"));
  assert.equal(result.cwd, cwd);
  assert.equal(result.results[0].savedOutputPath, config.steps[0].outputFile);
  assert.equal(result.launchContractDigest, manifest.binding.launchContractDigest);
  const target = resolveAsyncResumeTarget({ id: manifest.runId }, { asyncDirRoot: dirname(asyncDir), resultsDir, kill: () => false }, { requireSessionFile: true });
  assert.equal(target.kind, "revive");
  assert.equal(target.sessionFile, manager.getSessionFile());
  assert.equal(target.cwd, cwd);
  assert.equal(config.cwd, cwd);
  assert.equal(config.asyncDir, asyncDir);
  assert.equal(config.resultPath, location.resultPath);
  assert.equal(config.steps[0].task, manifest.originalCwd);
  if (["probe", "race", "serve"].includes(action)) {
    const { waitFor, awaitsWithin } = await import(pathToFileURL(join(gateway, "test-support/wait-for.ts")).href);
    const socket = createServer();
    await new Promise(resolve => socket.listen(0, "127.0.0.1", resolve));
    const port = socket.address().port;
    await new Promise(resolve => socket.close(resolve));
    const preloads = ["--import", pathToFileURL(join(gateway, "test-support/home-ledger-crash-preload.mjs")).href];
    if (action === "race") {
      const gate = join(temporary, "before-agent-lock.mjs");
      writeFileSync(gate, `import fs from "node:fs"; import { syncBuiltinESMExports } from "node:module"; const original = fs.promises.mkdir; let held = false; fs.promises.mkdir = async (path, ...args) => { if (!held && String(path) === ${JSON.stringify(join(home, "agent"))}) { held = true; process.stdout.write("fixture-before-agent-lock\\n"); await new Promise(resolve => process.stdin.once("data", resolve)); process.stdin.pause(); } return original(path, ...args); }; syncBuiltinESMExports();`);
      preloads.push("--import", pathToFileURL(gate).href);
    }
    const child = spawn(process.execPath, ["--experimental-transform-types", "--no-warnings", ...preloads, join(gateway, "src/index.ts")], { cwd: gateway, stdio: ["pipe", "pipe", "pipe"], env: { PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: process.env.TMPDIR, TRON_DATA_DIR: home, PI_CODING_AGENT_DIR: join(home, "agent"), PI_SUBAGENTS_TEMP_ROOT: join(home, "state/subagents"), TRON_GATEWAY_HOST: "127.0.0.1", TRON_GATEWAY_PORT: String(port) } });
    let output = "";
    child.stdout.on("data", chunk => { output += chunk; });
    child.stderr.on("data", chunk => { output += chunk; });
    const closed = new Promise((resolve, reject) => { child.once("error", reject); child.once("close", (code, signal) => resolve({ code, signal })); });
    try {
      if (action !== "probe") {
        await waitFor(() => {
          if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Gateway exited before its boundary: ${output}`);
          if (action === "race") return output.includes("fixture-before-agent-lock");
          try { return readFileSync(join(home, "logs/gateway.jsonl"), "utf8").includes('"gateway.startup-budget"'); }
          catch (error) { if (error.code !== "ENOENT") throw error; return false; }
        }, "actual Gateway reached its controlled runtime boundary");
        console.log(JSON.stringify({ ready: true }));
        await new Promise(resolve => process.stdin.once("data", resolve));
        process.stdin.pause();
        if (action === "race") child.stdin.end("release");
        else child.kill("SIGTERM");
      }
      const result = await awaitsWithin(closed, "actual Gateway exited");
      console.log(JSON.stringify({ ...result, output }));
    } catch (error) {
      throw new Error(`${String(error)}\n${output}`);
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
      await awaitsWithin(closed, "owned Gateway joined before cleanup");
    }
  } else {
    console.log(JSON.stringify({ session: relative(home, manager.getSessionFile()), sessionId: manager.getSessionId(), status: status.state, configValid: true }));
  }
}
