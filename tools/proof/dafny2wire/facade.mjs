#!/usr/bin/env node
// Purpose: `scripts/tron proof facade <block> [--check]`: the generated core façade of a proof block.
// Writes packages/core/dist/<block>/core.mjs, the block compiled to JavaScript by the pinned Dafny without
// the Dafny runtime (so a core needs no package at run time), and facade.ts, a typed TypeScript wrapper that
// marshals plain values to and from the compiled datatypes, so no hand adapter sits between a shell and a core.
// --check regenerates into a temporary directory and fails if the checked-in files differ.
//
// core.mjs is the compiler's module-only output, unedited, between a generated header and an export line. A
// block may use only what compiles to plain JavaScript (bounded newtypes, booleans, datatypes, reading
// sequences and arrays, loops) plus runtime helpers that are closed functions (integer division and modulo
// on numbers): those are copied verbatim from the runtime the same compiler emits. Anything else that would
// need the runtime (an unbounded int, building a sequence, datatype equality, a tuple) is refused, naming
// the function.
//
// The façade exposes every compiled (non-ghost) function and predicate the block's laws declare, with the
// signatures stated there, and checks each stated precondition (a call of a compiled predicate on parameters)
// before calling, because compiled code does not check `requires`; any other precondition is refused. Types:
// a newtype over a literal integer range within the JavaScript safe integers -> number (checked to be an
// integer in that range, both ways), bool -> boolean, a datatype whose constructors all take no arguments ->
// a string union of their names, a one-constructor datatype named like its type -> a plain object, any other
// datatype -> an object tagged by `$` (the constructor name), seq<T> -> a readonly array of T. Other Dafny
// types (int and nat among them) are refused.
// Exit 0: written or fresh. 1: --check found a difference. 2: usage, unsupported type or toolchain error.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
let CORE = join(REPO, "packages/core");
const DAFNY = join(process.env.XDG_CACHE_HOME || join(homedir(), "Library/Caches"), "tron-proof/bin/dafny");
export class UsageError extends Error {}

function splitTop(s, sep) { const out = []; let depth = 0, cur = ""; for (const ch of s) { if ("(<".includes(ch)) depth++; if (")>".includes(ch)) depth--; if (ch === sep && depth === 0) { out.push(cur); cur = ""; } else cur += ch; } out.push(cur); return out.map((x) => x.trim()).filter(Boolean); }
const param = (p) => { const [name, ...type] = p.split(":"); return { name: name.trim(), type: type.join(":").trim() }; };

// Datatypes, compiled signatures and their preconditions in the block's laws file. Anything the façade
// cannot translate faithfully is refused, never skipped.
export function readLaws(text) {
  const code = text.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, "");
  // Declarations start a line; a declaration runs to the next one (or the module's closing brace).
  const starts = [...code.matchAll(/^[ \t]*((?:(?:ghost|opaque|static|function|predicate|method|lemma|datatype|codatatype|newtype|type|const|import|module|abstract)\b[ \t]*)+)/gm)];
  const datatypes = new Map();
  const newtypes = new Map();
  const functions = [];
  // A literal bound: exact up to 2^53 either way, so an exclusive bound of the widest range is read exactly.
  const literal = (text) => { const digits = text.replace(/_/g, "").replace(/^-\s*/, ""); const n = Number(digits); return /^(0x[0-9a-fA-F]+|[0-9]+)$/.test(digits) && n <= 2 ** 53 ? (text.startsWith("-") ? -n : n) : NaN; };
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
    if (words.includes("newtype")) {
      // A newtype over a literal integer range: the compiler represents it as a JavaScript number.
      const n = /^newtype\s+(\w+)\s*=\s*(\w+)\s*:\s*int\s*\|\s*(-?\s*[\w]+)\s*(<=?)\s*\2\s*(<=?)\s*(-?\s*[\w]+)$/.exec(text.replace(/\s+/g, " "));
      const lo = n ? literal(n[3]) + (n[4] === "<" ? 1 : 0) : NaN;
      const hi = n ? literal(n[6]) - (n[5] === "<" ? 1 : 0) : NaN;
      if (!n || !Number.isSafeInteger(lo) || !Number.isSafeInteger(hi)) throw new UsageError(`cannot read newtype as a literal integer range within the safe integers: ${text.slice(0, 80)}`);
      newtypes.set(n[1], { lo, hi });
      return;
    }
    if (!words.includes("function") && !words.includes("predicate")) return;
    if (words.includes("ghost")) return; // erased: not compiled, so not in the façade
    if (words.includes("method")) throw new UsageError(`'${words.join(" ")}' is not Dafny 4 syntax: ${text.slice(0, 60)}`);
    const f = /^(?:\w+\s+)*(function|predicate)\s+(\w+)\s*(<[^>]*>)?\s*\(([^)]*)\)\s*(?::\s*(\w+(?:<(?:[^<>]|<[^<>]*>)*>)?))?([\s\S]*)$/.exec(text);
    if (!f) throw new UsageError(`cannot read signature: ${text.slice(0, 80)}`);
    if (f[3]) throw new UsageError(`${f[2]}: generic functions are not supported by the façade`);
    const params = splitTop(f[4], ",").map(param);
    // The generated wrapper's own names; a parameter with one of them would shadow it.
    const taken = params.find((p) => ["M", "_dafny", "seq", "BigNumber", "require", "int", "nat", "bool", "num", "natNum", "bad", "unknown"].includes(p.name));
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
  return { datatypes, newtypes, functions };
}

