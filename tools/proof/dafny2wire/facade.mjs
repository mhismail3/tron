#!/usr/bin/env node
// Purpose: `scripts/tron proof facade <block> [--check]`: the generated core façade of a proof block.
// Writes packages/core/dist/<block>/core.js (the block compiled to JavaScript by the pinned Dafny, unedited)
// and facade.ts, a typed TypeScript wrapper that marshals plain values to and from the compiled datatypes
// (int <-> BigNumber, datatypes <-> tagged objects), so no hand adapter sits between a shell and a core.
// --check regenerates into a temporary directory and fails if the checked-in files differ.
//
// The façade exposes every compiled (non-ghost) function and predicate the block's laws declare, with the
// signatures stated there, and checks each stated precondition (a call of a compiled predicate on parameters)
// before calling, because compiled code does not check `requires`; any other precondition is refused. Types: int/nat -> number (a safe integer, checked both ways), bool -> boolean,
// a datatype whose constructors all take no arguments -> a string union of their names, a one-constructor
// datatype named like its type -> a plain object, any other datatype -> an object tagged by `$` (the
// constructor name). Other Dafny types are refused until a block needs them.
// Exit 0: written or fresh. 1: --check found a difference. 2: usage, unsupported type or toolchain error.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
let CORE = join(REPO, "packages/core");
const DAFNY = join(process.env.XDG_CACHE_HOME || join(homedir(), "Library/Caches"), "tron-proof/bin/dafny");
class UsageError extends Error {}

function splitTop(s, sep) { const out = []; let depth = 0, cur = ""; for (const ch of s) { if ("(<".includes(ch)) depth++; if (")>".includes(ch)) depth--; if (ch === sep && depth === 0) { out.push(cur); cur = ""; } else cur += ch; } out.push(cur); return out.map((x) => x.trim()).filter(Boolean); }
const param = (p) => { const [name, ...type] = p.split(":"); return { name: name.trim(), type: type.join(":").trim() }; };

// Datatypes, compiled signatures and their preconditions in the block's laws file. Anything the façade
// cannot translate faithfully is refused, never skipped.
export function readLaws(text) {
  const code = text.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, "");
  // Declarations start a line; a declaration runs to the next one (or the module's closing brace).
  const starts = [...code.matchAll(/^[ \t]*((?:(?:ghost|opaque|static|function|predicate|method|lemma|datatype|codatatype|type|const|import|module|abstract)\b[ \t]*)+)/gm)];
  const datatypes = new Map();
  const functions = [];
  starts.forEach((m, i) => {
    const words = m[1].trim().split(/\s+/);
    const text = code.slice(m.index, i + 1 < starts.length ? starts[i + 1].index : code.length).replace(/\}\s*$/, "").trim();
    if (words.includes("datatype") || words.includes("codatatype")) {
      const d = /^(?:co)?datatype\s+(\w+)\s*(<[^>]*>)?\s*=\s*([\s\S]+)$/.exec(text);
      if (!d) throw new UsageError(`cannot read datatype: ${text.slice(0, 80)}`);
      if (d[2]) return; // generic datatypes are refused where a signature uses them (no shape is known)
      const ctors = splitTop(d[3].replace(/\s+/g, " ").trim().replace(/^\|/, ""), "|").map((c) => {
        const p = c.indexOf("(");
        return { name: (p < 0 ? c : c.slice(0, p)).trim(), fields: p < 0 ? [] : splitTop(c.slice(p + 1, c.lastIndexOf(")")), ",").map(param) };
      });
      datatypes.set(d[1], ctors);
      return;
    }
    if (!words.includes("function") && !words.includes("predicate")) return;
    if (words.includes("ghost")) return; // erased: not compiled, so not in the façade
    if (words.includes("method")) throw new UsageError(`'${words.join(" ")}' is not Dafny 4 syntax: ${text.slice(0, 60)}`);
    const f = /^(?:\w+\s+)*(function|predicate)\s+(\w+)\s*(<[^>]*>)?\s*\(([^)]*)\)\s*(?::\s*(\w+))?([\s\S]*)$/.exec(text);
    if (!f) throw new UsageError(`cannot read signature: ${text.slice(0, 80)}`);
    if (f[3]) throw new UsageError(`${f[2]}: generic functions are not supported by the façade`);
    const params = splitTop(f[4], ",").map(param);
    // The generated wrapper's own names; a parameter with one of them would shadow it.
    const taken = params.find((p) => ["M", "BigNumber", "require", "int", "nat", "bool", "num", "natNum", "bad", "unknown"].includes(p.name));
    if (taken) throw new UsageError(`${f[2]}: parameter name ${taken.name} is reserved by the façade`);
    // Preconditions the façade checks before calling: each must be a call of a compiled predicate on parameters.
    const spec = f[6].split("{")[0];
    const requires = [...spec.matchAll(/\brequires\b([\s\S]*?)(?=\brequires\b|\bensures\b|\bdecreases\b|\breads\b|$)/g)].map((r) => r[1].trim());
    const checks = requires.flatMap((r) => splitTop(r, "&").filter((x) => x !== "&")).map((clause) => {
      const c = /^(\w+)\(([^()]*)\)$/.exec(clause.replace(/^&+|&+$/g, "").trim());
      if (!c) throw new UsageError(`${f[2]}: precondition '${clause}' cannot be checked by the façade`);
      return { predicate: c[1], args: splitTop(c[2], ",") };
    });
    const unique = checks.filter((c, i) => checks.findIndex((d) => d.predicate === c.predicate && d.args.join() === c.args.join()) === i);
    functions.push({ name: f[2], params, returns: f[1] === "predicate" ? "bool" : f[5], checks: unique });
  });
  for (const fn of functions) for (const c of fn.checks) {
    if (!functions.some((g) => g.name === c.predicate && g.returns === "bool")) throw new UsageError(`${fn.name}: precondition ${c.predicate} is not a compiled predicate of the laws`);
    if (c.args.some((a) => !fn.params.some((p) => p.name === a))) throw new UsageError(`${fn.name}: precondition ${c.predicate}(${c.args.join(", ")}) must take parameters only`);
  }
  return { datatypes, functions };
}

