#!/usr/bin/env node
// Purpose: `scripts/tron proof facade <block> [--check]`: the generated core façade of a proof block.
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

export function readLaws(text) {
  const code = text.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, "");
  const starts = [...code.matchAll(/^[ \t]*((?:(?:ghost|opaque|static|function|predicate|method|lemma|datatype|codatatype|newtype|type|const|import|module|abstract)\b[ \t]*)+)/gm)];
  const datatypes = new Map();
  const newtypes = new Map();
  const lists = new Map();
  const functions = [];
  const literal = (text) => { const digits = text.replace(/_/g, "").replace(/^-\s*/, ""); const n = Number(digits); return /^(0x[0-9a-fA-F]+|[0-9]+)$/.test(digits) && n <= 2 ** 53 ? (text.startsWith("-") ? -n : n) : NaN; };
  starts.forEach((m, i) => {
    const words = m[1].trim().split(/\s+/);
    const text = code.slice(m.index, i + 1 < starts.length ? starts[i + 1].index : code.length).replace(/\}\s*$/, "").trim();
    if (words.includes("datatype") || words.includes("codatatype")) {
      const d = /^(?:co)?datatype\s+(\w+)\s*(<[^>]*>)?\s*=\s*([\s\S]+)$/.exec(text);
      if (!d) throw new UsageError(`cannot read datatype: ${text.slice(0, 80)}`);
      const ctors = splitTop(d[3].replace(/\s+/g, " ").trim().replace(/^\|/, ""), "|").map((c) => {
        const p = c.indexOf("(");
        return { name: (p < 0 ? c : c.slice(0, p)).trim().replace(/^ghost\s+/, ""), fields: p < 0 ? [] : splitTop(c.slice(p + 1, c.lastIndexOf(")")), ",").map(param) };
      });
      if (d[2]) {
        const t = /^<\s*(\w+)\s*>$/.exec(d[2])?.[1];
        const [nil, cons] = ctors;
        if (t && ctors.length === 2 && nil.fields.length === 0 && cons.fields.length === 2 && cons.fields[0].type === t
          && cons.fields[1].type.replace(/\s+/g, "") === `${d[1]}<${t}>`) lists.set(d[1], { nil: nil.name, cons: cons.name, head: cons.fields[0].name, tail: cons.fields[1].name });
        return;
      }
      datatypes.set(d[1], ctors);
      return;
    }
    if (words.includes("newtype")) {
      const n = /^newtype\s+(\w+)\s*=\s*(\w+)\s*:\s*int\s*\|\s*(-?\s*[\w]+)\s*(<=?)\s*\2\s*(<=?)\s*(-?\s*[\w]+)$/.exec(text.replace(/\s+/g, " "));
      const lo = n ? literal(n[3]) + (n[4] === "<" ? 1 : 0) : NaN;
      const hi = n ? literal(n[6]) - (n[5] === "<" ? 1 : 0) : NaN;
      if (!n || !Number.isSafeInteger(lo) || !Number.isSafeInteger(hi)) throw new UsageError(`cannot read newtype as a literal integer range within the safe integers: ${text.slice(0, 80)}`);
      newtypes.set(n[1], { lo, hi });
      return;
    }
    if (words.includes("method") && !words.includes("function") && !words.includes("lemma")) {
      if (words.includes("ghost")) return;
      const m = /^method\s+(\w+)\s*\(([^)]*)\)\s*returns\s*\(\s*\w+\s*:\s*([^)]+?)\s*\)([\s\S]*)$/.exec(text);
      if (!m) throw new UsageError(`cannot read method signature: ${text.slice(0, 80)}`);
      const all = splitTop(m[2], ",").map(param);
      const arrays = all.filter((p) => /^array<.+>$/.test(p.type));
      const params = all.filter((p) => !arrays.includes(p));
      const requires = [...m[4].split("{")[0].matchAll(/\brequires\b([\s\S]*?)(?=\brequires\b|\bensures\b|\bdecreases\b|\bmodifies\b|\breads\b|$)/g)].map((r) => r[1].trim());
      const sized = new Map(), bounds = [], checks = [];
      for (const clause of requires.flatMap((r) => r.split("&&")).map((c) => c.trim()).filter(Boolean)) {
        const length = /^(\w+)\.Length\s*==\s*\|(\w+)\|$/.exec(clause);
        const bound = /^\|(\w+)\|\s*<\s*([\w]+)$/.exec(clause);
        const call = /^(\w+)\(([^()]*)\)$/.exec(clause);
        const isSeq = (name) => params.some((p) => p.name === name && /^seq<.+>$/.test(p.type));
        if (length && arrays.some((a) => a.name === length[1]) && isSeq(length[2]) && !sized.has(length[1])) sized.set(length[1], length[2]);
        else if (bound && isSeq(bound[1]) && Number.isSafeInteger(literal(bound[2]))) bounds.push({ seq: bound[1], limit: literal(bound[2]) });
        else if (call) checks.push({ predicate: call[1], args: splitTop(call[2], ",") });
        else throw new UsageError(`${m[1]}: precondition '${clause}' cannot be checked by the façade`);
      }
      const unsized = arrays.find((a) => !sized.has(a.name));
      if (unsized) throw new UsageError(`${m[1]}: array ${unsized.name} needs a precondition ${unsized.name}.Length == |<a sequence parameter>|`);
      functions.push({ name: m[1], params, returns: m[3], checks, method: { order: all.map((p) => p.name), sized, bounds } });
      return;
    }
    if (!words.includes("function") && !words.includes("predicate")) return;
    if (words.includes("ghost")) return;
    if (words.includes("method")) throw new UsageError(`'${words.join(" ")}' is not Dafny 4 syntax: ${text.slice(0, 60)}`);
    const f = /^(?:\w+\s+)*(function|predicate)\s+(\w+)\s*(<[^>]*>)?\s*\(([^)]*)\)\s*(?::\s*(\w+(?:<(?:[^<>]|<[^<>]*>)*>)?))?([\s\S]*)$/.exec(text);
    if (!f) throw new UsageError(`cannot read signature: ${text.slice(0, 80)}`);
    if (f[3]) throw new UsageError(`${f[2]}: generic functions are not supported by the façade`);
    const params = splitTop(f[4], ",").map(param);
    const taken = params.find((p) => ["M", "_dafny", "seq", "BigNumber", "require", "int", "nat", "bool", "num", "natNum", "bad", "unknown"].includes(p.name));
    if (taken) throw new UsageError(`${f[2]}: parameter name ${taken.name} is reserved by the façade`);
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
  return { datatypes, newtypes, lists, functions };
}

