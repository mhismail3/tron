#!/usr/bin/env node
// Purpose: `scripts/tron proof wire --inventory`: classify every export of the Gateway protocol types
// (packages/gateway/src/protocol/types.ts) as expressible by the generated wire format (a dafny2wire schema
// with a canonical JSON codec, no hand code) or not, with a reason.
//
// Resolution is the pinned TypeScript compiler's, not a re-implementation: each type is written as
// `x<T>()` with `x<T>(): T extends unknown ? { [K in keyof T]: T[K] } : never` into a probe file, and the
// declaration emit of the pinned packages/gateway tsc prints its structure with intersections, extends,
// Omit/Pick/Extract/Partial/Record and indexed access already applied. Field types the emit leaves as
// utility expressions are probed again until only primitives, literals, arrays, object literals and
// references to named declarations remain. The classifier reads that output only.
//
// Usage: scripts/tron proof wire --inventory [--json] [--numbers float64|integer]
//   --numbers float64 (default): `number` is a JSON float64 (today's wire); integer: `number` is not
//   expressible because nothing in types.ts bounds it to integers.
// Exit 0 with the inventory; 2 on usage or compiler error.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const TYPES = join(REPO, "packages/gateway/src/protocol/types.ts");
const TSC = join(REPO, "packages/gateway/node_modules/.bin/tsc");

// ---------------------------------------------------------------- compiler probe
// Expands each expression one level with the pinned compiler; returns the emitted type text per expression.
function probe(expressions, wrapped = new Set()) {
  return compile((lines) => expressions.forEach((e, i) => lines.push(`export const v${i} = ${wrapped.has(e) ? "y" : "x"}<${e}>();`)), (text, out, dir) => {
    // import("…") specifiers in the emit are relative to the emitted file, which mirrors its source under
    // out/ (rootDir "/"); map them back to absolute source paths.
    text = text.replace(/import\("(\.[^"]*)"\)/g, (_, spec) => `import(${JSON.stringify(resolve(dirname(out), spec).slice(join(dir, "out").length) || "/")})`);
    const result = [];
    for (let i = 0; i < expressions.length; i++) {
      // A literal type is emitted as an initializer (`= "x"`), any other type as an annotation.
      const hit = [...text.matchAll(/export declare const v(\d+)(: | = )/g)].find((m) => Number(m[1]) === i);
      if (!hit) throw new Error(`no emitted type for ${expressions[i]}`);
      const from = hit.index + hit[0].length;
      result.push(text.slice(from, endOfType(text, from)));
    }
    return result;
  });
}

// The parser's fidelity check: every expansion, printed back from the parsed form, must be exactly the type
// the compiler started from (mutual assignability with no difference in optionality or literals).
// Returns the expressions whose printed form the compiler does not accept as equal.
function verifyPrinted(entries) {
  const lines = [];
  return compile((body) => {
    body.push("type Eq<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;");
    // Both sides normalised one level, as the expansion was, so an intersection equals its flattened form.
    body.push("type N<T> = T extends unknown ? { [K in keyof T]: T[K] } : never;");
    const first = body.length + 1;
    entries.forEach(([expr, printed], i) => { lines[i] = first + i; body.push(`export const e${i}: Eq<N<${printed}>, N<${expr}>> = true;`); });
  }, () => [], (diagnostics) => {
    const bad = new Set();
    for (const m of diagnostics.matchAll(/probe\.ts\((\d+),\d+\): error TS/g)) { const i = lines.indexOf(Number(m[1])); bad.add(i >= 0 ? entries[i][0] : `line ${m[1]}`); }
    return [...bad];
  });
}