export function emitFacade({ datatypes, functions }, module, source, packageJson) {
  const shape = (name) => {
    const ctors = datatypes.get(name);
    if (!ctors) return null;
    if (ctors.every((c) => c.fields.length === 0)) return "enum";
    if (ctors.length === 1 && ctors[0].name === name) return "record";
    return "union";
  };
  const tsType = (t) => {
    if (t === "int" || t === "nat") return "number";
    if (t === "bool") return "boolean";
    if (shape(t)) return t;
    throw new UsageError(`façade: unsupported Dafny type ${t}`);
  };
  const toCore = (t, v) => (t === "int" ? `int(${v})` : t === "nat" ? `nat(${v})` : t === "bool" ? `bool(${v})` : `to${t}(${v})`);
  const fromCore = (t, v) => (t === "int" ? `num(${v})` : t === "nat" ? `natNum(${v})` : t === "bool" ? v : `from${t}(${v})`);
  const used = new Set();
  const visit = (t) => { if (shape(t) && !used.has(t)) { used.add(t); for (const c of datatypes.get(t)) for (const f of c.fields) visit(f.type); } };
  for (const f of functions) { f.params.forEach((p) => { tsType(p.type); visit(p.type); }); tsType(f.returns); visit(f.returns); }
  const out = [
    `// GENERATED by tools/proof/dafny2wire/facade.mjs from ${source}. Do not edit.`,
    `// Typed façade over the compiled core ./core.js (module ${module}).`,
    `import { readFileSync } from "node:fs";`,
    `import { createRequire } from "node:module";`,
    `import { fileURLToPath } from "node:url";`,
    ``,
  ];
  for (const t of [...used].sort()) {
    const ctors = datatypes.get(t);
    const kind = shape(t);
    if (kind === "enum") out.push(`export type ${t} = ${ctors.map((c) => JSON.stringify(c.name)).join(" | ")};`);
    else if (kind === "record") out.push(`export interface ${t} { ${ctors[0].fields.map((f) => `readonly ${f.name}: ${tsType(f.type)}`).join("; ")} }`);
    else out.push(`export type ${t} =\n${ctors.map((c) => `  | { readonly $: ${JSON.stringify(c.name)}${c.fields.map((f) => `; readonly ${f.name}: ${tsType(f.type)}`).join("")} }`).join("\n")};`);
  }
  out.push(``, `export interface Core {`, ...functions.map((f) => `  ${f.name}(${f.params.map((p) => `${p.name}: ${tsType(p.type)}`).join(", ")}): ${tsType(f.returns)};`), `}`, ``);
  out.push(
    `// Loads a compiled core (the checked-in ./core.js, or a freshly translated one) and binds the façade to it.`,
    `export function load(corePath: string): Core {`,
    `  const require = createRequire(new URL(${JSON.stringify(packageJson)}, import.meta.url));`,
    `  // The compiled file is a script that declares its modules; evaluate it and take ${module} and BigNumber.`,
    `  const { M, BigNumber } = new Function("require", readFileSync(corePath, "utf8") + "\\nreturn { M: ${module}, BigNumber };")(require);`,
    `  const int = (n: number): unknown => { if (!Number.isSafeInteger(n)) throw new RangeError(\`not a safe integer: \${n}\`); return new BigNumber(n); };`,
    `  const nat = (n: number): unknown => { if (!Number.isSafeInteger(n) || n < 0) throw new RangeError(\`not a natural number: \${n}\`); return new BigNumber(n); };`,
    `  const bool = (b: boolean): boolean => { if (typeof b !== "boolean") throw new TypeError(\`not a boolean: \${String(b)}\`); return b; };`,
    `  const num = (b: { isInteger(): boolean; toNumber(): number }): number => { const n = b.toNumber(); if (!b.isInteger() || !Number.isSafeInteger(n)) throw new RangeError("core returned an integer outside the safe range"); return n; };`,
    `  const natNum = (b: { isInteger(): boolean; toNumber(): number }): number => { const n = num(b); if (n < 0) throw new RangeError("core returned a negative natural number"); return n; };`,
  );
  for (const t of [...used].sort()) {
    const ctors = datatypes.get(t);
    const kind = shape(t);
    const args = (c, src) => c.fields.map((f) => toCore(f.type, `${src}.${f.name}`)).join(", ");
    const fields = (c, src) => c.fields.map((f) => `${f.name}: ${fromCore(f.type, `${src}.dtor_${f.name}`)}`).join(", ");
    if (kind === "enum") {
      out.push(`  const to${t} = (v: ${t}): unknown => { switch (v) { ${ctors.map((c) => `case ${JSON.stringify(c.name)}: return M.${t}.create_${c.name}();`).join(" ")} default: return unknown("${t}", v); } };`,
        `  const from${t} = (v: any): ${t} => ${ctors.map((c) => `v.is_${c.name} ? ${JSON.stringify(c.name)} : `).join("")}bad("${t}");`);
    } else if (kind === "record") {
      out.push(`  const to${t} = (v: ${t}): unknown => { if (typeof v !== "object" || v === null) return unknown("${t}", v); return M.${t}.create_${ctors[0].name}(${args(ctors[0], "v")}); };`,
        `  const from${t} = (v: any): ${t} => ({ ${fields(ctors[0], "v")} });`);
    } else {
      out.push(`  const to${t} = (v: ${t}): unknown => { switch (v?.$) { ${ctors.map((c) => `case ${JSON.stringify(c.name)}: return M.${t}.create_${c.name}(${args(c, "v")});`).join(" ")} default: return unknown("${t}", v); } };`,
        `  const from${t} = (v: any): ${t} => ${ctors.map((c) => `v.is_${c.name} ? { $: ${JSON.stringify(c.name)}${c.fields.length ? ", " : ""}${fields(c, "v")} } : `).join("")}bad("${t}");`);
    }
  }
  // Compiled code does not check \`requires\`, so each precondition the laws state is checked here first.
  const call = (f) => `M.__default.${f.name}(${f.params.map((p) => `${p.name}$`).join(", ")})`;
  const body = (f) => {
    const converted = f.params.map((p) => `const ${p.name}$ = ${toCore(p.type, p.name)};`);
    const checks = f.checks.map((c) => `if (!M.__default.${c.predicate}(${c.args.map((a) => `${a}$`).join(", ")})) throw new RangeError("precondition ${c.predicate}(${c.args.join(", ")}) of ${f.name} does not hold");`);
    return `{ ${[...converted, ...checks, `return ${fromCore(f.returns, call(f))};`].join(" ")} }`;
  };
  out.push(`  return {`, ...functions.map((f) => `    ${f.name}: (${f.params.map((p) => `${p.name}: ${tsType(p.type)}`).join(", ")}) => ${body(f)},`), `  };`, `}`,
    `function bad(type: string): never { throw new TypeError(\`compiled core returned an unknown \${type}\`); }`,
    `function unknown(type: string, value: unknown): never { throw new TypeError(\`not a \${type}: \${JSON.stringify(value)}\`); }`, ``,
    `/** The checked-in compiled core, bound. */`,
    `export const core: Core = load(fileURLToPath(new URL("./core.js", import.meta.url)));`, ``);
  return out.join("\n");
}

