#!/usr/bin/env node
// packet: render a block's law review packet (LAWS.md) from the sources, never by hand, so the packet
// cannot drift from what is proven. Per law: plain English (the comment block directly above each lemma),
// the Dafny statement (lemma header, no proof body) of the law and of every supporting lemma it lists,
// the reviewer's verdict and notes, and its mutation kills. Per block: the implementation under test
// (full definitions of the compiled functions), the definitions the laws use, the world-model assumptions,
// the law-kind checklist, and its gates: proof, independent review, mutation and, until a shell runs the block
// (block.json "shell"), shadow and readiness for cut-over.
// Every gate result is bound to the block hash (hash.mjs): any edit makes it STALE.
//
// Usage: scripts/tron proof packet <block> [--root <dir>] [--write] [--no-verify] [--recheck]   -> <block dir>/LAWS.md
//   --recheck re-runs a random sample of mutants and the shadow comparison (gate files are not trusted);
//   "Ready for cut-over" can only be YES with --recheck.
//        scripts/tron proof packet --batch <out.md> [--root <dir>] <block>...      -> one batch for human reading
// Exit 1 if the packet has problems (missing English, unlisted law lemma, missing law kinds).
import { readFileSync, readdirSync, statSync, writeFileSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { execFileSync } from "node:child_process";
import { blockFiles, blockHash, toolHash } from "./hash.mjs";

const REPO = resolve(new URL("../../..", import.meta.url).pathname);
const DAFNY = join(process.env.XDG_CACHE_HOME || join(homedir(), "Library/Caches"), "tron-proof/bin/dafny");
const readJson = (p) => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null);
const KINDS = ["safety", "progress", "recovery", "stale-inputs", "exact-results", "uncertain-outcomes"];
const LAW_ID = /^[A-Z]\d+[a-z]?\b/; // a comment starting with a law id (L7, R6b) marks a law lemma
const env = { ...process.env, PATH: `${dirname(process.execPath)}:/usr/bin:/bin`, DAFNY_CORES: "1" };
// Reviewer transcripts are read (never written) from Pi's session store.
const SESSIONS = join(homedir(), ".tron/agent/sessions");
const sh = (cmd, cwd) => { try { return { code: 0, out: execFileSync(cmd[0], cmd.slice(1), { cwd, env, maxBuffer: 1 << 26 }).toString() }; } catch (e) { return { code: e.status ?? 1, out: (e.stdout ?? "").toString() + (e.stderr ?? "").toString() }; } };