function compile(write, read, onDiagnostics) {
  const dir = mkdtempSync(join(tmpdir(), "tron-wire-inventory-"));
  try {
    // A copy of types.ts in which every declaration is exported (so the emit can name internal ones, which
    // become named wire types like any other) and relative imports point at the real files.
    const copy = readFileSync(TYPES, "utf8")
      .replace(/^(interface|type) /gm, "export $1 ")
      .replace(/from "(\.\.?\/[^"]+)"/g, (_, spec) => `from ${JSON.stringify(resolve(dirname(TYPES), spec))}`);
    writeFileSync(join(dir, "types.ts"), copy);
    const lines = [
      'import type * as P from "./types.js";',
      "declare function x<T>(): T extends unknown ? { [K in keyof T]: T[K] } : never;",
      // The emit keeps an alias of a union of scalars by name; wrapping each member in a tuple prints them.
      "declare function y<T>(): T extends unknown ? [T] : never;",
    ];
    write(lines);
    writeFileSync(join(dir, "probe.ts"), `${lines.join("\n")}\n`);
    writeFileSync(join(dir, "package.json"), '{"type": "module"}\n');
    // The Gateway's own strictness options, so optional and indexed types read as they do in the Gateway.
    writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        target: "ES2023", module: "NodeNext", moduleResolution: "NodeNext", lib: ["ES2023"], strict: true,
        noUncheckedIndexedAccess: true, exactOptionalPropertyTypes: true,
        skipLibCheck: true, declaration: true, emitDeclarationOnly: true, noErrorTruncation: true,
        types: [], rootDir: "/", outDir: join(dir, "out"),
      },
      files: [join(dir, "probe.ts"), join(dir, "types.ts")],
    }));
    // Declaration emit still writes the file when a type uses a declaration types.ts does not export
    // (TS4023); the copy exports everything, so that is not expected either.
    let diagnostics = "";
    try { execFileSync(TSC, ["-p", dir], { encoding: "utf8", stdio: "pipe" }); }
    catch (error) { diagnostics = `${error.stdout}${error.stderr}`; }
    if (onDiagnostics) return onDiagnostics(diagnostics);
    const out = findFile(join(dir, "out"), "probe.d.ts");
    const unexpected = diagnostics.split("\n").filter((line) => /error TS/.test(line));
    if (!out || unexpected.length) throw new Error(`pinned tsc failed on the probe:\n${(unexpected.length ? unexpected : [diagnostics]).slice(0, 20).join("\n")}`);
    return read(readFileSync(out, "utf8"), out, dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
function findFile(dir, name) {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) { const found = findFile(path, name); if (found) return found; }
    else if (entry === name) return path;
  }
  return null;
}
function endOfType(text, from) {
  let depth = 0;
  for (let i = from; i < text.length; i++) {
    const c = text[i];
    if (c === '"' || c === "'") { i = text.indexOf(c, i + 1); continue; }
    if ("({[<".includes(c)) depth++;
    else if (")}]>".includes(c) && !(c === ">" && text[i - 1] === "=")) depth--;
    else if (c === ";" && depth === 0) return i;
  }
  throw new Error("unterminated emitted type");
}