function generate(block, outDir) {
  const dir = join(CORE, "blocks", block);
  const cfg = JSON.parse(readFileSync(join(dir, "mutate.json"), "utf8"));
  const { interface: laws } = JSON.parse(readFileSync(join(dir, "block.json"), "utf8"));
  const impl = readFileSync(join(CORE, cfg.translate), "utf8");
  const module = /^\s*module\s+(\w+)\s+refines\b/m.exec(impl)?.[1];
  if (!module) throw new UsageError(`${cfg.translate}: no refining module`);
  const doctor = spawnSync("/bin/bash", [join(REPO, "tools/proof/bootstrap.sh"), "doctor"], { encoding: "utf8" });
  if (doctor.status !== 0) throw new UsageError(`pinned toolchain unavailable: ${doctor.stderr.trim()}`);
  // The laws are read first: a declaration the façade cannot carry is refused before anything compiles.
  const signatures = readLaws(laws.map((f) => readFileSync(join(CORE, f), "utf8")).join("\n"));
  const facade = emitFacade(signatures, module, `${laws.join(", ")} and ${cfg.translate}`, `${"../".repeat(block.split("/").length + 1)}package.json`);
  const work = mkdtempSync(join(tmpdir(), "tron-proof-facade-"));
  try {
    try { execFileSync(DAFNY, ["translate", "js", "--no-verify", "--include-runtime", cfg.translate, "-o", join(work, "core")], { cwd: CORE, stdio: "pipe" }); }
    catch (error) { throw new UsageError(`${cfg.translate} does not compile:\n${String(error.stdout ?? "").trim()}`); }
    const compiled = readFileSync(join(work, "core.js"), "utf8");
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, "core.js"), `// GENERATED by tools/proof/dafny2wire/facade.mjs: ${cfg.translate} compiled by the pinned Dafny. Do not edit.\n${compiled}`);
    writeFileSync(join(outDir, "facade.ts"), facade);
  } finally { rmSync(work, { recursive: true, force: true }); }
}

