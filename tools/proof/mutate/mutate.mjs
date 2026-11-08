#!/usr/bin/env node
// mutate: automatic mutation checker for a Dafny proof block (laws + implementation).
//
// Every mutant of the implementation must be KILLED by the laws (verification fails, attributed to the
// law whose lemma failed). A mutant the laws accept is either:
//   law-gap   - the compiled-JS oracle/shadow tests reject it, but no law does (the laws are too weak:
//               once the oracle is retired, nothing would catch this bug), or
//   survived  - nothing rejects it (laws AND tests too weak, or an equivalent mutant).
// Both fail the gate unless the mutant is listed in mutate.json "accepted" with a reviewed reason
// (an equivalent mutant, or behaviour outside every law's contract that the block owner accepts).
// Stillborn mutants (resolution/type errors) are reported and excluded from the score.
//
// Block config <root>/blocks/<block>/mutate.json, every file path relative to <root> (packages/core):
//   { block, tier: "high-stakes"|"leaf", impl: "blocks/<block>/Block.dfy", symbols: [compiled functions to mutate],
//     verify: [files whose verification checks the laws], laws: { "<law id>": ["<Module.lemma>", ...] }, translate: "...",
//     setup: [[cmd...]], oracles: [{ name, cmd: [...], env?: {}, jsonEq?: [a, b] }],
//     accepted: { "<mutant id>": { kind: "equivalent"|"out-of-contract", reason, reviewer, hint? } } }
//   "equivalent" is checked, not trusted: the tool proves <sym> == mutated <sym> in Dafny (hint = proof
//   body); "out-of-contract" (behaviour no law constrains, by decision) is allowed only for tier "leaf".
// Placeholders in cmd/env: {dir} = mutant work root (a copy of <root>), {repo}, {block} (source block dir), {work}.
// Each mutant runs in its own copy of <root>, so relative includes between laws/ and blocks/ hold.
//
// Usage: scripts/tron proof mutate <block> [--root <dir>] [--laws <file>] [--config <mutate.json>] [--no-oracle]
//        [--jobs N] [--only <id-substr>] [--list] [--equiv <mutant id>] [--out <report.json>] [--recheck <report.json> [--sample N]]
//   --equiv <id>   print the generated equivalence-proof file for one mutant (for reviewers) and exit
//   --laws <file>  use this file's content as the block's laws (block.json interface[0]; shows a weakened law)
// Exit 0 iff the full mutant set ran (no --only) with no survivors, law-gaps or unknowns (after "accepted").
import { execFile } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, cpSync, rmSync, mkdtempSync, statSync } from "node:fs";
import { dirname, join, resolve, basename } from "node:path";
import { homedir, tmpdir } from "node:os";
import { promisify } from "node:util";
import { createHash, randomBytes } from "node:crypto";
import { blockHash, toolHash } from "../packet/hash.mjs";
const run = promisify(execFile);

const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n, d) => (argv.includes(n) ? argv[argv.indexOf(n) + 1] : d);
const REPO = resolve(new URL("../../..", import.meta.url).pathname);
if (!argv[0] || argv[0].startsWith("-")) { console.error("usage: scripts/tron proof mutate <block> [options] (tools/proof/README.md)"); process.exit(2); }
const root = resolve(opt("--root", join(REPO, "packages/core")));
const blockDir = join(root, "blocks", argv[0]);
const cfg = JSON.parse(readFileSync(opt("--config") ?? join(blockDir, "mutate.json"), "utf8"));
if (cfg.block !== argv[0]) { console.error(`mutate.json block "${cfg.block}" is not ${argv[0]}`); process.exit(2); }
const lawsOverride = opt("--laws");
// --laws replaces the block's laws (its first block.json interface file) in every work copy.
const lawFiles = JSON.parse(readFileSync(join(blockDir, "block.json"), "utf8")).interface;
const lawsTarget = lawFiles[0];
const verifyFiles = cfg.verify;
// The pinned toolchain only: the doctor must pass, then every Dafny call goes through its wrapper.
const DAFNY = join(process.env.XDG_CACHE_HOME || join(homedir(), "Library/Caches"), "tron-proof/bin/dafny");
// Shared Mac: at most MAX_SOLVERS concurrent Z3 processes. Each job runs one dafny command with --cores 1.
const MAX_SOLVERS = 4;
const jobs = Number(opt("--jobs", 2));
if (!(jobs >= 1 && jobs <= MAX_SOLVERS)) { console.error(`--jobs must be 1..${MAX_SOLVERS} (solver cap on the shared Mac)`); process.exit(2); }
const env = { ...process.env, DAFNY_CORES: "1", PATH: `${dirname(process.execPath)}:/usr/bin:/bin`, DOTNET_CLI_TELEMETRY_OPTOUT: "1" };