function sourcesOf(root, cfg) {
  return blockFiles(root, cfg).map((f) => ({ f, src: readFileSync(join(root, f), "utf8") }));
}
// All declarations: { kind, name, file, comment, header, body }.
function decls(sources) {
  const out = [];
  for (const { f, src } of sources) {
    const re = /^([ \t]*)(?:ghost\s+)?(lemma|predicate|function|method)\s+(?:\{:[^}]*\}\s*)*([A-Za-z_][A-Za-z0-9_']*)/gm; let m;
    while ((m = re.exec(src))) {
      const lines = src.slice(0, m.index).split("\n"); lines.pop();
      const comment = []; while (lines.length && /^\s*\/\//.test(lines[lines.length - 1])) comment.unshift(lines.pop().replace(/^\s*\/\/\s?/, ""));
      // The body's `{` is the first one not preceded by an operator (`== {s}` is a set literal).
      let i = src.indexOf("{", m.index); while (i > 0 && /(?:[=<>+\-*(,|&:]|\bin)\s*$/.test(src.slice(m.index, i))) i = src.indexOf("{", i + 1);
      // An abstract (laws) declaration has no body: it ends at the next line that is a comment, a blank line,
      // another declaration or the module's closing brace.
      const end = /\n[ \t]*(?:\/\/|\n|(?:ghost\s+)?(?:lemma|predicate|function|method|datatype|type|const|import)\b|\})/.exec(src.slice(m.index + m[0].length));
      const stop = end ? m.index + m[0].length + end.index : src.length;
      const dedent = (x) => x.replace(new RegExp(`^${m[1]}`, "gm"), "");
      if (i < 0 || i > stop) { out.push({ kind: m[2], ghost: /ghost/.test(src.slice(m.index, m.index + m[0].length)), name: m[3], file: f, comment: comment.join(" "), header: dedent(src.slice(m.index, stop).trimEnd()), body: "" }); continue; }
      let d = 0, j = i; for (; j < src.length; j++) { if (src[j] === "{") d++; if (src[j] === "}" && --d === 0) break; }
      out.push({ kind: m[2], ghost: /ghost/.test(src.slice(m.index, m.index + m[0].length)), name: m[3], file: f, comment: comment.join(" "), header: dedent(src.slice(m.index, i).trimEnd()), body: dedent(src.slice(i, j + 1)) });
    }
  }
  return out;
}
const idsIn = (text) => new Set(text.match(/\b[A-Za-z_][A-Za-z0-9_]*\b/g) ?? []);

function packet(root, block, opts = {}) {
  const dir = join(root, "blocks", block); const cfg = readJson(join(dir, "mutate.json"));
  if (!cfg) throw new Error(`no mutate.json for block ${block} under ${root}`);
  if (cfg.block !== block) throw new Error(`mutate.json block "${cfg.block}" is not ${block}`);
  const sources = sourcesOf(root, cfg); const all = decls(sources);
  const hash = blockHash(root, cfg);
  const review = readJson(join(dir, "REVIEW.json")), shadow = readJson(join(dir, "SHADOW.json"));
  const report = cfg.report ? readJson(join(root, cfg.report)) : null;
  const problems = [];
  // A law's statement and English live in the block's laws (block.json interface); a refining proof repeats only its name.
  const { interface: lawPaths, shell } = JSON.parse(readFileSync(join(dir, "block.json"), "utf8"));
  const lawFiles = new Set(lawPaths);
  // A law is a lemma, or a compiled method whose contract is the law.
  const named = (sym) => all.filter((d) => (d.kind === "lemma" || d.kind === "method") && d.name === sym.split(".").pop());
  const lemma = (sym) => named(sym).find((d) => lawFiles.has(d.file)) ?? named(sym)[0];
  const laws = Object.entries(cfg.laws).map(([law, syms]) => ({ law, items: syms.map((s) => lemma(s) ?? (problems.push(`${law}: lemma ${s} not found`), null)).filter(Boolean) }));
  for (const { law, items } of laws) if (items[0] && !items[0].comment) problems.push(`${law}: no plain-English comment above ${items[0].name}`);
  // Coverage: every lemma whose English starts with a law id must be listed as a law.
  const listed = new Set(Object.values(cfg.laws).flat().map((s) => s.split(".").pop()));
  const helpers = new Set(cfg.helpers ?? []);
  // Every lemma outside the impl is either part of a listed law or a declared helper; nothing hides.
  for (const d of all) if (d.kind === "lemma" && !listed.has(d.name) && !helpers.has(d.name)) problems.push(`lemma ${d.name} (${d.file}) is neither in mutate.json laws nor in helpers`);
  for (const d of all) if ((d.kind === "lemma" || d.kind === "method") && LAW_ID.test(d.comment) && !listed.has(d.name)) problems.push(`lemma ${d.name} is marked as law "${d.comment.slice(0, 20)}..." but not listed in mutate.json laws`);
  for (const { f, src } of sources) { const n = (src.replace(/\/\/[^\n]*/g, "").match(/\bassume\b|\{:axiom\}|\{:verify\s+false\}|\{:extern[^}]*\}/g) ?? []).length; if (n) problems.push(`${f}: ${n} escape hatch(es) (assume/axiom/verify false/extern) need a maintainer decision`); }
  // Law kinds (LAW-WRITING.md): high-stakes blocks must account for every kind.
  const kinds = cfg.kinds ?? {};
  if (cfg.tier === "high-stakes") for (const k of KINDS) if (!kinds[k] || (Array.isArray(kinds[k]) && !kinds[k].length)) problems.push(`law kind "${k}" not accounted for (list law ids or "n/a: <reason>")`);
  for (const [k, v] of Object.entries(kinds)) if (Array.isArray(v)) for (const l of v) if (!cfg.laws[l]) problems.push(`kinds.${k} names unknown law "${l}"`);
  // Definitions the statements use: spec predicates/functions from any file; compiled impl functions are shown in full separately.
  const implSyms = new Set(cfg.symbols);
  const used = new Map(); const visit = (text) => { for (const id of idsIn(text)) { const d = all.find((x) => x.name === id && (x.kind === "predicate" || x.kind === "function") && !implSyms.has(x.name)); if (d && !used.has(id)) { used.set(id, d); visit(d.body); } } };
  for (const { items } of laws) for (const d of items) visit(d.header);
  const impl = cfg.symbols.map((s) => all.find((d) => d.name === s && d.file === cfg.impl)).filter(Boolean);
  for (const d of impl) visit(d.body);
  const assumptions = []; for (const { src } of sources) { const re = /^\s*\/\/ Assumption (A\d+): ([^\n]*(?:\n\s*\/\/ (?!Assumption )[^\n]*)*)/gm; let m; while ((m = re.exec(src))) assumptions.push([m[1], m[2].replace(/\n\s*\/\/ /g, " ")]); }

  // Gate 1: proof (pinned Dafny, included files verified).
  let verify = { ok: null, text: "not run (--no-verify)" };
  if (!opts.noVerify) {
    verify = { ok: true, text: "" };
    const doctor = sh(["/bin/bash", join(REPO, "tools/proof/bootstrap.sh"), "doctor"], REPO);
    if (doctor.code !== 0) verify = { ok: false, text: `pinned toolchain unavailable: ${doctor.out.trim()}; ` };
    else for (const f of cfg.verify) { let out; try { out = execFileSync(DAFNY, ["verify", "--verify-included-files", f], { cwd: root, env }).toString(); } catch (e) { out = (e.stdout ?? "").toString(); verify.ok = false; } verify.text += `${f}: ${(out.match(/Dafny program verifier finished[^\n]*/) ?? ["no verifier summary"])[0]}; `; }
  }
  // Gate 2: independent review, bound to the hash, the tier, the reviewer's own transcript and every accepted mutant.
  const reviewProblems = [];
  if (review) {
    if (review.packetHash !== hash) reviewProblems.push(`STALE (reviewed ${review.packetHash}, current ${hash})`);
    if (review.tier !== cfg.tier) reviewProblems.push(`reviewer did not confirm tier ${cfg.tier} (REVIEW.json tier: ${review.tier})`);
    if (!review.reviewer?.agent || review.reviewer.agent === review.writer?.agent) reviewProblems.push("reviewer agent missing or same as writer");
    // reviewer.session names the transcript below its project directory of the Pi session store
    // (<started-at>_<id>/.../session.jsonl), so committed reviews carry no machine path.
    const named = review.reviewer?.session;
    const found = typeof named === "string" && !named.startsWith("/") && !named.split("/").includes("..") && existsSync(SESSIONS)
      ? readdirSync(SESSIONS).map((d) => join(SESSIONS, d, named)).filter((f) => existsSync(f) && statSync(f).isFile()) : [];
    const t = found.length === 1 ? found[0] : null;
    if (!named || found.length === 0) reviewProblems.push("reviewer transcript (reviewer.session) missing: identity unverifiable");
    else if (found.length > 1) reviewProblems.push(`reviewer.session matches ${found.length} transcripts in the Pi session store`);
    else if (!readFileSync(t, "utf8").includes(hash)) reviewProblems.push("reviewer transcript never mentions the current block hash (it did not review this version)");
    else {
      const models = [...new Set([...readFileSync(t, "utf8").matchAll(/"provider":"([^"]+)","model":"([^"]+)"/g)].map((m) => `${m[1]}/${m[2]}`))];
      if (models.length !== 1 || models[0] !== review.reviewer.model) reviewProblems.push(`reviewer.model ${review.reviewer.model} does not match its transcript (${models.join(", ") || "no model"})`);
    }
    // Both tiers: a different model from the writer, so a tier downgrade buys no review shortcut.
    if (review.reviewer?.model === review.writer?.model) reviewProblems.push("reviewer model must differ from writer model");
    for (const id of Object.keys(cfg.accepted ?? {})) if (review.acceptedMutants?.[id] !== "AGREE") reviewProblems.push(`accepted mutant ${id} lacks the reviewer's AGREE`);
    for (const l of Object.keys(cfg.laws)) if (review.laws?.[l]?.verdict !== "ACCEPT") reviewProblems.push(`${l}: ${review.laws?.[l]?.verdict ?? "no verdict"}`);
  }
  const reviewOk = !!review && reviewProblems.length === 0;
  // Gate 3: mutation report for exactly these inputs.
  const ms = report?.summary; const mutFresh = ms?.inputsHash === hash;
  // --recheck: never trust gate files alone. Re-run a seeded sample of the report's mutants and the
  // whole shadow comparison; READY requires both to reproduce.
  let mutRecheck = null, shadowRecheck = null;
  if (opts.recheck && ms && mutFresh) { const r = sh([process.execPath, join(REPO, "tools/proof/mutate/mutate.mjs"), block, "--root", root, "--recheck", join(root, cfg.report), "--sample", "12", "--jobs", "2"], REPO); try { mutRecheck = JSON.parse(r.out.trim().split("\n").pop()); } catch { mutRecheck = { recheck: "error", why: r.out.slice(-200) }; } }
  // A recorded-traffic shadow is re-run over the same window of the (growing) corpus; a generated one exactly.
  if (opts.recheck && cfg.shadow && shadow) {
    const tmp = join(tmpdir(), `shadow-recheck-${process.pid}.json`);
    sh([process.execPath, join(REPO, "tools/proof/shadow/shadow.mjs"), block, "--root", root, "--out", tmp, ...(shadow.realTraffic ? ["--days", String(shadow.windowDays)] : [])], REPO);
    shadowRecheck = readJson(tmp); rmSync(tmp, { force: true });
  }
  // The report must come from the current checker (a semantics change re-runs every block).
  const toolNow = toolHash();
  const toolFresh = ms?.toolHash === toolNow;
  const reportOnly = (report?.results ?? []).filter((r) => r.accepted && !cfg.accepted?.[r.id]).map((r) => r.id);
  if (reportOnly.length) problems.push(`mutation report accepts mutants not in mutate.json accepted: ${reportOnly.join(", ")}`);
  const mutOk = reportOnly.length === 0 && ms?.pass === true && mutFresh && toolFresh && (!opts.recheck || mutRecheck?.recheck === "ok");
  // Gate 4: shadow for exactly these inputs; cut-over additionally needs real traffic over the tier's window.
  const windowNeed = cfg.tier === "high-stakes" ? 7 : 3;
  const shadowFresh = shadow?.inputsHash === hash;
  // The compiled core the shadow ran must be the one the current sources compile to (pinned toolchain).
  let coreHashNow = null;
  if (shadow && !opts.noVerify) {
    const work = mkdtempSync(join(tmpdir(), "tron-proof-packet-"));
    try {
      if (sh([DAFNY, "translate", "js", "--no-verify", "--include-runtime", cfg.translate, "-o", join(work, "core")], root).code === 0)
        coreHashNow = createHash("sha256").update(readFileSync(join(work, "core.js"))).digest("hex").slice(0, 16);
    } finally { rmSync(work, { recursive: true, force: true }); }
  }
  const shadowOk = shadow?.status === "match" && shadow.compared > 0 && shadow.mismatches === 0 && shadowFresh && shadow.coreJsHash === coreHashNow
    && (!opts.recheck || (shadowRecheck?.status === "match" && shadowRecheck.realTraffic === shadow.realTraffic
      && (shadow.realTraffic ? shadowRecheck.compared >= shadow.compared : shadowRecheck.compared === shadow.compared)));
  // Real traffic must also be current: its newest recorded day at most two days old.
  const recent = shadow?.corpus?.last !== undefined && Date.now() - Date.parse(`${shadow.corpus.last}T00:00:00Z`) <= 2 * 86_400_000 + 86_400_000;
  const realOk = shadowOk && shadow.realTraffic === true && shadow.windowDays >= windowNeed && recent;
  const ready = opts.recheck === true && verify.ok === true && reviewOk && mutOk && realOk;

  // A block its shell runs (block.json "shell") is the implementation: there is no TypeScript left to shadow.
  const cutOver = shell !== undefined;
  const tierRules = (cfg.tier === "high-stakes"
    ? "reviewer must be a different agent AND model than the writer; equivalent-mutant acceptances must be proven"
    : "reviewer must be a different agent than the writer; out-of-contract acceptances allowed with a reason")
    + (cutOver ? "" : `; real-traffic shadow 100% over >= ${windowNeed} days before cut-over`);
  const md = [];
  md.push(`# Law review packet: ${cfg.block}`, "", `Tier: **${cfg.tier}** (${tierRules}).`,
    `Block hash: \`${hash}\` (over ${sources.map((s) => `\`${s.f}\``).join(", ")} and the whole mutate.json). Generated by \`scripts/tron proof packet\`; do not edit.`, "",
    "| Gate | Status |", "|---|---|",
    `| Proof (pinned Dafny, --verify-included-files) | ${verify.ok === null ? verify.text : `${verify.ok ? "PASS" : "FAIL"}: ${verify.text}`} |`,
    `| Independent review | ${!review ? "MISSING" : reviewOk ? `ACCEPT by ${review.reviewer.agent} (${review.reviewer.model}, transcript-verified); writer ${review.writer.agent} (${review.writer.model}); ${review.date}` : `NOT ACCEPTED: ${reviewProblems.join("; ")}`} |`,
    `| Mutation check | ${!ms ? "MISSING" : `${!mutFresh ? `STALE (report for ${ms.inputsHash}) ` : ""}${!toolFresh ? "STALE (older mutation checker) " : ""}${ms.pass ? "PASS" : "FAIL"}${mutRecheck ? ` [recheck ${mutRecheck.recheck}: ${mutRecheck.sampled?.length ?? 0} sampled mutants re-run]` : ""}: ${ms.valid} valid mutants, ${ms.killed} killed by laws, ${ms.lawGap} law-gap, ${ms.survived} survived, ${ms.accepted} accepted (${cfg.report})`} |`,
    ...(cutOver ? [`| Cut over | the only implementation: \`${shell}\` runs this block's compiled core (scripts/tron proof facade) |`] : [
    `| Shadow | ${!shadow ? "MISSING" : `${!shadowFresh ? `STALE (run for ${shadow.inputsHash}) ` : ""}${shadow.status}: ${shadow.compared} ${shadow.unit ?? ""} compared, ${shadow.mismatches} mismatches; ${(opts.recheck ? shadowRecheck?.realTraffic : shadow.realTraffic) ? `real traffic, ${shadow.windowDays} days` : "lab traffic only"}; ${shadow.source ?? shadow.error}${coreHashNow === null ? "; compiled core not checked (--no-verify or translate failed)" : shadow.coreJsHash !== coreHashNow ? "; STALE: compiled core changed" : ""}${shadowRecheck ? ` [recheck: ${shadowRecheck.status}, ${shadowRecheck.compared} compared]` : ""}`} |`,
    `| **Ready for cut-over** | ${ready ? "**YES**" : `no${!opts.recheck ? " (READY is only computed with --recheck)" : ""}${shadowOk && !realOk ? ` (needs a current real-traffic shadow over >= ${windowNeed} days)` : ""}`} |`]), "");
  const per = (law) => report?.perLaw?.find((p) => p.law === law);
  for (const { law, items } of laws) {
    const [main, ...helpers] = items; if (!main) continue; const p = per(law), r = review?.laws?.[law];
    md.push(`## ${law}`, "", `**In plain English.** ${main.comment || "(MISSING)"}`, "", "```dafny", main.header, "```", "");
    if (helpers.length) md.push("Supporting lemmas (part of this law's proof; statements only):", "", ...helpers.flatMap((h) => [`- ${h.comment || h.name}`, "", "```dafny", h.header, "```", ""]));
    md.push(`**Mutation results.** ${p ? `kills ${p.killed} of ${ms.valid} valid mutants; ${p.only} killed by this law alone.${p.killed === 0 ? " Kills nothing here: implied by other laws or by the world model; the reviewer must say which." : ""}` : "no report"}`, "",
      `**Reviewer notes.** ${r ? `${r.verdict}: ${r.notes}` : "(not reviewed)"}`, "");
  }
  const helperDecls = [...helpers].map((h) => lemma(h)).filter(Boolean);
  if (helperDecls.length) md.push("## Proof helpers (statements only; not laws, but part of what is proven)", "", ...helperDecls.flatMap((h) => [`- ${h.comment || h.name}`, "", "```dafny", h.header, "```", ""]));
  md.push("## Law kinds", "", "| Kind | Laws |", "|---|---|", ...KINDS.map((k) => `| ${k} | ${Array.isArray(kinds[k]) ? kinds[k].join(", ") : kinds[k] ?? "(not stated)"} |`), "");
  if (assumptions.length) md.push("## World-model assumptions (requirements on the shell and stores; not proven here)", "", ...assumptions.map(([a, t]) => `- **${a}** ${t}`), "");
  md.push("## Implementation under test (compiled to JS; the laws constrain these)", "");
  for (const d of impl) md.push("```dafny", `${d.header} ${d.body}`.trim(), "```", "");
  if (used.size) { md.push("## Definitions the laws use", ""); for (const [id, x] of used) md.push(`**${id}**${x.comment ? `: ${x.comment}` : ""}`, "", "```dafny", `${x.header} ${x.body}`.trim(), "```", ""); }
  const notKilled = report?.results?.filter((r) => r.status !== "killed" && r.status !== "stillborn") ?? [];
  if (notKilled.length || Object.keys(cfg.accepted ?? {}).length) md.push("## Mutants not killed by a law (each needs the reviewer's AGREE)", "", "| Mutant | Change | Status | Reviewer |", "|---|---|---|---|", ...notKilled.map((r) => `| \`${r.id}\` | \`${r.from}\` -> \`${r.to}\` | ${r.accepted ?? r.status} | ${review?.acceptedMutants?.[r.id] ?? "-"} |`), "");
  if (review?.general) md.push("## Reviewer: general notes", "", review.general, "");
  if (problems.length) md.push("## Packet problems", "", ...problems.map((p) => `- ${p}`), "");
  return { md: md.join("\n"), hash, ready, problems };
}

