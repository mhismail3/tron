// Integration test for `scripts/tron proof mutate` and `scripts/tron proof packet` (tools/proof/README.md
// "Mutation" and "Packet"): the real CLIs with the pinned toolchain on a copy of the fixture block demo/clamp
// (tests/fixtures/mutate; test input, not a core block). One journey through the five gate cases:
// the real laws PASS (with six proven equivalences); a weakened law FAILS with a survivor; a false
// equivalence claim is REJECTED; a mutant only an unmapped helper catches is not a kill; a law proof that
// runs out of resources (fixture block demo/timeout) is unknown, never a kill; and the packet renders each
// law from the laws file and shows the review and the mutation report STALE after an impl or a law edit;
// and `proof shadow` records a match or mismatch only from a comparison that ran and agrees with its exit status.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const FIXTURES = join(ROOT, "tools/proof/tests/fixtures");
const ALWAYS_HI = "Clamp/branch/hi < x->true#1"; // returns hi for every x >= lo: only L2 (and its helper) catch it

test("mutation and packet gates fail for the right reasons", (t) => {
  const base = mkdtempSync(join(tmpdir(), "tron-proof-gates-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const root = join(base, "core");
  cpSync(join(FIXTURES, "mutate"), root, { recursive: true });
  const cli = (...args) => spawnSync(join(ROOT, "scripts/tron"), ["proof", ...args, "--root", root], { encoding: "utf8" });
  const mutate = (out, ...args) => {
    const block = args[0] === "demo/timeout" ? args.shift() : "demo/clamp";
    const run = cli("mutate", block, "--no-oracle", "--jobs", "2", "--out", out, ...args);
    const report = JSON.parse(readFileSync(out, "utf8"));
    return { status: run.status, summary: report.summary, byId: Object.fromEntries(report.results.map((r) => [r.id, r])) };
  };
  const variant = (name) => join(FIXTURES, "mutate-variants", name);

  // 1. Real laws: every valid mutant is killed by a law or proven equivalent.
  const real = mutate(join(root, "blocks/demo/clamp/mutation-report.json"));
  assert.equal(real.status, 0);
  assert.deepEqual([real.summary.pass, real.summary.valid, real.summary.killed, real.summary.accepted, real.summary.survived, real.summary.unknown], [true, 16, 10, 6, 0, 0]);
  for (const r of Object.values(real.byId).filter((x) => x.status !== "killed")) assert.match(r.accepted, /^equivalent \(proven\): /, r.id);
  assert.deepEqual(real.byId[ALWAYS_HI].killedBy, ["L2 inside"]);

  // 2. Weakened law: the mutant only L2 caught now survives, so the gate fails.
  const weak = mutate(join(base, "weak.json"), "--laws", variant("weak-L2.dfy"));
  assert.equal(weak.status, 1);
  assert.deepEqual([weak.summary.pass, weak.summary.survived, weak.byId[ALWAYS_HI].status], [false, 1, "survived"]);
  assert.match(weak.summary.inputsHash, /^override:/);

  // 3. False equivalence: claiming that survivor equivalent is checked, its proof fails, and it stays a survivor.
  const claimed = mutate(join(base, "false-equivalence.json"), "--laws", variant("weak-L2.dfy"), "--config", variant("false-equivalence.json"), "--only", ALWAYS_HI);
  assert.equal(claimed.status, 1);
  const rejected = claimed.byId[ALWAYS_HI];
  assert.deepEqual([rejected.status, rejected.accepted, claimed.summary.accepted], ["survived", undefined, 0]);
  assert.ok(rejected.acceptanceRejected.some((line) => /Equiv\.dfy\(\d+,\d+\): Error: a postcondition could not be proved/.test(line)), rejected.acceptanceRejected.join("\n"));

  // 4. Vacuous law: only the unmapped helper AtLow fails, which is never a kill.
  const vacuous = mutate(join(base, "vacuous.json"), "--laws", variant("vacuous-L2.dfy"), "--only", ALWAYS_HI);
  assert.equal(vacuous.status, 1);
  const unmapped = vacuous.byId[ALWAYS_HI];
  assert.deepEqual([unmapped.status, unmapped.killedBy, unmapped.unmapped, vacuous.summary.unknown], ["unmapped", [], ["Clamp.AtLow"], 1]);

  // 5. Timeout: mutants that change F(1) make T1's proof run out of resources; retried alone, still unknown.
  const timeout = mutate(join(base, "timeout.json"), "demo/timeout");
  assert.equal(timeout.status, 1);
  const unknown = Object.values(timeout.byId).filter((r) => r.status === "unknown-timeout");
  assert.deepEqual([timeout.summary.pass, timeout.summary.killed, timeout.summary.unknown, unknown.length], [false, 0, 5, 5]);
  for (const r of unknown) assert.deepEqual([r.killedBy, r.timeouts, r.retried], [[], 1, true], r.id);

  // 6. Packet: gate results are bound to the block hash; an edit makes the review and the report STALE.
  const packet = () => {
    const run = cli("packet", "demo/clamp");
    assert.equal(run.status, 0, run.stderr);
    const row = (gate) => run.stdout.split("\n").find((line) => line.startsWith(`| ${gate} |`));
    return { md: run.stdout, hash: /Block hash: `([0-9a-f]{16})`/.exec(run.stdout)[1], proof: row("Proof (pinned Dafny, --verify-included-files)"), review: row("Independent review"), mutation: row("Mutation check") };
  };
  const before = packet();
  // Each law is rendered from the laws file: its English and its bodiless statement, not the refining proof.
  assert.ok(before.md.includes([
    "## L2 inside", "", "**In plain English.** L2 inside: a value already inside [lo, hi] is returned unchanged.", "",
    "```dafny", "lemma L2Inside(lo: int, hi: int, x: int)", "  requires lo <= x <= hi", "  ensures Clamp(lo, hi, x) == x", "```",
  ].join("\n")), before.md);
  writeFileSync(join(root, "blocks/demo/clamp/REVIEW.json"), JSON.stringify({
    packetHash: before.hash, tier: "high-stakes", date: "2026-11-08",
    writer: { agent: "writer", model: "provider/writer-model" }, reviewer: { agent: "reviewer", model: "provider/reviewer-model" },
    laws: Object.fromEntries(["L1 in-range", "L2 inside", "L3 below", "L4 above"].map((law) => [law, { verdict: "ACCEPT", notes: "fixture" }])),
    acceptedMutants: Object.fromEntries(Object.values(real.byId).filter((r) => r.accepted).map((r) => [r.id, "AGREE"])),
  }));
  const reviewed = packet();
  assert.equal(reviewed.hash, before.hash);
  assert.match(reviewed.proof, /\| PASS: blocks\/demo\/clamp\/Block\.dfy: Dafny program verifier finished with \d+ verified, 0 errors/);
  assert.equal(reviewed.review, "| Independent review | NOT ACCEPTED: reviewer transcript (reviewer.session) missing: identity unverifiable |");
  assert.match(reviewed.mutation, /^\| Mutation check \| PASS: 16 valid mutants, 10 killed by laws, 0 law-gap, 0 survived, 6 accepted /);

  const block = join(root, "blocks/demo/clamp/Block.dfy");
  writeFileSync(block, readFileSync(block, "utf8").replace("// Definition and proofs", "// Definition and the proofs"));
  const edited = packet();
  assert.notEqual(edited.hash, before.hash);
  assert.match(edited.review, new RegExp(`NOT ACCEPTED: STALE \\(reviewed ${before.hash}, current ${edited.hash}\\)`));
  assert.match(edited.mutation, new RegExp(`^\\| Mutation check \\| STALE \\(report for ${before.hash}\\) PASS: `));

  // A law edit also changes the hash: the laws file is part of what every gate result is bound to.
  writeFileSync(block, readFileSync(block, "utf8").replace("// Definition and the proofs", "// Definition and proofs"));
  assert.equal(packet().hash, before.hash);
  const laws = join(root, "laws/demo/Clamp.dfy");
  writeFileSync(laws, readFileSync(laws, "utf8").replace("is returned unchanged.", "is returned as it is."));
  const lawEdited = packet();
  assert.notEqual(lawEdited.hash, before.hash);
  assert.match(lawEdited.review, new RegExp(`NOT ACCEPTED: STALE \\(reviewed ${before.hash}, current ${lawEdited.hash}\\)`));

  // 7. Shadow: the comparison's own exit status and output decide; a crash, garbage, nothing compared or an
  // exit status that contradicts the counts is an error, never a match, and the previous result is gone.
  const config = join(root, "blocks/demo/clamp/mutate.json");
  const shadowFile = join(root, "blocks/demo/clamp/SHADOW.json");
  const shadow = (mode) => {
    const cfg = JSON.parse(readFileSync(config, "utf8"));
    writeFileSync(config, JSON.stringify({ ...cfg, shadow: { cmd: ["node", variant("shadow-stub.mjs"), mode], source: "fixture" } }));
    const run = cli("shadow", "demo/clamp");
    return [run.status, JSON.parse(readFileSync(shadowFile, "utf8")).status];
  };
  assert.deepEqual(shadow("match"), [0, "match"]);
  assert.deepEqual(shadow("mismatch"), [1, "mismatch"]);
  for (const mode of ["crash", "garbage", "none", "lie"]) assert.deepEqual(shadow(mode), [1, "error"], mode);
});