// ---------------- tokenizer (Dafny subset: enough to find and rewrite expression tokens) ----------
const OPS = ["<==>", "==>", "<==", "==", "!=", "<=", ">=", "&&", "||", ":=", ":|", "::", "=>", "->", ".."];
function tokenize(src) {
  const t = []; let i = 0, line = 1, col = 1;
  const push = (kind, text) => { t.push({ kind, text, pos: i, line, col }); };
  const adv = (n) => { for (let k = 0; k < n; k++) { if (src[i] === "\n") { line++; col = 1; } else col++; i++; } };
  while (i < src.length) {
    const c = src[i], rest = src.slice(i);
    let m;
    if (/\s/.test(c)) { adv(1); continue; }
    if (rest.startsWith("//")) { const e = src.indexOf("\n", i); adv((e < 0 ? src.length : e) - i); continue; }
    if (rest.startsWith("/*")) { const e = src.indexOf("*/", i) + 2; adv(e - i); continue; }
    if ((m = /^[A-Za-z_][A-Za-z0-9_'?]*/.exec(rest))) { push("id", m[0]); adv(m[0].length); continue; }
    if ((m = /^[0-9]+/.exec(rest))) { push("num", m[0]); adv(m[0].length); continue; }
    if (c === '"') { const e = src.indexOf('"', i + 1) + 1; push("str", src.slice(i, e)); adv(e - i); continue; }
    const op = OPS.find((o) => rest.startsWith(o));
    push("op", op ?? c); adv(op ? op.length : 1);
  }
  return t;
}

// Token index ranges [start, end) of the bodies of the configured compiled symbols.
function bodies(toks, symbols) {
  const out = [];
  for (let k = 0; k < toks.length - 1; k++) {
    if (!["function", "method", "predicate"].includes(toks[k].text) || toks[k - 1]?.text === "ghost") continue;
    const name = toks[k + 1].text;
    if (!symbols.includes(name)) continue;
    let j = k + 2; while (toks[j].text !== "{") j++;
    let depth = 0, s = j;
    for (; j < toks.length; j++) { if (toks[j].text === "{") depth++; if (toks[j].text === "}" && --depth === 0) break; }
    out.push({ name, start: s + 1, end: j });
  }
  const missing = symbols.filter((s) => !out.some((b) => b.name === s));
  if (missing.length) throw new Error(`symbols not found as compiled functions: ${missing.join(", ")}`);
  return out;
}

// Nullary-constructor groups from `datatype X = A | B(..) | C` declarations in the impl.
function ctorGroups(toks) {
  const groups = [];
  for (let k = 0; k < toks.length; k++) {
    if (toks[k].text !== "datatype") continue;
    let j = k + 1; while (toks[j].text !== "=") j++;
    const ctors = []; j++;
    while (j < toks.length) {
      const name = toks[j].text; let depth = 0, nullary = true; j++;
      if (toks[j]?.text === "(") { nullary = false; for (; j < toks.length; j++) { if (toks[j].text === "(") depth++; if (toks[j].text === ")" && --depth === 0) { j++; break; } } }
      ctors.push({ name, nullary });
      if (toks[j]?.text !== "|") break; j++;
    }
    groups.push(ctors);
  }
  return groups;
}

// ---------------- mutation operators ----------------
const ROR = { "<": ["<=", ">="], "<=": ["<", ">"], ">": [">=", "<="], ">=": [">", "<"], "==": ["!="], "!=": ["=="] };
const AOR = { "+": ["-"], "-": ["+"], "*": ["+"], "/": ["*"], "%": ["/"] };
const operandEnd = (t) => t && (t.kind === "id" || t.kind === "num" || t.text === ")" || t.text === "]");

// Constructor groups come from the impl and the block's laws, where a refined block's datatypes live.
function mutants(src, toks, symbols, lawToks = []) {
  const out = []; const groups = [...ctorGroups(toks), ...ctorGroups(lawToks)];
  const add = (sym, op, a, b, repl, from, note) => {
    const s = src.slice(0, toks[a].pos) + repl + src.slice(toks[b - 1].pos + toks[b - 1].text.length);
    out.push({ sym, op, line: toks[a].line, col: toks[a].col, from: from ?? src.slice(toks[a].pos, toks[b - 1].pos + toks[b - 1].text.length), to: repl, note, src: s });
  };
  // split [a,b) on top-level commas
  const args = (a, b) => { const r = []; let d = 0, s = a; for (let k = a; k < b; k++) { const x = toks[k].text; if ("([{".includes(x)) d++; if (")]}".includes(x)) d--; if (x === "," && d === 0) { r.push([s, k]); s = k + 1; } } r.push([s, b]); return r; };
  const close = (k) => { let d = 0; for (let j = k; j < toks.length; j++) { if (toks[j].text === "(") d++; if (toks[j].text === ")" && --d === 0) return j; } };
  for (const { name: sym, start, end } of bodies(toks, symbols)) {
    for (let k = start; k < end; k++) {
      const t = toks[k], prev = toks[k - 1], next = toks[k + 1];
      // boundary / relational (skip generic angle brackets: seq<Effect>, Option<nat>)
      if (ROR[t.text] && !((t.text === "<" || t.text === ">") && (/^(seq|set|map|multiset|iset|imap|Option)$/.test(prev?.text) || /^[A-Z]/.test(next?.text) && t.text === "<")))
        for (const r of ROR[t.text]) add(sym, ["<", "<=", ">", ">="].includes(t.text) && ["<", "<=", ">", ">="].includes(r) && r[0] === t.text[0] ? "boundary" : "relational", k, k + 1, r);
      // arithmetic (binary only)
      if (AOR[t.text] && operandEnd(prev)) for (const r of AOR[t.text]) add(sym, "arith", k, k + 1, r);
      // dropped operand (a + b*c -> a): the right operand runs to the next operator of lower or equal precedence
      if (AOR[t.text] && operandEnd(prev)) {
        const stop = t.text === "+" || t.text === "-" ? /^(\+|-|<|<=|>|>=|==|!=|&&|\|\||==>|<==>|then|else|,|\)|\]|}|;|:=)$/ : /^(\+|-|\*|\/|%|<|<=|>|>=|==|!=|&&|\|\||==>|<==>|then|else|,|\)|\]|}|;|:=)$/;
        let j = k + 1, d = 0; for (; j < end; j++) { const x = toks[j].text; if (d === 0 && j > k + 1 && stop.test(x) && !(x === "-" && !operandEnd(toks[j - 1]))) break; if ("([{".includes(x)) d++; if (")]}".includes(x)) { if (d === 0) break; d--; } }
        add(sym, "drop-operand", k, j, "", src.slice(toks[k].pos, toks[j - 1].pos + toks[j - 1].text.length), "drop right operand");
      }
      // off-by-one on a variable used in arithmetic or a comparison: x -> (x + 1), (x - 1)
      const arithCtx = (u) => u && (AOR[u.text] || ROR[u.text]);
      if (t.kind === "id" && /^[a-z]/.test(t.text) && prev?.text !== "." && next?.text !== "(" && next?.text !== "." && (arithCtx(prev) || arithCtx(next)) && !["then", "else", "if", "var", "match", "case", "true", "false"].includes(t.text)) {
        add(sym, "off-by-one", k, k + 1, `(${t.text} + 1)`); add(sym, "off-by-one", k, k + 1, `(${t.text} - 1)`);
      }
      if (t.text === "&&") add(sym, "logic", k, k + 1, "||");
      if (t.text === "||") add(sym, "logic", k, k + 1, "&&");
      if (t.text === "!" && next?.text !== "=") add(sym, "logic", k, k + 1, "", "!", "drop negation");
      // constants
      if (t.kind === "num") { const n = Number(t.text); add(sym, "constant", k, k + 1, String(n + 1)); if (n > 0) add(sym, "constant", k, k + 1, String(n - 1)); }
      if (t.text === "true" || t.text === "false") add(sym, "constant", k, k + 1, t.text === "true" ? "false" : "true");
      // dropped branch: `if C then` -> `if true/false then`
      if (t.text === "if") {
        let j = k + 1, d = 0; for (; j < end; j++) { const x = toks[j].text; if ("([{".includes(x)) d++; if (")]}".includes(x)) d--; if (x === "then" && d === 0) break; }
        add(sym, "branch", k + 1, j, "true", undefined, "drop else-branch"); add(sym, "branch", k + 1, j, "false", undefined, "drop then-branch");
      }
      // constructors: swap nullary siblings; replace a constructor call with a nullary sibling (dropped value)
      if (t.kind === "id" && prev?.text !== "." && prev?.text !== "case") {
        const g = groups.find((g) => g.some((c) => c.name === t.text));
        if (g) {
          const me = g.find((c) => c.name === t.text);
          if (me.nullary && next?.text !== "(") for (const c of g) if (c.nullary && c.name !== t.text) add(sym, "constructor", k, k + 1, c.name);
          if (!me.nullary && next?.text === "(") { const e = close(k + 1); for (const c of g) if (c.nullary) add(sym, "constructor", k, e + 1, c.name, undefined, "drop value"); }
        }
      }
      // swapped arguments of a call / constructor with >= 2 args
      if (t.kind === "id" && next?.text === "(" && prev?.text !== "case") {
        const e = close(k + 1); const as = args(k + 2, e);
        for (let a = 0; a + 1 < as.length; a++) {
          const [x0, x1] = as[a], [y0, y1] = as[a + 1];
          const X = src.slice(toks[x0].pos, toks[x1 - 1].pos + toks[x1 - 1].text.length), Y = src.slice(toks[y0].pos, toks[y1 - 1].pos + toks[y1 - 1].text.length);
          if (X !== Y) add(sym, "swap-args", x0, y1, `${Y}, ${X}`, `${X}, ${Y}`, `${t.text} args ${a + 1}<->${a + 2}`);
        }
      }
    }
  }
  // stable ids: sym/op/from->to#n (n = occurrence among identical keys); dedupe identical sources
  const seen = new Map(), count = {}; const res = [];
  for (const m of out) {
    const h = createHash("sha256").update(m.src).digest("hex").slice(0, 12);
    if (seen.has(h) || m.src === src) continue; seen.set(h, 1);
    const key = `${m.sym}/${m.op}/${m.from.replace(/\s+/g, " ")}->${m.to}`; count[key] = (count[key] ?? 0) + 1;
    res.push({ ...m, id: `${key}#${count[key]}`, hash: h });
  }
  return res;
}

