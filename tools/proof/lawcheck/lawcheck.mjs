#!/usr/bin/env node
// Purpose: `scripts/tron proof check`: incremental, cached Dafny checking of proof blocks, scoped to
// "this block and below", with the pinned toolchain only (tools/proof/README.md "Check").
//
// A block is a directory under <root>/blocks holding block.json:
//   {"interface": [laws files], "impl": [definition and proof files], "deps": [block names]}
// Paths are relative to <root>; the block's name is its directory relative to <root>/blocks.
// A dependent may use ONLY its deps' interfaces (Dafny abstract-module refinement), and every
// `include` must name the block's own files or a transitive dep's interface file. Therefore
//   key(block) = H(toolchain pin, this checker, own files, interfaces of every transitive dep)
// so an impl/proof edit re-checks that block alone and a law edit re-checks it and every block above it.
// Passing keys are cached per worktree (<git dir>/proof/lawcheck-cache.json unless --cache).
//
// Exit 0: every requested block passed (checked or cached). 1: a block failed; blocks above it are not
// run. 2: usage, block-graph or toolchain error.
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../../..");
const PIN = join(HERE, "../dafny.pin");
// Flags are part of every key: a change to them re-checks everything.
const VERIFY_FLAGS = ["verify", "--cores", "1", "--verify-included-files", "--verification-time-limit", "60"];

class UsageError extends Error {}

function parseArgs(argv) {
  const out = { root: join(ROOT, "packages/core"), cache: null, json: false, blocks: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--root" || a === "--cache") {
      if (i + 1 >= argv.length) throw new UsageError(`${a} needs a path`);
      out[a.slice(2)] = resolve(argv[++i]);
    } else if (a === "--json") out.json = true;
    else if (a.startsWith("-")) throw new UsageError(`unknown option ${a}`);
    else out.blocks.push(a);
  }
  return out;
}

function findBlocks(root) {
  const base = join(root, "blocks");
  const blocks = new Map();
  if (!existsSync(base)) return blocks;
  const walk = (dir) => {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (name === "block.json") {
        const spec = JSON.parse(readFileSync(path, "utf8"));
        const blockName = relative(base, dir).split(sep).join("/");
        const keys = Object.keys(spec).sort().join(",");
        if (keys !== "deps,impl,interface") throw new UsageError(`${blockName}: block.json keys must be interface, impl, deps (got ${keys})`);
        for (const f of [...spec.interface, ...spec.impl]) {
          if (!existsSync(join(root, f))) throw new UsageError(`${blockName}: missing file ${f}`);
        }
        if (spec.interface.length + spec.impl.length === 0) throw new UsageError(`${blockName}: no files`);
        blocks.set(blockName, { name: blockName, dir, ...spec });
      }
    }
  };
  walk(base);
  return blocks;
}

// Transitive deps of `name`, deps first; rejects unknown deps and cycles.
function below(blocks, name, done = new Set(), path = []) {
  const b = blocks.get(name);
  if (!b) throw new UsageError(`unknown block ${name}${path.length ? ` (dep of ${path.at(-1)})` : ""}`);
  if (path.includes(name)) throw new UsageError(`dependency cycle: ${[...path, name].join(" -> ")}`);
  for (const d of b.deps) if (!done.has(d)) below(blocks, d, done, [...path, name]);
  done.add(name);
  return done;
}

// Dafny source with comments blanked (strings kept), so an `include` cannot hide behind a comment.
function code(text) {
  let out = "";
  for (let i = 0; i < text.length;) {
    if (text[i] === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"' && text[j] !== "\n") j += text[j] === "\\" ? 2 : 1;
      out += text.slice(i, j + 1); i = j + 1;
    } else if (text.startsWith("//", i)) {
      while (i < text.length && text[i] !== "\n") { out += " "; i++; }
    } else if (text.startsWith("/*", i)) {
      // Dafny block comments nest.
      let depth = 0;
      do {
        if (text.startsWith("/*", i)) { depth++; out += "  "; i += 2; }
        else if (text.startsWith("*/", i)) { depth--; out += "  "; i += 2; }
        else { out += text[i] === "\n" ? "\n" : " "; i++; }
      } while (depth > 0 && i < text.length);
    } else { out += text[i]; i++; }
  }
  return out;
}

// What a block's files may include: impl files see the block's own files and its transitive deps'
// interfaces; interface files see only interface files (own or deps'), because a dependent follows them
// transitively and its key covers only interfaces. Anything else would let a block see what its key omits.
function checkIncludes(root, blocks, b) {
  const deps = [...below(blocks, b.name)].filter((d) => d !== b.name);
  const laws = new Set([...b.interface, ...deps.flatMap((d) => blocks.get(d).interface)].map((f) => resolve(root, f)));
  const all = new Set([...laws, ...b.impl.map((f) => resolve(root, f))]);
  for (const [files, visible, what] of [[b.interface, laws, "an interface file of this block or a dep"], [b.impl, all, "its own file nor a dep's interface"]]) {
    for (const f of files.map((x) => resolve(root, x))) {
      for (const m of code(readFileSync(f, "utf8")).matchAll(/\binclude\s*"([^"]+)"/g)) {
        if (!visible.has(resolve(dirname(f), m[1]))) throw new UsageError(`${b.name}: ${relative(root, f)} includes ${m[1]}, which is neither ${what}`);
      }
    }
  }
}