// ---------------------------------------------------------------- emitted-type parser
function tokenize(src) {
  const out = [];
  for (let i = 0; i < src.length;) {
    const c = src[i];
    if (/\s/.test(c)) { i++; continue; }
    if (c === '"' || c === "'") { let j = i + 1; while (src[j] !== c) j += src[j] === "\\" ? 2 : 1; out.push({ t: "str", v: JSON.parse(c === '"' ? src.slice(i, j + 1) : `"${src.slice(i + 1, j)}"`) }); i = j + 1; continue; }
    if (src.startsWith("=>", i)) { out.push({ t: "=>" }); i += 2; continue; }
    if (src.startsWith("...", i)) { out.push({ t: "..." }); i += 3; continue; }
    const m = /^-?[0-9][0-9.e+-]*/.exec(src.slice(i));
    if (m && (c !== "-" || /[0-9]/.test(src[i + 1]))) { out.push({ t: "num", v: Number(m[0]) }); i += m[0].length; continue; }
    const id = /^[A-Za-z_$][A-Za-z0-9_$]*/.exec(src.slice(i));
    if (id) { out.push({ t: "id", v: id[0] }); i += id[0].length; continue; }
    out.push({ t: c }); i++;
  }
  return out;
}
function parse(src) {
  const toks = tokenize(src); let k = 0;
  const peek = (o = 0) => toks[k + o] ?? { t: "eof" };
  const eat = (t) => { if (peek().t !== t) throw new Error(`expected ${t} at ${k} in ${src.slice(0, 120)}`); return toks[k++]; };
  const is = (t, v) => peek().t === t && (v === undefined || peek().v === v);
  function type() {
    if (is("|")) k++;
    const members = [inter()];
    while (is("|")) { k++; members.push(inter()); }
    return members.length === 1 ? members[0] : { k: "union", members };
  }
  function inter() {
    const parts = [postfix()];
    while (is("&")) { k++; parts.push(postfix()); }
    return parts.length === 1 ? parts[0] : { k: "intersection", parts };
  }
  function postfix() {
    let base = primary();
    for (;;) {
      if (is("[") && peek(1).t === "]") { k += 2; base = { k: "array", of: base }; }
      else if (is("[")) { k++; const key = type(); eat("]"); base = { k: "indexed", of: base, key }; }
      else return base;
    }
  }
  function skipBalanced(open, close) { let d = 0; do { if (is(open)) d++; else if (is(close)) d--; k++; } while (d > 0); }
  function primary() {
    const p = peek();
    if (p.t === "(") {
      // A function type `(...) => T`, or a parenthesised type.
      const save = k; skipBalanced("(", ")");
      if (is("=>")) { k++; type(); return { k: "function" }; }
      k = save + 1; const inner = type(); eat(")"); return inner;
    }
    if (p.t === "{") return object();
    if (p.t === "[") { k++; const items = []; while (!is("]")) { if (is("...")) k++; items.push(type()); if (is("?")) k++; if (is(",")) k++; } eat("]"); return { k: "tuple", items }; }
    if (p.t === "str") { k++; return { k: "literal", v: p.v }; }
    if (p.t === "num") { k++; return { k: "literal", v: p.v }; }
    if (p.t === "-" && peek(1).t === "num") { k += 2; return { k: "literal", v: -toks[k - 1].v }; }
    if (p.t === "id") {
      if (p.v === "readonly") { k++; return postfix(); }
      if (p.v === "typeof") {
        k++; let text = "typeof ";
        if (is("id", "import")) { k++; eat("("); text += `import(${JSON.stringify(eat("str").v)})`; eat(")"); while (is(".")) { k++; text += `.${eat("id").v}`; } }
        else { text += eat("id").v; while (is(".")) { k++; text += `.${eat("id").v}`; } }
        return { k: "typeof", text };
      }
      if (p.v === "import") { k++; eat("("); const from = eat("str").v; eat(")"); eat("."); const name = eat("id").v; return { k: "ref", name, from, args: typeArgs() }; }
      const kw = { string: "string", number: "number", boolean: "boolean", null: "null", undefined: "undefined", never: "never", unknown: "unknown", any: "any", object: "object", bigint: "bigint", symbol: "symbol", void: "void" }[p.v];
      if (kw) { k++; return { k: kw }; }
      if (p.v === "true" || p.v === "false") { k++; return { k: "literal", v: p.v === "true" }; }
      return ref();
    }
    throw new Error(`unexpected ${p.t} in ${src.slice(0, 160)}`);
  }
  function ref() {
    let name = eat("id").v; let ns = null;
    while (is(".")) { k++; ns = ns ? `${ns}.${name}` : name; name = eat("id").v; }
    return { k: "ref", ns, name, args: typeArgs() };
  }
  function typeArgs() {
    if (!is("<")) return [];
    k++; const args = [type()]; while (is(",")) { k++; args.push(type()); } eat(">"); return args;
  }
  function object() {
    eat("{"); const fields = []; let index = null; let callable = false;
    while (!is("}")) {
      if (is("id", "readonly")) k++;
      if (is("[")) { k++; eat("id"); eat(":"); const key = type(); eat("]"); eat(":"); index = { key, value: type() }; }
      else {
        const name = eat(peek().t === "str" ? "str" : "id").v; const optional = is("?") ? (k++, true) : false;
        if (is("(") || is("<")) { skipBalanced(is("<") ? "<" : "(", is("<") ? ">" : ")"); if (is("(")) skipBalanced("(", ")"); eat(":"); type(); callable = true; }
        else { eat(":"); fields.push({ name, optional, type: type() }); }
      }
      if (is(";") || is(",")) k++;
    }
    eat("}");
    return { k: "object", fields, index, callable };
  }
  const t = type();
  if (k !== toks.length) throw new Error(`trailing tokens in ${src.slice(0, 160)}`);
  return t;
}