// ---------------- proving an accepted mutant equivalent ----------------
// Builds: original impl + the mutated definition renamed <sym>__mutant + a lemma
//   <sym>__equiv(params) requires <same requires> ensures <sym>(params) == <sym>__mutant(params) { hint }
// inserted right after the original definition. Verified with the pinned Dafny; no proof, no acceptance.
// A refining definition inherits its preconditions from the laws (abstract module) and Dafny enforces them at
// every call, so they are read from the laws' signature of <sym> when the impl states none: equivalence is
// proven over the function's whole domain, exactly as for a definition that states its own requires.
function lawRequires(sym) {
  for (const f of lawFiles) {
    const text = readFileSync(lawsOverride && f === lawsTarget ? resolve(lawsOverride) : join(root, f), "utf8");
    const m = new RegExp(`^\\s*(?:ghost\\s+)?(?:function|predicate)\\s+${sym}\\b[\\s\\S]*?(?=\\n\\s*\\n|\\n\\s*(?://|lemma|function|predicate|method|ghost|datatype|\\{|\\}))`, "m").exec(text);
    if (m) return m[0];
  }
  return "";
}
function equivSource(origSrc, mutSrc, sym, hint) {
  const def = (src) => { const t = tokenize(src); const b = bodies(t, [sym])[0]; let k = b.start; while (!["function", "predicate", "method"].includes(t[k].text)) k--; return { t, from: t[k].pos, open: t[b.start - 1].pos, to: t[b.end].pos + 1, k }; };
  const o = def(origSrc), m = def(mutSrc);
  const header = origSrc.slice(o.from, o.open);
  const params = header.slice(header.indexOf("(") + 1, header.indexOf(")"));
  const names = params.split(",").map((p) => p.split(":")[0].trim()).filter(Boolean);
  // Every requires clause, including multi-line ones (each runs to the next clause keyword).
  const clauses = (text) => (text.match(/requires[\s\S]*?(?=\s(?:requires|ensures|decreases|reads|modifies)\b|$)/g) ?? []).map((r) => r.trim());
  const own = clauses(header);
  const requires = (own.length ? own : clauses(lawRequires(sym))).join("\n    ");
  const rename = (txt) => txt.replace(new RegExp(`\\b${sym}\\b`, "g"), `${sym}__mutant`);
  const mutDef = rename(mutSrc.slice(m.from, m.to));
  const call = (f) => `${f}(${names.join(", ")})`;
  const lemma = `\n  lemma ${sym}__equiv(${params})\n    ${requires}\n    ensures ${call(sym)} == ${call(sym + "__mutant")}\n  { ${hint ?? ""} }\n`;
  return origSrc.slice(0, o.to) + "\n  " + mutDef + lemma + origSrc.slice(o.to);
}