export function emitFacade({ datatypes, newtypes, functions }, module, source) {
  const shape = (name) => {
    const ctors = datatypes.get(name);
    if (!ctors) return null;
    if (ctors.every((c) => c.fields.length === 0)) return "enum";
    if (ctors.length === 1 && ctors[0].name === name) return "record";
    return "union";
  };
  const elem = (t) => /^seq<(.+)>$/.exec(t)?.[1];
  const tsType = (t) => {
    if (elem(t)) return elem(elem(t)) ? `readonly (${tsType(elem(t))})[]` : `readonly ${tsType(elem(t))}[]`;
    if (newtypes.has(t)) return "number";
    if (t === "bool") return "boolean";
    if (shape(t)) return t;
    throw new UsageError(`façade: unsupported Dafny type ${t}`);
  };
  const reserved = [...newtypes.keys()].find((t) => datatypes.has(t) || ["M", "seq", "bool", "bad", "unknown"].includes(`in${t}`));
  if (reserved) throw new UsageError(`façade: newtype name ${reserved} is taken`);
  const toCore = (t, v) => (elem(t) ? `seq(${v}, (x: ${tsType(elem(t))}) => ${toCore(elem(t), "x")})` : newtypes.has(t) ? `in${t}(${v})` : t === "bool" ? `bool(${v})` : `to${t}(${v})`);
  const fromCore = (t, v) => (elem(t) ? `Array.from(${v} as unknown[], (x: any) => ${fromCore(elem(t), "x")})` : newtypes.has(t) ? `in${t}(${v})` : t === "bool" ? v : `from${t}(${v})`);
  // What crosses in each direction (the Gateway compiles with noUnusedLocals, so only converters in use are emitted).
  const used = new Set();
  const numbers = new Set();
  const into = new Set();
  const outOf = new Set();
  const visit = (t, way) => {
    if (elem(t)) { if (way === into) into.add("seq"); return visit(elem(t), way); }
    if (newtypes.has(t)) numbers.add(t);
    if (t === "bool" && way === into) into.add("bool");
    if (shape(t) && !way.has(t)) { way.add(t); used.add(t); for (const c of datatypes.get(t)) for (const f of c.fields) visit(f.type, way); }
  };
  for (const f of functions) { f.params.forEach((p) => { tsType(p.type); visit(p.type, into); }); tsType(f.returns); visit(f.returns, outOf); }
  const taken = functions.flatMap((f) => f.params.map((p) => [f.name, p.name])).find(([, name]) => [...numbers].some((t) => name === `in${t}`));
  if (taken) throw new UsageError(`${taken[0]}: parameter name ${taken[1]} is reserved by the façade`);
  const out = [
    `// GENERATED by tools/proof/dafny2wire/facade.mjs from ${source}. Do not edit.`,
    `// Typed façade over the compiled core ./core.mjs (module ${module}).`,
    `import { compiled } from "./core.mjs";`,
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
    `// Binds the façade to a compiled core: the checked-in ./core.mjs, or another translation of the block.`,
    `export function bind(M: any): Core {`,
  );
  if (into.has("bool")) out.push(`  const bool = (b: boolean): boolean => { if (typeof b !== "boolean") throw new TypeError(\`not a boolean: \${String(b)}\`); return b; };`);
  if (into.has("seq")) out.push(`  const seq = <T>(v: readonly T[], each: (x: T) => unknown): unknown[] => { if (!Array.isArray(v)) throw new TypeError(\`not an array: \${JSON.stringify(v)}\`); return v.map(each); };`);
  // A number crosses unchanged, in either direction, only as an integer of its newtype's range.
  for (const t of [...numbers].sort()) {
    const { lo, hi } = newtypes.get(t);
    out.push(`  const in${t} = (n: number): number => { if (!Number.isSafeInteger(n) || n < ${lo} || n > ${hi}) throw new RangeError(\`not a ${t}: \${n}\`); return n; };`);
  }
  for (const t of [...used].sort()) {
    const ctors = datatypes.get(t);
    const kind = shape(t);
    const args = (c, src) => c.fields.map((f) => toCore(f.type, `${src}.${f.name}`)).join(", ");
    const fields = (c, src) => c.fields.map((f) => `${f.name}: ${fromCore(f.type, `${src}.dtor_${f.name}`)}`).join(", ");
    if (kind === "enum") {
      if (into.has(t)) out.push(`  const to${t} = (v: ${t}): unknown => { switch (v) { ${ctors.map((c) => `case ${JSON.stringify(c.name)}: return M.${t}.create_${c.name}();`).join(" ")} default: return unknown("${t}", v); } };`);
      if (outOf.has(t)) out.push(`  const from${t} = (v: any): ${t} => ${ctors.map((c) => `v.is_${c.name} ? ${JSON.stringify(c.name)} : `).join("")}bad("${t}");`);
    } else if (kind === "record") {
      if (into.has(t)) out.push(`  const to${t} = (v: ${t}): unknown => { if (typeof v !== "object" || v === null) return unknown("${t}", v); return M.${t}.create_${ctors[0].name}(${args(ctors[0], "v")}); };`);
      if (outOf.has(t)) out.push(`  const from${t} = (v: any): ${t} => ({ ${fields(ctors[0], "v")} });`);
    } else {
      if (into.has(t)) out.push(`  const to${t} = (v: ${t}): unknown => { switch (v?.$) { ${ctors.map((c) => `case ${JSON.stringify(c.name)}: return M.${t}.create_${c.name}(${args(c, "v")});`).join(" ")} default: return unknown("${t}", v); } };`);
      if (outOf.has(t)) out.push(`  const from${t} = (v: any): ${t} => ${ctors.map((c) => `v.is_${c.name} ? { $: ${JSON.stringify(c.name)}${c.fields.length ? ", " : ""}${fields(c, "v")} } : `).join("")}bad("${t}");`);
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
    ...([...outOf].some((t) => shape(t)) ? [`function bad(type: string): never { throw new TypeError(\`compiled core returned an unknown \${type}\`); }`] : []),
    ...([...into].some((t) => shape(t)) ? [`function unknown(type: string, value: unknown): never { throw new TypeError(\`not a \${type}: \${JSON.stringify(value)}\`); }`] : []), ``,
    `/** The checked-in compiled core, bound. */`,
    `export const core: Core = bind(compiled);`, ``);
  return out.join("\n");
}

// The façade of a block that still runs on the Dafny runtime (BigNumber integers, runtime sequences). Such a
// block is shadow-only: a shell cannot ship it, because the runtime needs the bignumber.js package. It goes when
// the last block names its shell (#2393).
function emitRuntimeFacade({ datatypes, functions }, module, source, packageJson) {
  const shape = (name) => {
    const ctors = datatypes.get(name);
    if (!ctors) return null;
    if (ctors.every((c) => c.fields.length === 0)) return "enum";
    if (ctors.length === 1 && ctors[0].name === name) return "record";
    return "union";
  };
  const elem = (t) => /^seq<(.+)>$/.exec(t)?.[1];
  const tsType = (t) => {
    if (elem(t)) return elem(elem(t)) ? `readonly (${tsType(elem(t))})[]` : `readonly ${tsType(elem(t))}[]`;
    if (t === "int" || t === "nat") return "number";
    if (t === "bool") return "boolean";
    if (shape(t)) return t;
    throw new UsageError(`façade: unsupported Dafny type ${t}`);
  };
  const toCore = (t, v) => (elem(t) ? `seq(${v}, (x: ${tsType(elem(t))}) => ${toCore(elem(t), "x")})` : t === "int" ? `int(${v})` : t === "nat" ? `nat(${v})` : t === "bool" ? `bool(${v})` : `to${t}(${v})`);
  const fromCore = (t, v) => (elem(t) ? `Array.from(${v} as unknown[], (x: any) => ${fromCore(elem(t), "x")})` : t === "int" ? `num(${v})` : t === "nat" ? `natNum(${v})` : t === "bool" ? v : `from${t}(${v})`);
  const used = new Set();
  const visit = (t) => { if (elem(t)) return visit(elem(t)); if (shape(t) && !used.has(t)) { used.add(t); for (const c of datatypes.get(t)) for (const f of c.fields) visit(f.type); } };
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
    `  // The compiled file is a script that declares its modules; evaluate it and take ${module}, its runtime and BigNumber.`,
    `  const { M, _dafny, BigNumber } = new Function("require", readFileSync(corePath, "utf8") + "\\nreturn { M: ${module}, _dafny, BigNumber };")(require);`,
    `  const int = (n: number): unknown => { if (!Number.isSafeInteger(n)) throw new RangeError(\`not a safe integer: \${n}\`); return new BigNumber(n); };`,
    `  const nat = (n: number): unknown => { if (!Number.isSafeInteger(n) || n < 0) throw new RangeError(\`not a natural number: \${n}\`); return new BigNumber(n); };`,
    `  const bool = (b: boolean): boolean => { if (typeof b !== "boolean") throw new TypeError(\`not a boolean: \${String(b)}\`); return b; };`,
    `  const num = (b: { isInteger(): boolean; toNumber(): number }): number => { const n = b.toNumber(); if (!b.isInteger() || !Number.isSafeInteger(n)) throw new RangeError("core returned an integer outside the safe range"); return n; };`,
    `  const seq = <T>(v: readonly T[], each: (x: T) => unknown): unknown => { if (!Array.isArray(v)) throw new TypeError(\`not an array: \${JSON.stringify(v)}\`); return _dafny.Seq.of(...v.map(each)); };`,
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

// Members the compiler emits for every datatype and newtype that only the Dafny runtime would call.
const RUNTIME_ONLY_MEMBERS = new Set(["toString", "equals", "_Is", "IntegerRange"]);

// The block at `translate` (relative to `root`) compiled to a JavaScript module that needs no Dafny runtime:
// the compiler's module-only output between a header and `export { <module> as compiled }`. Refuses a block
// whose compiled functions would call into the runtime, apart from helpers that are closed functions there.
export function compileCore(root, translate, env = process.env) {
  const module = /^\s*module\s+(\w+)\s+refines\b/m.exec(readFileSync(join(root, translate), "utf8"))?.[1];
  if (!module) throw new UsageError(`${translate}: no refining module`);
  const work = mkdtempSync(join(tmpdir(), "tron-proof-core-"));
  const run = (flags, name) => {
    try { execFileSync(DAFNY, ["translate", "js", "--no-verify", ...flags, translate, "-o", join(work, name)], { cwd: root, env, stdio: "pipe" }); }
    catch (error) { throw new UsageError(`${translate} does not compile:\n${String(error.stdout ?? "").trim()}`); }
    return readFileSync(join(work, `${name}.js`), "utf8");
  };
  try {
    const compiled = run([], "core");
    if (!compiled.includes(`\nlet ${module} = (function() {\n`)) throw new UsageError(`${translate}: the compiler did not emit module ${module}`);
    // Each use of the runtime outside the members only the runtime calls: a helper call, or anything else.
    const needs = (member, i, line) => new UsageError(`${translate}: ${member ?? "the module"} needs the Dafny runtime (compiled line ${i + 1}: ${line.trim().slice(0, 120)}); a core may use only bounded newtypes, booleans, datatypes, sequence and array reads and loops`);
    const helpers = new Map();
    let member = null;
    compiled.split("\n").forEach((line, i) => {
      const header = /^ {4}(?:static )?(?:get )?\*?([\w$]+) ?\(.*\) \{$/.exec(line);
      if (header) member = header[1];
      else if (/^ {0,2}\S/.test(line)) member = null;
      if (member !== null && RUNTIME_ONLY_MEMBERS.has(member)) return;
      const rest = line.replace(/\b_dafny\.([\w$]+)\(/g, (_, name) => { if (!helpers.has(name)) helpers.set(name, needs(member, i, line)); return "("; });
      if (/\b(_dafny|BigNumber)\b/.test(rest)) throw needs(member, i, line);
    });
    let header = "";
    if (helpers.size) {
      // The runtime the same compiler emits; a helper is copied only if it is a function that stands alone.
      const full = run(["--include-runtime"], "full");
      const sources = [...helpers.keys()].sort().map((name) => {
        const start = full.indexOf(`\n  $module.${name} = function(`);
        const end = start < 0 ? -1 : full.indexOf("\n  }\n", start);
        const source = end < 0 ? "" : full.slice(start + `\n  $module.${name} = `.length, end + "\n  }".length);
        let closed = source !== "" && !/\b(_dafny|BigNumber|this)\b|\$module/.test(source);
        if (closed) { try { closed = typeof new Function(`"use strict"; return (${source});`)() === "function"; } catch { closed = false; } }
        if (!closed) throw helpers.get(name);
        return `  ${name}: ${source},`;
      });
      header = `// Runtime helpers this block calls, copied verbatim from the pinned Dafny's JavaScript runtime.\nconst _dafny = Object.freeze({\n${sources.join("\n")}\n});\n`;
    }
    return `// GENERATED by tools/proof/dafny2wire/facade.mjs: ${translate} compiled by the pinned Dafny, without the Dafny runtime. Do not edit.\n${header}${compiled}export { ${module} as compiled };\n`;
  } finally { rmSync(work, { recursive: true, force: true }); }
}

// Where a block's generated files go: its shell's directory (block.json "shell", relative to the repository
// that holds the core root at packages/core) for a block a shell runs, else <core root>/dist/<block> for a
// shadow-only block.
function target(block) {
  const { shell } = JSON.parse(readFileSync(join(CORE, "blocks", block, "block.json"), "utf8"));
  return shell === undefined ? { dir: join(CORE, "dist", block), files: ["core.js", "facade.ts"] } : { dir: resolve(CORE, "../..", shell), files: ["core.mjs", "facade.ts"] };
}

function generate(block, outDir) {
  const dir = join(CORE, "blocks", block);
  const cfg = JSON.parse(readFileSync(join(dir, "mutate.json"), "utf8"));
  const { interface: laws, shell } = JSON.parse(readFileSync(join(dir, "block.json"), "utf8"));
  const impl = readFileSync(join(CORE, cfg.translate), "utf8");
  const module = /^\s*module\s+(\w+)\s+refines\b/m.exec(impl)?.[1];
  if (!module) throw new UsageError(`${cfg.translate}: no refining module`);
  const doctor = spawnSync("/bin/bash", [join(REPO, "tools/proof/bootstrap.sh"), "doctor"], { encoding: "utf8" });
  if (doctor.status !== 0) throw new UsageError(`pinned toolchain unavailable: ${doctor.stderr.trim()}`);
  // The laws are read first: a declaration the façade cannot carry is refused before anything compiles.
  const signatures = readLaws(laws.map((f) => readFileSync(join(CORE, f), "utf8")).join("\n"));
  const source = `${laws.join(", ")} and ${cfg.translate}`;
  if (shell !== undefined) {
    // Both files are made before either is written: a refused block leaves nothing behind.
    const facade = emitFacade(signatures, module, source);
    const core = compileCore(CORE, cfg.translate);
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, "core.mjs"), core);
    writeFileSync(join(outDir, "facade.ts"), facade);
    return;
  }
  const facade = emitRuntimeFacade(signatures, module, source, `${"../".repeat(block.split("/").length + 1)}package.json`);
  const work = mkdtempSync(join(tmpdir(), "tron-proof-facade-"));
  try {
    try { execFileSync(DAFNY, ["translate", "js", "--no-verify", "--include-runtime", cfg.translate, "-o", join(work, "core")], { cwd: CORE, stdio: "pipe" }); }
    catch (error) { throw new UsageError(`${cfg.translate} does not compile:\n${String(error.stdout ?? "").trim()}`); }
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, "core.js"), `// GENERATED by tools/proof/dafny2wire/facade.mjs: ${cfg.translate} compiled by the pinned Dafny. Do not edit.\n${readFileSync(join(work, "core.js"), "utf8")}`);
    writeFileSync(join(outDir, "facade.ts"), facade);
  } finally { rmSync(work, { recursive: true, force: true }); }
}