export function emitFacade({ datatypes, newtypes, lists, functions }, module, source) {
  const shape = (name) => {
    const ctors = datatypes.get(name);
    if (!ctors) return null;
    if (ctors.every((c) => c.fields.length === 0)) return "enum";
    if (ctors.length === 1 && ctors[0].name === name) return "record";
    return "union";
  };
  const elem = (t) => /^seq<(.+)>$/.exec(t)?.[1];
  const list = (t) => { const m = /^(\w+)<(.+)>$/.exec(t); return m && lists.has(m[1]) ? [m[1], m[2]] : null; };
  const item = (t) => elem(t) ?? list(t)?.[1];
  const tsType = (t) => {
    if (item(t)) return item(item(t)) ? `readonly (${tsType(item(t))})[]` : `readonly ${tsType(item(t))}[]`;
    if (newtypes.has(t)) return "number";
    if (t === "bool") return "boolean";
    if (shape(t)) return t;
    throw new UsageError(`façade: unsupported Dafny type ${t}`);
  };
  const toCore = (t, v) => (elem(t) ? `seq(${v}, (x: ${tsType(elem(t))}) => ${toCore(elem(t), "x")})`
    : list(t) ? `to${list(t)[0]}(${v}, (x: ${tsType(list(t)[1])}) => ${toCore(list(t)[1], "x")})`
    : newtypes.has(t) ? `in${t}(${v})` : t === "bool" ? `bool(${v})` : `to${t}(${v})`);
  const fromCore = (t, v) => (elem(t) ? `Array.from(${v} as unknown[], (x: any) => ${fromCore(elem(t), "x")})`
    : list(t) ? `from${list(t)[0]}(${v}, (x: any) => ${fromCore(list(t)[1], "x")})`
    : newtypes.has(t) ? `in${t}(${v})` : t === "bool" ? v : `from${t}(${v})`);
  const used = new Set();
  const numbers = new Set();
  const into = new Set();
  const outOf = new Set();
  const listsIn = new Set();
  const listsOut = new Set();
  const visit = (t, way) => {
    if (elem(t)) { if (way === into) into.add("seq"); return visit(elem(t), way); }
    if (list(t)) { (way === into ? listsIn : listsOut).add(list(t)[0]); return visit(list(t)[1], way); }
    if (newtypes.has(t)) numbers.add(t);
    if (t === "bool" && way === into) into.add("bool");
    if (shape(t) && !way.has(t)) { way.add(t); used.add(t); for (const c of datatypes.get(t)) for (const f of c.fields) visit(f.type, way); }
  };
  for (const f of functions) { f.params.forEach((p) => { tsType(p.type); visit(p.type, into); }); tsType(f.returns); visit(f.returns, outOf); }
  const own = new Set(["M", "seq", "bool", ...[...numbers].map((t) => `in${t}`), ...[...used, ...lists.keys()].flatMap((t) => [`to${t}`, `from${t}`, `the${t}`])]);
  const taken = functions.flatMap((f) => f.params.map((p) => [f.name, p.name])).find(([, name]) => own.has(name));
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
  for (const t of [...numbers].sort()) {
    const { lo, hi } = newtypes.get(t);
    out.push(`  const in${t} = (n: number): number => { if (!Number.isSafeInteger(n) || n < ${lo} || n > ${hi}) throw new RangeError(\`not a ${t}: \${n}\`); return n; };`);
  }
  for (const t of [...lists.keys()].sort()) {
    const { nil, cons, head, tail } = lists.get(t);
    if (listsIn.has(t)) out.push(`  const to${t} = <T>(v: readonly T[], each: (x: T) => unknown): unknown => { if (!Array.isArray(v)) throw new TypeError(\`not an array: \${JSON.stringify(v)}\`); let list = M.${t}.create_${nil}(); for (let i = v.length - 1; i >= 0; i--) list = M.${t}.create_${cons}(each(v[i] as T), list); return list; };`);
    if (listsOut.has(t)) out.push(`  const from${t} = <T>(v: any, each: (x: any) => T): T[] => { const items: T[] = []; let rest = v; while (rest.is_${cons}) { items.push(each(rest.dtor_${head})); rest = rest.dtor_${tail}; } return rest.is_${nil} ? items : bad("${t}"); };`);
  }
  for (const t of [...used].sort()) {
    const ctors = datatypes.get(t);
    const kind = shape(t);
    const args = (c, src) => c.fields.map((f) => toCore(f.type, `${src}.${f.name}`)).join(", ");
    const fields = (c, src) => c.fields.map((f) => `${f.name}: ${fromCore(f.type, `${src}.dtor_${f.name}`)}`).join(", ");
    const shared = ctors.filter((c) => c.fields.length === 0);
    if (into.has(t) && shared.length) out.push(`  const the${t}: Record<string, unknown> = Object.assign(Object.create(null), { ${shared.map((c) => `${c.name}: M.${t}.create_${c.name}()`).join(", ")} });`);
    if (kind === "enum") {
      if (into.has(t)) out.push(`  const to${t} = (v: ${t}): unknown => the${t}[v] ?? unknown("${t}", v);`);
      if (outOf.has(t)) out.push(`  const from${t} = (v: any): ${t} => ${ctors.map((c) => `v.is_${c.name} ? ${JSON.stringify(c.name)} : `).join("")}bad("${t}");`);
    } else if (kind === "record") {
      if (into.has(t)) out.push(`  const to${t} = (v: ${t}): unknown => { if (typeof v !== "object" || v === null) return unknown("${t}", v); return M.${t}.create_${ctors[0].name}(${args(ctors[0], "v")}); };`);
      if (outOf.has(t)) out.push(`  const from${t} = (v: any): ${t} => ({ ${fields(ctors[0], "v")} });`);
    } else {
      if (into.has(t)) out.push(`  const to${t} = (v: ${t}): unknown => { switch (v?.$) { ${ctors.map((c) => `case ${JSON.stringify(c.name)}: return ${c.fields.length ? `M.${t}.create_${c.name}(${args(c, "v")})` : `the${t}.${c.name}`};`).join(" ")} default: return unknown("${t}", v); } };`);
      if (outOf.has(t)) out.push(`  const from${t} = (v: any): ${t} => ${ctors.map((c) => `v.is_${c.name} ? { $: ${JSON.stringify(c.name)}${c.fields.length ? ", " : ""}${fields(c, "v")} } : `).join("")}bad("${t}");`);
    }
  }
  const call = (f) => `M.__default.${f.name}(${(f.method?.order ?? f.params.map((p) => p.name)).map((name) => `${name}$`).join(", ")})`;
  const body = (f) => {
    const converted = f.params.map((p) => `const ${p.name}$ = ${toCore(p.type, p.name)};`);
    const checks = f.checks.map((c) => `if (!M.__default.${c.predicate}(${c.args.map((a) => `${a}$`).join(", ")})) throw new RangeError("precondition ${c.predicate}(${c.args.join(", ")}) of ${f.name} does not hold");`);
    const bounds = (f.method?.bounds ?? []).map((b) => `if (!(${b.seq}$.length < ${b.limit})) throw new RangeError("precondition |${b.seq}| < ${b.limit} of ${f.name} does not hold");`);
    const arrays = [...(f.method?.sized ?? [])].map(([array, of]) => `const ${array}$ = new Array(${of}$.length);`);
    return `{ ${[...converted, ...checks, ...bounds, ...arrays, `return ${fromCore(f.returns, call(f))};`].join(" ")} }`;
  };
  out.push(`  return {`, ...functions.map((f) => `    ${f.name}: (${f.params.map((p) => `${p.name}: ${tsType(p.type)}`).join(", ")}) => ${body(f)},`), `  };`, `}`,
    ...([...outOf].some((t) => shape(t)) || listsOut.size ? [`function bad(type: string): never { throw new TypeError(\`compiled core returned an unknown \${type}\`); }`] : []),
    ...([...into].some((t) => shape(t)) ? [`function unknown(type: string, value: unknown): never { throw new TypeError(\`not a \${type}: \${JSON.stringify(value)}\`); }`] : []), ``,
    `/** The checked-in compiled core, bound. */`,
    `export const core: Core = bind(compiled);`, ``);
  return out.join("\n");
}