function digest(root, files) {
  const h = createHash("sha256");
  for (const f of files) h.update(f).update("\0").update(readFileSync(join(root, f))).update("\0");
  return h.digest("hex");
}

function key(root, blocks, b, toolKey) {
  const h = createHash("sha256").update(toolKey).update(digest(root, [...b.interface, ...b.impl]));
  for (const d of [...below(blocks, b.name)].filter((n) => n !== b.name).sort()) h.update(d).update(digest(root, blocks.get(d).interface));
  return h.digest("hex");
}

function pinnedDafny() {
  const doctor = spawnSync("/bin/bash", [join(HERE, "../bootstrap.sh"), "doctor"], { encoding: "utf8" });
  if (doctor.status !== 0) throw new UsageError(`pinned toolchain unavailable: ${(doctor.stderr || doctor.stdout).trim()}`);
  return join(process.env.XDG_CACHE_HOME || join(homedir(), "Library/Caches"), "tron-proof/bin/dafny");
}

function defaultCache() {
  const gitDir = execFileSync("git", ["rev-parse", "--absolute-git-dir"], { cwd: ROOT, encoding: "utf8" }).trim();
  return join(gitDir, "proof/lawcheck-cache.json");
}

function main(argv) {
  const args = parseArgs(argv);
  const blocks = findBlocks(args.root);
  const names = args.blocks.length ? args.blocks : [...blocks.keys()];
  const order = [];
  for (const n of names) for (const m of below(blocks, n)) if (!order.includes(m)) order.push(m);
  for (const n of order) checkIncludes(args.root, blocks, blocks.get(n));
  if (order.length === 0) {
    console.log(`proof check: no blocks under ${relative(ROOT, join(args.root, "blocks")) || join(args.root, "blocks")}`);
    return 0;
  }
  const dafny = pinnedDafny();
  const toolKey = createHash("sha256").update(readFileSync(PIN)).update(readFileSync(fileURLToPath(import.meta.url))).update(VERIFY_FLAGS.join(" ")).digest("hex");
  const cachePath = args.cache ?? defaultCache();
  const cache = existsSync(cachePath) ? JSON.parse(readFileSync(cachePath, "utf8")) : {};
  const report = [];
  let ok = true;
  for (const n of order) {
    const b = blocks.get(n);
    const k = key(args.root, blocks, b, toolKey);
    if (cache[n] === k) { report.push({ block: n, status: "cached" }); continue; }
    const started = performance.now();
    const run = spawnSync(dafny, [...VERIFY_FLAGS, ...b.interface, ...b.impl], {
      cwd: args.root, encoding: "utf8", timeout: 900_000, env: { ...process.env, DAFNY_CORES: "1" },
    });
    const seconds = +((performance.now() - started) / 1000).toFixed(2);
    if (run.error) throw new UsageError(`${n}: could not run the pinned dafny: ${run.error.message}`);
    const summary = (run.stdout.match(/Dafny program verifier finished[^\n]*/) ?? [""])[0];
    if (run.status !== 0) {
      report.push({ block: n, status: "FAIL", seconds, output: `${run.stdout}${run.stderr}`.trim().slice(-4000) });
      ok = false;
      break;
    }
    cache[n] = k;
    report.push({ block: n, status: "checked", seconds, summary });
  }
  mkdirSync(dirname(cachePath), { recursive: true });
  writeFileSync(`${cachePath}.part`, `${JSON.stringify(cache, null, 1)}\n`);
  renameSync(`${cachePath}.part`, cachePath);
  if (args.json) console.log(JSON.stringify({ ok, report }, null, 1));
  else {
    for (const r of report) console.log(`${r.status.padEnd(7)} ${r.block}${r.seconds !== undefined ? ` ${r.seconds}s` : ""}${r.summary ? ` (${r.summary})` : ""}`);
    const failed = report.find((r) => r.status === "FAIL");
    if (failed) console.log(failed.output);
    console.log(`proof check: ${ok ? "PASS" : "FAIL"} (${report.filter((r) => r.status === "checked").length} checked, ${report.filter((r) => r.status === "cached").length} cached, ${order.length - report.length} not run)`);
  }
  return ok ? 0 : 1;
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch (error) {
  if (!(error instanceof UsageError) && !(error instanceof SyntaxError)) throw error;
  console.error(`proof check: ${error.message}`);
  process.exitCode = 2;
}