function main(argv) {
  const rootAt = argv.indexOf("--root");
  if (rootAt >= 0) CORE = resolve(argv[rootAt + 1]);
  const block = argv.find((a, i) => !a.startsWith("--") && (rootAt < 0 || i !== rootAt + 1));
  if (!block) throw new UsageError("usage: scripts/tron proof facade <block> [--check] [--root <dir>]");
  const target = join(CORE, "dist", block);
  if (!argv.includes("--check")) { generate(block, target); console.log(`proof facade: wrote ${target}/{core.js,facade.ts}`); return 0; }
  const fresh = mkdtempSync(join(tmpdir(), "tron-proof-facade-check-"));
  try {
    generate(block, fresh);
    const stale = ["core.js", "facade.ts"].filter((f) => !existsSync(join(target, f)) || readFileSync(join(target, f), "utf8") !== readFileSync(join(fresh, f), "utf8"));
    if (stale.length) { console.error(`proof facade: ${stale.join(", ")} in ${target} differ from the sources; run scripts/tron proof facade ${block}`); return 1; }
    console.log(`proof facade: ${target} is fresh`);
    return 0;
  } finally { rmSync(fresh, { recursive: true, force: true }); }
}

try { process.exitCode = main(process.argv.slice(2)); }
catch (error) { if (!(error instanceof UsageError)) throw error; console.error(`proof facade: ${error.message}`); process.exitCode = 2; }