// ---------------- running a mutant ----------------
const fill = (s, vars) => s.replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? `{${k}}`);
// Every child runs in its own process group so an interrupted run kills its dafny AND z3 processes
// (killing only node used to leave orphaned solvers running).
const children = new Set();
const killAll = () => { for (const pid of children) { try { process.kill(-pid, "SIGKILL"); } catch {} } };
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, () => { killAll(); process.exit(130); });
process.on("exit", killAll);
async function sh(cmd, opts) {
  const p = run(cmd[0], cmd.slice(1), { maxBuffer: 1 << 26, timeout: 600_000, killSignal: "SIGKILL", detached: true, ...opts });
  children.add(p.child.pid);
  try { const r = await p; return { code: 0, out: r.stdout + r.stderr, stdout: r.stdout }; }
  catch (e) { return { code: e.code ?? 1, out: (e.stdout ?? "") + (e.stderr ?? "") + (e.killed ? "\n[killed: timeout]" : ""), stdout: e.stdout ?? "" }; }
  finally { try { process.kill(-p.child.pid, "SIGKILL"); } catch {} children.delete(p.child.pid); }
}
function lawOf(symbol) {
  for (const [law, syms] of Object.entries(cfg.laws)) if (syms.includes(symbol)) return law;
  return null;
}
// One verifier run per law file; every CSV row is classified:
//   a mapped law lemma Failed            -> that law kills the mutant
//   a compiled impl symbol's well-formedness Failed -> the build rejects the mutant (counted as wf, a kill)
//   a timeout anywhere                   -> unknown (never a kill: the gate fails unless a law also failed)
//   any other failing lemma (unmapped)   -> unmapped (never a kill: map it to a law or it fails the gate)
const ROW = /^(.*) \((correctness|well-formedness)\),([A-Za-z]+),/;
async function verify(dir, baseline = false) {
  const failed = new Set(), unmapped = new Set(), passed = new Set(); let stillborn = false, timeouts = 0, wf = false, error = null;
  for (const f of verifyFiles) {
    const csv = join(dir, `verify-${basename(f)}.csv`);
    const r = await sh([DAFNY, "verify", "--cores", "1", "--verify-included-files", "--verification-time-limit", "30", ...(cfg.resourceLimit ? ["--resource-limit", String(cfg.resourceLimit)] : []), "--log-format", `csv;LogFileName=${csv}`, f], { cwd: dir, env });
    if (/resolution\/type errors|parse errors/.test(r.out)) { stillborn = true; break; }
    let rows = []; try { rows = readFileSync(csv, "utf8").trim().split("\n").slice(1); } catch {}
    if (!rows.length) { error = `no verifier results for ${f} (exit ${r.code})`; continue; }
    // Dafny's CSV marks a time-out or resource-out as plain "Failed"; only stdout names them. A symbol whose
    // verification timed out or ran out of resources is unknown, never a kill.
    const timedOut = new Set([...r.out.matchAll(/Verification of '([^']+)'[^\n]*?(?:timed out|out of resource)/g), ...r.out.matchAll(/Verification (?:out of resource|inconclusive) \(([^)]+)\)/g)].map((m) => m[1]));
    if (/out of resource|timed out|inconclusive/i.test(r.out) && !timedOut.size) error = "time-out or resource-out not attributable to a symbol";
    let failures = 0;
    for (const row of rows) {
      const m = ROW.exec(row); if (!m) { error = `unparsable verifier row: ${row.slice(0, 80)}`; continue; }
      const [, name, part, outcome] = m; const law = lawOf(name);
      if (outcome === "Passed") { if (law) passed.add(law); continue; }
      failures++;
      if (timedOut.has(name) || /Time|Out|Resource/i.test(outcome)) { timeouts++; continue; }
      if (law) failed.add(law);
      else if (part === "well-formedness" && cfg.symbols.includes(name.split(".").pop())) wf = true;
      else unmapped.add(name);
    }
    if (r.code !== 0 && failures === 0) error = `verifier exit ${r.code} with no failing rows`;
  }
  return { stillborn, failedLaws: [...failed].sort(), wf, unmapped: [...unmapped].sort(), timeouts, error, passedLaws: [...passed] };
}
async function oracles(dir, work) {
  const vars = { dir, repo: REPO, block: blockDir, work };
  const tr = await sh([DAFNY, "translate", "js", "--no-verify", "--include-runtime", cfg.translate, "-o", join(dir, "out/core")], { cwd: dir, env });
  if (tr.code !== 0) return { compiled: false, failed: ["compile"] };
  const failed = [];
  for (const o of cfg.oracles) {
    const e = { ...env }; for (const [k, v] of Object.entries(o.env ?? {})) e[k] = fill(v, vars);
    const r = await sh(o.cmd.map((c) => fill(c, vars)), { cwd: REPO, env: e });
    let ok = r.code === 0;
    // An oracle's verdict is its stdout JSON; stderr (warnings) is diagnostics only.
    if (ok && o.jsonEq) { try { const j = JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))); ok = j[o.jsonEq[0]] === j[o.jsonEq[1]]; } catch { ok = false; } }
    if (!ok) failed.push(o.name);
  }
  return { compiled: true, failed };
}
// A copy of <root>'s sources (laws/ and blocks/), so every relative include resolves as in the source tree.
function copyBlock(dst) {
  mkdirSync(dst, { recursive: true });
  cpSync(root, dst, { recursive: true, filter: (src) => statSync(src).isDirectory() ? !["out", "dist", "node_modules"].includes(basename(src)) : /\.(dfy|mjs|ts|json)$/.test(src) });
  if (lawsOverride) cpSync(resolve(lawsOverride), join(dst, lawsTarget));
}