// ---------------------------------------------------------------- resolution and classification
const UTILITY = /^(Partial|Required|Readonly|Pick|Omit|Record|Exclude|Extract|NonNullable)$/;
function main(argv) {
  const json = argv.includes("--json");
  const numbersAt = argv.indexOf("--numbers");
  const numbers = numbersAt >= 0 ? argv[numbersAt + 1] : "float64";
  if (!argv.includes("--inventory") || !["float64", "integer"].includes(numbers)) {
    console.error("usage: scripts/tron proof wire --inventory [--json] [--numbers float64|integer]"); return 2;
  }
  const source = readFileSync(TYPES, "utf8");
  const exports = [...source.matchAll(/^export (interface|type|const) ([A-Za-z_$][A-Za-z0-9_$]*)(<)?/gm)].map((m) => ({ kind: m[1], name: m[2], generic: !!m[3] }));

  // Expand named declarations, then every non-trivial field expression, round by round.
  const expanded = new Map(); // expression -> parsed AST
  const pending = new Set(exports.filter((e) => e.kind !== "const" && !e.generic).map((e) => `P.${e.name}`));
  const keyOf = (ref) => (ref.from ? `import(${JSON.stringify(ref.from)}).${ref.name}` : `${ref.ns ? `${ref.ns}.` : ""}${ref.name}`);
  const visit = (node) => {
    if (!node || typeof node !== "object") return;
    if (node.k === "indexed" || node.k === "intersection" || node.k === "typeof") { if (!expanded.has(exprOf(node))) pending.add(exprOf(node)); return; }
    if (node.k === "ref") {
      const key = keyOf(node);
      if (node.args.length || UTILITY.test(node.name)) { if (!expanded.has(exprOf(node))) pending.add(exprOf(node)); }
      else if (!expanded.has(key)) pending.add(key);
      return;
    }
    for (const value of Object.values(node)) if (Array.isArray(value)) value.forEach(visit); else if (value && typeof value === "object") visit(value);
  };
  const exprOf = (node) => print(node);
  for (let round = 0; pending.size; round++) {
    if (round > 12) throw new Error("type expansion did not converge");
    const batch = [...pending].sort(); pending.clear();
    const emitted = probe(batch);
    const parsed = batch.map((expr, i) => parse(emitted[i]));
    // An expansion that is only its own name is re-probed member by member.
    const self = batch.filter((expr, i) => parsed[i].k === "ref" && print(parsed[i]) === expr);
    const members = self.length ? probe(self, new Set(self)) : [];
    batch.forEach((expr, i) => {
      const j = self.indexOf(expr);
      let ast = parsed[i];
      if (j >= 0) {
        const tuples = parse(members[j]);
        const items = (tuples.k === "union" ? tuples.members : [tuples]).map((t) => {
          if (t.k !== "tuple" || t.items.length !== 1) throw new Error(`unexpected member probe for ${expr}: ${members[j]}`);
          return t.items[0];
        });
        ast = items.length === 1 ? items[0] : { k: "union", members: items };
        if (ast.k === "ref" && print(ast) === expr) throw new Error(`${expr} expands only to itself`);
      }
      expanded.set(expr, ast); visit(ast);
    });
  }
  const unfaithful = new Set(verifyPrinted([...expanded].sort(([a], [b]) => a.localeCompare(b)).map(([expr, ast]) => [expr, print(ast)])));

  const memo = new Map();
  const classify = (node, stack = []) => {
    switch (node.k) {
      case "string": case "boolean": case "null": return { ok: true };
      case "literal": return typeof node.v === "number" && numbers === "integer" && !Number.isInteger(node.v) ? { ok: false, reason: "non-integer literal" } : { ok: true };
      case "number": return numbers === "float64" ? { ok: true } : { ok: false, reason: "number is not bounded to integers" };
      case "never": case "undefined": return { ok: true, absent: true };
      case "array": return classify(node.of, stack);
      case "indexed": return named_(exprOf(node), stack);
      case "ref": {
        const expr = node.args.length || UTILITY.test(node.name) ? exprOf(node) : keyOf(node);
        return named_(expr, stack);
      }
      case "object": {
        if (node.callable) return { ok: false, reason: "function member" };
        for (const f of node.fields) { const r = classify(f.type, stack); if (!r.ok) return { ok: false, reason: `field ${f.name}: ${r.reason}` }; }
        if (node.index) { const r = classify(node.index.value, stack); if (!r.ok) return { ok: false, reason: `map value: ${r.reason}` }; if (node.index.key.k !== "string") return { ok: false, reason: "map key is not string" }; }
        return { ok: true, object: true };
      }
      case "union": return union(node, stack);
      case "intersection": return named_(exprOf(node), stack);
      case "tuple": return { ok: false, reason: "tuple" };
      case "function": return { ok: false, reason: "function type" };
      case "typeof": return named_(exprOf(node), stack);
      default: return { ok: false, reason: `${node.k} type` };
    }
  };
  // A named declaration resolves through its compiler expansion; a cycle back to a declaration on the
  // stack is expressible as a recursive datatype if everything else is.
  const named_ = (expr, stack) => {
    if (memo.has(expr)) return memo.get(expr);
    if (stack.includes(expr)) return { ok: true, recursive: true };
    const ast = expanded.get(expr);
    if (!ast) return { ok: false, reason: `unresolved ${expr}` };
    if (unfaithful.has(expr)) return { ok: false, reason: `tsc: the parsed shape of ${expr} differs from the original` };
    const r = classify(ast, [...stack, expr]);
    const out = { ...r, object: r.object || isObjectAst(ast) };
    if (!stack.length) memo.set(expr, out);
    return out;
  };
  const isObjectAst = (ast) => ast.k === "object";
  const resolveObject = (node, seen = new Set()) => {
    if (node.k === "object") return node;
    const expr = node.k === "indexed" ? exprOf(node) : node.k === "ref" ? (node.args.length || UTILITY.test(node.name) ? exprOf(node) : keyOf(node)) : null;
    if (!expr || seen.has(expr)) return null;
    seen.add(expr);
    const ast = expanded.get(expr);
    return ast ? resolveObject(ast, seen) : null;
  };

  // The expansion behind a reference, indexed access or intersection, if the compiler produced one.
  const behind = (node) => {
    if (node.k === "indexed" || node.k === "intersection" || node.k === "typeof") return expanded.get(exprOf(node));
    if (node.k === "ref") return expanded.get(node.args.length || UTILITY.test(node.name) ? exprOf(node) : keyOf(node));
    return undefined;
  };
  // Union members with aliases of unions and literals flattened (objects stay as they are).
  const flatten = (members, seen = new Set()) => members.flatMap((m) => {
    if (m.k === "union") return flatten(m.members, seen);
    const ast = behind(m);
    if (!ast || ast.k === "object" || seen.has(exprOf(m))) return [m];
    seen.add(exprOf(m));
    return ast.k === "union" ? flatten(ast.members, seen) : flatten([ast], seen);
  });
  const jsonKind = (m) => (m.k === "literal" ? typeof m.v : m.k === "array" ? "array" : resolveObject(m) ? "object" : m.k);
  const tagSet = (t) => {
    const members = flatten([t]);
    return members.every((x) => x.k === "literal") ? members.map((x) => x.v) : null;
  };
  const union = (node, stack) => {
    let members = flatten(node.members).filter((m) => m.k !== "undefined");
    const nullable = members.some((m) => m.k === "null");
    members = members.filter((m) => m.k !== "null");
    if (members.length === 0) return { ok: true };
    if (members.length === 1) return classify(members[0], stack);
    const groups = new Map();
    for (const m of members) groups.set(jsonKind(m), [...(groups.get(jsonKind(m)) ?? []), m]);
    for (const kind of groups.keys()) if (!["string", "number", "boolean", "array", "object"].includes(kind)) return { ok: false, reason: `union member of kind ${kind}` };
    // Scalars of one JSON kind collapse to that kind (a string with literal members is a string).
    if ((groups.get("array") ?? []).length > 1) return { ok: false, reason: "union of several array types" };
    let tag;
    const objects = groups.get("object") ?? [];
    if (objects.length > 1) {
      const shapes = objects.map((m) => resolveObject(m));
      const candidates = shapes[0].fields.filter((f) => !f.optional && tagSet(f.type)).map((f) => f.name)
        .filter((name) => shapes.every((o) => o.fields.some((f) => f.name === name && !f.optional && tagSet(f.type))));
      tag = candidates.find((name) => {
        const values = shapes.flatMap((o) => tagSet(o.fields.find((f) => f.name === name).type));
        return new Set(values).size === values.length;
      });
      if (!tag) return { ok: false, reason: "object union without a discriminator of disjoint literal values" };
    }
    for (const m of members) { const r = classify(m, stack); if (!r.ok) return r; }
    return { ok: true, ...(tag ? { tag } : {}), ...(groups.size > 1 ? { byJsonKind: true } : {}), nullable };
  };


  const rows = exports.map((e) => {
    if (e.kind === "const") return { name: e.name, kind: e.kind, expressible: false, reason: "value, not a wire type" };
    if (e.generic) return { name: e.name, kind: e.kind, expressible: false, reason: "generic type parameter" };
    const r = named_(`P.${e.name}`, []);
    return { name: e.name, kind: e.kind, expressible: r.ok, ...(r.ok ? (r.tag ? { tag: r.tag } : {}) : { reason: r.reason }) };
  });
  const types = rows.filter((r) => r.kind !== "const");
  const ok = types.filter((r) => r.expressible).length;
  const summary = { numbers, exports: rows.length, types: types.length, consts: rows.length - types.length, expressible: ok, share: +(ok / types.length).toFixed(4), expansions: expanded.size, unfaithful: [...unfaithful].sort() };
  if (json) console.log(JSON.stringify({ summary, rows, expanded: Object.fromEntries([...expanded.keys()].sort().map((k) => [k, print(expanded.get(k))])) }, null, 1));
  else {
    for (const r of rows) console.log(`${r.expressible ? "yes" : "no "}  ${r.kind.padEnd(9)} ${r.name}${r.reason ? `  (${r.reason})` : r.tag ? `  [tagged on ${r.tag}]` : ""}`);
    if (unfaithful.size) console.log(`parser check: ${unfaithful.size} expansion(s) printed back differently: ${[...unfaithful].join(", ")}`);
    console.log(`wire inventory: ${ok}/${types.length} types expressible (${(100 * summary.share).toFixed(1)}%), numbers as ${numbers}; ${summary.consts} consts are values, not wire types; ${rows.length} exports`);
  }
  return 0;
}

