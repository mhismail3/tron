import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { chmod, cp, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import { test } from "node:test";

const gatewayRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const cli = join(gatewayRoot, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
const ai = join(gatewayRoot, "node_modules", "@earendil-works", "pi-ai", "dist", "providers", "faux.js");
const parentExtension = join(gatewayRoot, "dist", "delegation", "pi-subagents", "index.js");
const ownedPackage = join(gatewayRoot, "dist", "delegation", "pi-subagents");

function cleanEnvironment(root) {
  return {
    HOME: root,
    TMPDIR: join(root, "tmp"),
    PI_CODING_AGENT_DIR: join(root, "agent"),
    PI_SUBAGENTS_TEMP_ROOT: join(root, "pi-subagents-temp"),
    PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
    SCENARIO: "foreground",
    PROOF: join(root, "proof.jsonl"),
  };
}

async function fixture(root, scenario) {
  const environment = cleanEnvironment(root);
  environment.SCENARIO = scenario;
  await mkdir(join(root, "agent", "agents"), { recursive: true });
  await mkdir(join(root, "agent", "extensions", "subagent"), { recursive: true });
  await mkdir(join(root, "tmp"), { recursive: true });
  await writeFile(join(root, "agent", "extensions", "subagent", "config.json"), JSON.stringify({
    maxSubagentDepth: scenario === "depth-denied" ? 1 : 2,
    maxSubagentSpawnsPerSession: 8,
  }));
  const provider = `
    import { appendFileSync } from "node:fs";
    import { fauxProvider, fauxToolCall, fauxAssistantMessage } from ${JSON.stringify(ai)};
    export default function register(pi) {
      const faux = fauxProvider();
      const child = process.env.PI_SUBAGENT_CHILD === "1";
      const depth = Number(process.env.PI_SUBAGENT_DEPTH ?? 0);
      const proof = { pid: process.pid, child, fanout: process.env.PI_SUBAGENT_FANOUT_CHILD === "1", depth, cwd: process.cwd(), home: process.env.HOME, temp: process.env.PI_SUBAGENTS_TEMP_ROOT, scenario: process.env.SCENARIO };
      if (!child) {
        appendFileSync(process.env.PROOF, JSON.stringify(proof) + "\\n");
        const nested = process.env.SCENARIO === "nested-authorized" || process.env.SCENARIO === "depth-denied" || process.env.SCENARIO === "denied-agent" || process.env.SCENARIO === "denied-tool" || process.env.SCENARIO === "denied-extension";
        const args = nested
          ? { agent: "fixture", task: "child", async: false }
          : { agent: "fixture", task: "child", async: process.env.SCENARIO === "async" };
        faux.setResponses([
          fauxAssistantMessage(fauxToolCall("subagent", args), { stopReason: "toolUse" }),
          fauxAssistantMessage("parent done"),
        ]);
      } else if (depth === 1 && (process.env.SCENARIO === "nested-authorized" || process.env.SCENARIO === "depth-denied" || process.env.SCENARIO === "denied-agent" || process.env.SCENARIO === "denied-tool" || process.env.SCENARIO === "denied-extension")) {
        let args = { agent: "fixture", task: "grandchild", async: false };
        if (process.env.SCENARIO === "denied-agent") args = { agent: "does-not-exist", task: "forbidden", async: false };
        if (process.env.SCENARIO === "denied-tool") args = { agent: "fixture", task: "forbidden", tools: ["bash"], async: false };
        if (process.env.SCENARIO === "denied-extension") args = { agent: "fixture", task: "forbidden", extensions: ["/definitely-not-an-approved-extension.mjs"], async: false };
        faux.setResponses([
          fauxAssistantMessage(fauxToolCall("subagent", args), { stopReason: "toolUse" }),
          fauxAssistantMessage("child settled"),
        ]);
      } else {
        faux.setResponses([fauxAssistantMessage("grandchild settled")]);
      }
      pi.registerProvider({ ...faux.provider, streamSimple(model, context, options) { appendFileSync(process.env.PROOF, JSON.stringify(proof) + "\\n"); return faux.provider.streamSimple(model, context, options); } });
    }
  `;
  const providerPath = join(root, "fixture-provider.mjs");
  await writeFile(providerPath, provider);
  await writeFile(join(root, "agent", "agents", "fixture.md"), `---\nname: fixture\ndescription: isolated fixture\nmodel: faux/faux-1\nallowNestedSubagents: true\nextensions: ${providerPath}\n---\nfixture\n`);
  const parent = `
    import { fauxProvider, fauxToolCall, fauxAssistantMessage } from ${JSON.stringify(ai)};
    import registerSubagent from ${JSON.stringify(parentExtension)};
    export default function register(pi) {
      const faux = fauxProvider();
      const args = process.env.SCENARIO === "nested-authorized" || process.env.SCENARIO === "depth-denied" || process.env.SCENARIO === "denied-agent" || process.env.SCENARIO === "denied-tool" || process.env.SCENARIO === "denied-extension"
        ? { agent: "fixture", task: "child", async: false }
        : { agent: "fixture", task: "child", async: process.env.SCENARIO === "async" };
      faux.setResponses([
        fauxAssistantMessage(fauxToolCall("subagent", args), { stopReason: "toolUse" }),
        fauxAssistantMessage("parent done"),
      ]);
      pi.registerProvider(faux.provider);
      registerSubagent(pi);
    }
  `;
  const parentPath = join(root, "parent-extension.mjs");
  await writeFile(parentPath, parent);
  return { environment, providerPath, parentPath };
}

function runPi(root, environment, prompt = "fixture parent") {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [cli, "--no-extensions", "-e", join(root, "parent-extension.mjs"), "--provider", "faux", "--model", "faux/faux-1", "--no-session", "--mode", "json", "--print", prompt], {
      cwd: root,
      env: Object.fromEntries(Object.entries(environment).filter(([key]) => key !== "PI_SUBAGENT_CHILD")),
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
    });
    let output = "";
    const timer = setTimeout(() => {
      try { if (child.pid) process.kill(-child.pid, "SIGKILL"); } catch {}
      reject(new Error(`fixture timed out; output=${output.slice(-4000)}`));
    }, 20_000);
    child.stdout.on("data", (chunk) => { output = (output + String(chunk)).slice(-120_000); });
    child.stderr.on("data", (chunk) => { output = (output + String(chunk)).slice(-120_000); });
    child.once("error", (error) => { clearTimeout(timer); reject(error); });
    child.once("close", (code, signal) => {
      clearTimeout(timer);
      if (code !== 0) reject(new Error(`fixture exited ${signal ?? code}; output=${output.slice(-4000)}`));
      else resolve(output);
    });
  });
}