// ---------------- main ----------------
const implSrc = readFileSync(join(root, cfg.impl), "utf8");
const generated = mutants(implSrc, tokenize(implSrc), cfg.symbols, lawFiles.flatMap((f) => tokenize(readFileSync(join(root, f), "utf8"))));
let all = generated;
if (opt("--only")) all = all.filter((m) => m.id.includes(opt("--only")));
// --recheck <report.json> [--sample N]: never trusts a report. (1) Every count and the verdict are recomputed
// from the per-mutant results, and every acceptance must be one listed in mutate.json. (2) Every mutant the
// report calls stillborn is re-resolved (no solver) and must really fail to resolve. (3) Every mutant not
// labelled killed (accepted ones included) is re-run in full. (4) N killed mutants, chosen with a FRESH
// RANDOM seed, are re-run. Statuses and acceptances must match. packet.mjs --recheck uses this.
const recheck = opt("--recheck") ? JSON.parse(readFileSync(opt("--recheck"), "utf8")) : null;
let recheckProblems = [];
if (recheck) {
  const fail = (why) => { console.log(JSON.stringify({ recheck: "mismatch", why })); process.exit(1); };
  const rs = recheck.results;
  if (rs.length !== generated.length || rs.some((r) => !generated.some((m) => m.id === r.id))) fail("report's mutant set differs from the generated set");
  const bogus = rs.filter((r) => r.accepted && !cfg.accepted?.[r.id]); if (bogus.length) fail(`acceptances not in mutate.json: ${bogus.map((r) => r.id).join(", ")}`);
  const vs = rs.filter((r) => r.status !== "stillborn"), cnt = (st) => vs.filter((r) => r.status === st && !r.accepted).length;
  const derived = { mutants: rs.length, stillborn: rs.length - vs.length, valid: vs.length, killed: cnt("killed"), lawGap: cnt("law-gap"), survived: cnt("survived"), accepted: vs.filter((r) => r.accepted).length,
    unknown: vs.filter((r) => ["unknown-timeout", "unmapped", "verifier-error"].includes(r.status)).length };
  derived.pass = recheck.summary.filter == null && vs.length > 0 && derived.stillborn / rs.length <= 0.4 && derived.lawGap === 0 && derived.survived === 0 && derived.unknown === 0;
  for (const [k, v] of Object.entries(derived)) if (recheck.summary[k] !== v) fail(`summary.${k} ${recheck.summary[k]} but results imply ${v}`);
  // (2) stillborn claims: resolve each one; it must not resolve.
  const sdir = mkdtempSync(join(tmpdir(), "mutate-sb-")); copyBlock(sdir);
  for (const r of rs.filter((x) => x.status === "stillborn")) {
    writeFileSync(join(sdir, cfg.impl), generated.find((m) => m.id === r.id).src);
    const res = await sh([DAFNY, "resolve", cfg.verify[0]], { cwd: sdir, env });
    if (res.code === 0) { rmSync(sdir, { recursive: true, force: true }); fail(`mutant ${r.id} is labelled stillborn but resolves`); }
  }
  rmSync(sdir, { recursive: true, force: true });
  const seed = randomBytes(16).toString("hex"), rank = (id) => createHash("sha256").update(seed + id).digest("hex");
  const killed = rs.filter((r) => r.status === "killed").map((r) => r.id).sort((a, b) => rank(a).localeCompare(rank(b)));
  const pick = new Set([...killed.slice(0, Number(opt("--sample", 6))), ...rs.filter((r) => r.status !== "killed" && r.status !== "stillborn").map((r) => r.id)]);
  all = generated.filter((m) => pick.has(m.id));
}
for (const id of Object.keys(cfg.accepted ?? {})) if (!generated.some((m) => m.id === id)) { console.error(`accepted mutant ${id} matches no generated mutant (stale acceptance)`); process.exit(2); }
if (opt("--equiv")) { const m = all.find((x) => x.id === opt("--equiv")); if (!m) { console.error(`no mutant ${opt("--equiv")} (use --list)`); process.exit(2); } console.log(equivSource(implSrc, m.src, m.sym, cfg.accepted?.[m.id]?.hint)); process.exit(0); }
if (flag("--list")) { for (const m of all) console.log(`${m.id}  (${m.line}:${m.col})`); console.error(`${all.length} mutants`); process.exit(0); }
const doctor = await sh(["/bin/bash", join(REPO, "tools/proof/bootstrap.sh"), "doctor"], { env });
if (doctor.code !== 0) { console.error(`pinned toolchain unavailable: ${doctor.out.trim()}`); process.exit(2); }
const work = mkdtempSync(join(tmpdir(), "mutate-"));
const t0 = Date.now();
// Baseline: the unmutated block must pass every law and every oracle, or the run means nothing.
copyBlock(join(work, "base"));
for (const s of cfg.setup ?? []) { const r = await sh(s.map((c) => fill(c, { repo: REPO, block: blockDir, work, dir: join(work, "base") })), { cwd: REPO, env }); if (r.code) { console.error(`setup failed: ${s.join(" ")}\n${r.out}`); process.exit(2); } }
// Every implementation function the build compiles must be mutated or excluded with a reason.
{
  const t = tokenize(implSrc); const compiled = [];
  for (let k = 0; k < t.length - 1; k++) if (["function", "predicate", "method"].includes(t[k].text) && t[k - 1]?.text !== "ghost" && t[k - 1]?.text !== "lemma") compiled.push(t[k + 1].text);
  const missing = compiled.filter((n) => !cfg.symbols.includes(n) && !(cfg.excludeSymbols ?? {})[n]);
  if (missing.length) { console.error(`compiled impl functions neither mutated nor excluded (mutate.json excludeSymbols {name: reason}): ${missing.join(", ")}`); process.exit(2); }
}
const bv = await verify(join(work, "base"));
const notCovered = Object.keys(cfg.laws).filter((l) => !bv.passedLaws.includes(l));
if (notCovered.length) { console.error(`BASELINE: laws with no Passed verifier row (lemma names wrong?): ${notCovered.join(", ")}`); process.exit(2); }
const bo = flag("--no-oracle") ? { failed: [] } : await oracles(join(work, "base"), work);
if (bv.stillborn || bv.failedLaws.length || bv.unmapped.length || bv.timeouts || bv.wf || bv.error || bo.failed.length) { console.error(`BASELINE FAILS: laws ${JSON.stringify(bv)} oracles ${JSON.stringify(bo)}`); process.exit(2); }
console.error(`baseline ok; ${all.length} mutants; ${jobs} jobs; work ${work}`);