// Prints an AST back as a TypeScript type expression (used as the probe text for nested expressions).
function print(n) {
  switch (n.k) {
    case "ref": return `${n.from ? `import(${JSON.stringify(n.from)}).` : n.ns ? `${n.ns}.` : ""}${n.name}${n.args.length ? `<${n.args.map(print).join(", ")}>` : ""}`;
    case "literal": return JSON.stringify(n.v);
    case "array": return `(${print(n.of)})[]`;
    case "indexed": return `(${print(n.of)})[${print(n.key)}]`;
    case "union": return n.members.map(print).join(" | ");
    case "intersection": return n.parts.map((p) => `(${print(p)})`).join(" & ");
    case "object": return `{ ${n.fields.map((f) => `${JSON.stringify(f.name)}${f.optional ? "?" : ""}: ${print(f.type)};`).join(" ")}${n.index ? ` [key: ${print(n.index.key)}]: ${print(n.index.value)};` : ""} }`;
    case "tuple": return `[${n.items.map(print).join(", ")}]`;
    case "function": return "(() => unknown)";
    case "typeof": return n.text;
    default: return n.k;
  }
}

try { process.exitCode = main(process.argv.slice(2)); }
catch (error) { console.error(`proof wire: ${error.message}`); process.exitCode = 2; }