async function proofRows(path) {
  const text = await readFile(path, "utf8").catch(() => "");
  return text.trim() ? text.trim().split("\n").map((line) => JSON.parse(line)) : [];
}

async function runScenario(scenario) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-delegation-public-")));
  try {
    const { environment } = await fixture(root, scenario);
    const output = await runPi(root, environment);
    const rows = await proofRows(environment.PROOF);
    return { root, output, rows };
  } catch (error) {
    await rm(root, { recursive: true, force: true });
    throw error;
  }
}

test("public foreground executor settles an isolated child through the real SDK", async () => {
  const { root, output, rows } = await runScenario("foreground");
  try {
    assert.match(output, /child done|parent done/);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].child, true);
    assert.equal(rows[0].fanout, true);
    for (const row of rows) {
      assert.equal(row.home, root);
      assert.equal(row.temp, join(root, "pi-subagents-temp"));
      assert.equal(row.cwd, root);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("authorized fanout child reaches exactly one grandchild and settles every process", async () => {
  const { root, output, rows } = await runScenario("nested-authorized");
  try {
    assert.match(output, /child settled|grandchild settled/);
    assert.equal(rows.length, 2);
    assert.deepEqual(rows.map((row) => row.depth), [1, 2]);
    assert.equal(new Set(rows.map((row) => row.pid)).size, 2);
  } finally { await rm(root, { recursive: true, force: true }); }
});

for (const scenario of ["depth-denied", "denied-agent", "denied-tool", "denied-extension"]) {
  test(`nested ${scenario} denies before unauthorized child execution`, async () => {
    const { root, output, rows } = await runScenario(scenario);
    try {
      assert.match(output, /child settled|child done|denied|depth|not found|unavailable|extension/i);
      assert.equal(rows.length, 1);
      assert.deepEqual(rows.map((row) => row.depth), [1]);
      assert.equal(new Set(rows.map((row) => row.pid)).size, 1);
    } finally { await rm(root, { recursive: true, force: true }); }
  });
}

test("async public execution settles its detached child in the fixture-owned temp root", async () => {
  const { root, output, rows } = await runScenario("async");
  try {
    assert.match(output, /started|queued|running|parent done|Mission/);
    for (let attempt = 0; attempt < 40 && rows.length < 2; attempt += 1) await new Promise((resolve) => setTimeout(resolve, 100));
    const settled = await proofRows(join(root, "proof.jsonl"));
    assert.equal(settled.length, 1);
    assert.equal(settled[0].child, true);
    assert.equal(settled[0].temp, join(root, "pi-subagents-temp"));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("the shipped owned package resolves through an isolated consumer binding", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-delegation-package-"));
  try {
    const packageRoot = join(root, "node_modules", "pi-subagents");
    await mkdir(join(root, "node_modules"), { recursive: true });
    await cp(ownedPackage, packageRoot, { recursive: true });
    for (const dependency of ["@earendil-works/pi-agent-core", "@earendil-works/pi-ai", "@earendil-works/pi-coding-agent", "@earendil-works/pi-tui", "acorn", "get-east-asian-width", "jiti", "marked", "typebox", "yaml"]) {
      const source = join(gatewayRoot, "node_modules", dependency);
      const destination = join(root, "node_modules", dependency);
      await mkdir(dirname(destination), { recursive: true });
      await cp(source, destination, { recursive: true });
    }
    await writeFile(join(root, "consumer.mjs"), "import register from 'pi-subagents'; export const identity = typeof register;\n");
    const consumer = await import(pathToFileURL(join(root, "consumer.mjs")).href);
    assert.equal(consumer.identity, "function");
    const metadata = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
    assert.equal(metadata.name, "pi-subagents");
    assert.equal(metadata.version, "0.59.0-tron.1");
  } finally { await rm(root, { recursive: true, force: true }); }
});