const results = []; let next = 0, done = 0; // `all` is reassigned for the retry pass
async function worker() {
  while (next < all.length) {
    const m = all[next++]; const dir = join(work, `m${m.hash}`);
    copyBlock(dir); writeFileSync(join(dir, cfg.impl), m.src);
    const v = await verify(dir);
    const o = v.stillborn || v.failedLaws.length || v.wf || flag("--no-oracle") ? { failed: [] } : await oracles(dir, work);
    // Only a failing law (or the build rejecting the impl itself) kills; timeouts, unmapped lemmas and
    // verifier errors never do, so they cannot mask a weak law.
    const lawKill = v.failedLaws.length > 0 || v.wf;
    const status = v.stillborn ? "stillborn" : lawKill ? "killed" : v.timeouts ? "unknown-timeout" : v.unmapped.length ? "unmapped" : v.error ? "verifier-error" : o.failed.length ? "law-gap" : "survived";
    // An acceptance counts only if it holds: "equivalent" needs a verified equivalence lemma (and an
    // oracle disagreement refutes it); "out-of-contract" is allowed only for leaf blocks.
    let accepted; const acc = cfg.accepted?.[m.id];
    if (acc && (status === "law-gap" || status === "survived")) {
      if (acc.kind === "equivalent") {
        // Beside the impl, so its relative includes resolve.
        const equiv = join(dirname(cfg.impl), "Equiv.dfy");
        writeFileSync(join(dir, equiv), equivSource(implSrc, m.src, m.sym, acc.hint));
        const r = await sh([DAFNY, "verify", "--verification-time-limit", "30", equiv], { cwd: dir, env });
        const proven = r.code === 0 && status === "survived";
        accepted = proven ? `equivalent (proven): ${acc.reason} [${acc.reviewer}]` : undefined;
        if (!proven) acc.unproven = (acc.unproven ?? []).concat(r.out.split("\n").filter((l) => /Error|finished/.test(l)).slice(0, 3));
      } else if (acc.kind === "out-of-contract" && cfg.tier === "leaf") accepted = `out-of-contract: ${acc.reason} [${acc.reviewer}]`;
    }
    results.push({ id: m.id, sym: m.sym, op: m.op, line: m.line, col: m.col, from: m.from, to: m.to, note: m.note, status, accepted, acceptanceRejected: acc && !accepted && status !== "killed" ? (acc.unproven ?? ["acceptance not allowed for this tier"]) : undefined, killedBy: v.failedLaws.concat(v.wf ? ["build: impl well-formedness"] : []), unmapped: v.unmapped, timeouts: v.timeouts, error: v.error, oracleFailed: o.failed });
    rmSync(dir, { recursive: true, force: true });
    if (++done % 25 === 0) console.error(`  ${done}/${all.length}`);
  }
}
await Promise.all(Array.from({ length: jobs }, worker));
// Time limits are wall-clock, so a loaded host can time out a proof that normally fails fast. Retry each
// timed-out mutant once, alone (one solver); it stays unknown (gate FAIL) if it times out again.
const retry = results.filter((r) => r.status === "unknown-timeout");
if (retry.length) {
  console.error(`  retrying ${retry.length} timed-out mutant(s) serially`);
  for (const r of retry) results.splice(results.indexOf(r), 1);
  all = all.filter((m) => retry.some((r) => r.id === m.id)); next = 0;
  await worker();
  for (const r of results) if (retry.some((x) => x.id === r.id)) r.retried = true;
}
rmSync(work, { recursive: true, force: true });
results.sort((a, b) => a.line - b.line || a.col - b.col || a.id.localeCompare(b.id));
if (recheck) {
  const want = Object.fromEntries(recheck.results.map((r) => [r.id, `${r.status}|${r.accepted ? "accepted" : ""}`]));
  const bad = results.filter((r) => want[r.id] !== `${r.status}|${r.accepted ? "accepted" : ""}`).map((r) => ({ id: r.id, report: want[r.id], now: `${r.status}|${r.accepted ? "accepted" : ""}` }));
  const out = { recheck: bad.length ? "mismatch" : "ok", inputsHash: blockHash(root, cfg), reportHash: recheck.summary.inputsHash, sampled: results.map((r) => r.id), mismatches: bad };
  console.log(JSON.stringify(out)); process.exit(bad.length || out.inputsHash !== out.reportHash ? 1 : 0);
}