const runtimeOnly = (owner, name, isStatic, isGenerator) => owner !== "__default"
  && (isStatic ? (name === "_Is" && !isGenerator) || (name === "IntegerRange" && isGenerator) : !isGenerator && (name === "toString" || name === "equals"));

export function closedHelper(source) {
  let helper;
  try { helper = new Function(`"use strict"; return (${source});`)(); } catch { return false; }
  if (typeof helper !== "function") return false;
  const code = source.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
  if (/["'`]/.test(code)) return false;
  const known = new Set(["function", "return", "if", "else", "let", "const", "Math", ...(/^function\s*\(([^)]*)\)/.exec(code)?.[1].split(",").map((name) => name.trim()) ?? []),
    ...[...code.matchAll(/\b(?:let|const)\s+([A-Za-z_$][\w$]*)/g)].map((m) => m[1])]);
  return [...code.matchAll(/(\.\s*)?\b([A-Za-z_$][\w$]*)/g)].every((m) => m[1] !== undefined || known.has(m[2]));
}

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
    const needs = (member, i, line) => new UsageError(`${translate}: ${member ?? "the module"} needs the Dafny runtime (compiled line ${i + 1}: ${line.trim().slice(0, 120)}); a core may use only bounded newtypes, booleans, datatypes, sequence and array reads and loops`);
    const helpers = new Map();
    let owner = null, member = null, exempt = false;
    compiled.split("\n").forEach((line, i) => {
      const cls = /^ {2}\$module\.([\w$]+) = class /.exec(line);
      const header = /^ {4}(static )?(?:get )?(\*)?([\w$]+) ?\(.*\) \{$/.exec(line);
      if (cls) { owner = cls[1]; member = null; exempt = false; }
      else if (header) { member = header[3]; exempt = runtimeOnly(owner, member, header[1] !== undefined, header[2] !== undefined); }
      else if (/^ {0,2}\S/.test(line)) { member = null; exempt = false; }
      if (exempt) return;
      const rest = line.replace(/\b_dafny\.([\w$]+)\(/g, (_, name) => { if (!helpers.has(name)) helpers.set(name, needs(member, i, line)); return "("; });
      if (/\b(_dafny|BigNumber)\b/.test(rest)) throw needs(member, i, line);
    });
    let header = "";
    if (helpers.size) {
      const full = run(["--include-runtime"], "full");
      const sources = [...helpers.keys()].sort().map((name) => {
        const start = full.indexOf(`\n  $module.${name} = function(`);
        const end = start < 0 ? -1 : full.indexOf("\n  }\n", start);
        const source = end < 0 ? "" : full.slice(start + `\n  $module.${name} = `.length, end + "\n  }".length);
        if (!closedHelper(source)) throw helpers.get(name);
        return `  ${name}: ${source},`;
      });
      header = `// Runtime helpers this block calls, copied verbatim from the pinned Dafny's JavaScript runtime.\nconst _dafny = Object.freeze({\n${sources.join("\n")}\n});\n`;
    }
    return `// GENERATED by tools/proof/dafny2wire/facade.mjs: ${translate} compiled by the pinned Dafny, without the Dafny runtime. Do not edit.\n`
      + `// Nothing here or in the façade calls the members the compiler emits for that runtime's own use (a datatype's toString\n`
      + `// and equals, a newtype's _Is and IntegerRange); those that name the runtime would throw a ReferenceError.\n`
      + `${header}${compiled}export { ${module} as compiled };\n`;
  } finally { rmSync(work, { recursive: true, force: true }); }
}

function target(block) {
  const { shell } = JSON.parse(readFileSync(join(CORE, "blocks", block, "block.json"), "utf8"));
  if (shell === undefined) throw new UsageError(`${block}: block.json names no shell`);
  return { dir: resolve(CORE, "../..", shell), files: ["core.mjs", "facade.ts"] };
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
  const signatures = readLaws(laws.map((f) => readFileSync(join(CORE, f), "utf8")).join("\n"));
  const source = `${laws.join(", ")} and ${cfg.translate}`;
  const facade = emitFacade(signatures, module, source);
  const core = compileCore(CORE, cfg.translate);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, "core.mjs"), core);
  writeFileSync(join(outDir, "facade.ts"), facade);
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