const args = process.argv.slice(2);
const opts = { noVerify: args.includes("--no-verify"), recheck: args.includes("--recheck") };
const rootAt = args.indexOf("--root");
const root = resolve(rootAt >= 0 ? args[rootAt + 1] : join(REPO, "packages/core"));
const positional = args.filter((a, i) => !a.startsWith("--") && !(rootAt >= 0 && i === rootAt + 1));
if (args[0] === "--batch") {
  const out = positional[0]; const blocks = positional.slice(1); const parts = blocks.map((b) => packet(root, b, opts));
  writeFileSync(out, [`# Law review batch (${parts.length} blocks)`, "", "Read the English first; the Dafny is the exact statement that is proven.", "",
    "| Block | Hash | Ready |", "|---|---|---|", ...parts.map((p, i) => `| ${blocks[i]} | ${p.hash} | ${p.ready ? "YES" : "no"} |`), "", ...parts.map((p) => p.md)].join("\n\n---\n\n"));
  console.log(`wrote ${out}`);
  const bad = parts.filter((p) => p.problems.length); if (bad.length) { for (const p of bad) console.error(p.problems.join("\n")); process.exit(1); }
} else {
  if (positional.length !== 1) { console.error("usage: scripts/tron proof packet <block> [--root <dir>] [--write] [--no-verify] [--recheck] (tools/proof/README.md)"); process.exit(2); }
  const p = packet(root, positional[0], opts);
  const target = join(root, "blocks", positional[0], "LAWS.md");
  if (args.includes("--write")) { writeFileSync(target, `${p.md.trimEnd()}\n`); console.log(`wrote ${target} (hash ${p.hash}, ready ${p.ready})`); }
  else console.log(p.md.trimEnd());
  if (p.problems.length) { console.error(p.problems.join("\n")); process.exit(1); }
}