// ---------------- report ----------------
const valid = results.filter((r) => r.status !== "stillborn");
const n = (s) => valid.filter((r) => r.status === s && !r.accepted).length;
const laws = Object.keys(cfg.laws);
const perLaw = laws.map((l) => ({ law: l, killed: valid.filter((r) => r.killedBy.includes(l)).length, only: valid.filter((r) => r.killedBy.length === 1 && r.killedBy[0] === l).length }));
const other = [...new Set(valid.flatMap((r) => r.killedBy).filter((l) => !laws.includes(l)))];
const summary = { block: cfg.block, tier: cfg.tier, laws: lawsOverride ?? cfg.verify.join(","), oracle: !flag("--no-oracle") && cfg.oracles.length > 0, toolHash: toolHash(), mutants: results.length, stillborn: results.length - valid.length, valid: valid.length, killed: n("killed"), lawGap: n("law-gap"), survived: n("survived"), accepted: valid.filter((r) => r.accepted).length, seconds: Math.round((Date.now() - t0) / 1000) };
summary.score = valid.length ? +(summary.killed / valid.length).toFixed(3) : 0;
summary.unknown = valid.filter((r) => ["unknown-timeout", "unmapped", "verifier-error"].includes(r.status)).length;
summary.stillbornRatio = results.length ? +(summary.stillborn / results.length).toFixed(3) : 0;
// Zero valid mutants proves nothing; too many stillborn mutants means the generator is not testing the code.
// A filtered run (--only) is diagnostic: it never passes, so a partial run cannot stand in for the gate.
summary.filter = opt("--only") ?? null; summary.generated = generated.length;
summary.pass = summary.filter === null && summary.mutants === summary.generated && summary.valid > 0 && summary.stillbornRatio <= 0.4 && summary.lawGap === 0 && summary.survived === 0 && summary.unknown === 0;
// Binds this report to the exact block inputs (packet.mjs shows it STALE after any edit); a --laws or
// --config override is recorded and never matches the block's own hash.
summary.inputsHash = lawsOverride || opt("--config") ? `override:${blockHash(root, cfg)}` : blockHash(root, cfg);
const byOp = {}; for (const r of results) { const o = (byOp[r.op] ??= { valid: 0, killed: 0, lawGap: 0, survived: 0, unknown: 0, accepted: 0 }); if (r.status === "stillborn") continue; o.valid++; if (r.accepted) o.accepted++; else if (r.status === "law-gap") o.lawGap++; else if (r.status === "killed" || r.status === "survived") o[r.status]++; else o.unknown++; }
const md = [`# Mutation report: ${cfg.block} (${cfg.tier})`, "", `laws: \`${summary.laws}\`; oracle tests: ${summary.oracle ? cfg.oracles.map((o) => o.name).join(", ") : "off"}; generated by \`scripts/tron proof mutate\``, "",
  `**${summary.pass ? "PASS" : "FAIL"}**: ${summary.mutants} mutants, ${summary.stillborn} stillborn, ${summary.valid} valid: ${summary.killed} killed by laws, ${summary.lawGap} law-gap (oracle only), ${summary.survived} survived, ${summary.unknown} unknown (timeout/unmapped/error), ${summary.accepted} accepted (proven). Score ${summary.score}. ${summary.seconds} s.`, "",
  "| Law | Mutants killed | Killed only by this law |", "|---|---|---|", ...perLaw.map((p) => `| ${p.law} | ${p.killed} | ${p.only} |`), ...other.map((o) => `| ${o} (not a law: impl well-formedness / proof helper) | ${valid.filter((r) => r.killedBy.includes(o)).length} | - |`), "",
  "| Operator | Generated | Stillborn | Valid | Killed | Law-gap | Survived | Unknown | Accepted |", "|---|---|---|---|---|---|---|---|---|", ...Object.entries(byOp).map(([o, c]) => `| ${o} | ${results.filter((r) => r.op === o).length} | ${results.filter((r) => r.op === o && r.status === "stillborn").length} | ${c.valid} | ${c.killed} | ${c.lawGap} | ${c.survived} | ${c.unknown} | ${c.accepted} |`), ""];
const bad = valid.filter((r) => r.status !== "killed" || r.accepted);
if (bad.length) md.push("| Not killed by a law | Where | Change | Oracle | Status |", "|---|---|---|---|---|", ...bad.map((r) => `| \`${r.id}\` | ${r.sym} ${r.line}:${r.col} | \`${r.from}\` -> \`${r.to}\` | ${r.oracleFailed.join(", ") || (r.status === "killed" ? "-" : "passes")} | ${r.accepted ? `accepted: ${r.accepted}` : r.status + (r.acceptanceRejected ? ` (acceptance rejected: ${r.acceptanceRejected.join(" ").replace(/\|/g, "/")})` : "")} |`), "");
const outPath = opt("--out");
if (outPath) { writeFileSync(outPath, JSON.stringify({ summary, perLaw, results }, null, 1)); writeFileSync(outPath.replace(/\.json$/, ".md"), md.join("\n")); }
console.log(md.join("\n"));
process.exit(summary.pass ? 0 : 1);