function main(argv) {
  const rootAt = argv.indexOf("--root");
  if (rootAt >= 0) CORE = resolve(argv[rootAt + 1]);
  const block = argv.find((a, i) => !a.startsWith("--") && (rootAt < 0 || i !== rootAt + 1));
  if (!block) throw new UsageError("usage: scripts/tron proof facade <block> [--check] [--root <dir>]");
  const { dir, files } = target(block);
  if (!argv.includes("--check")) { generate(block, dir); console.log(`proof facade: wrote ${dir}/{${files.join(",")}}`); return 0; }
  const fresh = mkdtempSync(join(tmpdir(), "tron-proof-facade-check-"));
  try {
    generate(block, fresh);
    const stale = files.filter((f) => !existsSync(join(dir, f)) || readFileSync(join(dir, f), "utf8") !== readFileSync(join(fresh, f), "utf8"));
    if (stale.length) { console.error(`proof facade: ${stale.join(", ")} in ${dir} differ from the sources; run scripts/tron proof facade ${block}`); return 1; }
    console.log(`proof facade: ${dir} is fresh`);
    return 0;
  } finally { rmSync(fresh, { recursive: true, force: true }); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { if (!(error instanceof UsageError)) throw error; console.error(`proof facade: ${error.message}`); process.exitCode = 2; }
}
