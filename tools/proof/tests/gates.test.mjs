import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const FIXTURES = join(ROOT, "tools/proof/tests/fixtures");
const ALWAYS_HI = "Clamp/branch/hi < x->true#1";

test("mutation and packet gates fail for the right reasons", (t) => {
  const base = mkdtempSync(join(tmpdir(), "tron-proof-gates-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const root = join(base, "core");
  cpSync(join(FIXTURES, "mutate"), root, { recursive: true });
  const cli = (...args) => spawnSync(join(ROOT, "scripts/tron"), ["proof", ...args, "--root", root], { encoding: "utf8" });
  const mutate = (out, ...args) => {
    const block = args[0] === "demo/timeout" ? args.shift() : "demo/clamp";
    const run = cli("mutate", block, "--jobs", "2", "--out", out, ...args);
    const report = JSON.parse(readFileSync(out, "utf8"));
    return { status: run.status, summary: report.summary, byId: Object.fromEntries(report.results.map((r) => [r.id, r])) };
  };
  const variant = (name) => join(FIXTURES, "mutate-variants", name);

  const real = mutate(join(root, "blocks/demo/clamp/mutation-report.json"));
  assert.equal(real.status, 0);
  assert.deepEqual([real.summary.pass, real.summary.valid, real.summary.killed, real.summary.accepted, real.summary.survived, real.summary.unknown], [true, 16, 10, 6, 0, 0]);
  for (const r of Object.values(real.byId).filter((x) => x.status !== "killed")) assert.match(r.accepted, /^equivalent \(proven\): /, r.id);
  assert.deepEqual(real.byId[ALWAYS_HI].killedBy, ["L2 inside"]);

  const weak = mutate(join(base, "weak.json"), "--laws", variant("weak-L2.dfy"));
  assert.equal(weak.status, 1);
  assert.deepEqual([weak.summary.pass, weak.summary.survived, weak.byId[ALWAYS_HI].status], [false, 1, "survived"]);
  assert.match(weak.summary.inputsHash, /^override:/);

  const claimed = mutate(join(base, "false-equivalence.json"), "--laws", variant("weak-L2.dfy"), "--config", variant("false-equivalence.json"), "--only", ALWAYS_HI);
  assert.equal(claimed.status, 1);
  const rejected = claimed.byId[ALWAYS_HI];
  assert.deepEqual([rejected.status, rejected.accepted, claimed.summary.accepted], ["survived", undefined, 0]);
  assert.ok(rejected.acceptanceRejected.some((line) => /Equiv\.dfy\(\d+,\d+\): Error: a postcondition could not be proved/.test(line)), rejected.acceptanceRejected.join("\n"));

  const vacuous = mutate(join(base, "vacuous.json"), "--laws", variant("vacuous-L2.dfy"), "--only", ALWAYS_HI);
  assert.equal(vacuous.status, 1);
  const unmapped = vacuous.byId[ALWAYS_HI];
  assert.deepEqual([unmapped.status, unmapped.killedBy, unmapped.unmapped, vacuous.summary.unknown], ["unmapped", [], ["Clamp.AtLow"], 1]);

  const timeout = mutate(join(base, "timeout.json"), "demo/timeout");
  assert.equal(timeout.status, 1);
  const unknown = Object.values(timeout.byId).filter((r) => r.status === "unknown-timeout");
  assert.deepEqual([timeout.summary.pass, timeout.summary.killed, timeout.summary.unknown, unknown.length], [false, 0, 5, 5]);
  for (const r of unknown) assert.deepEqual([r.killedBy, r.timeouts, r.retried], [[], 1, true], r.id);

  const packet = () => {
    const run = cli("packet", "demo/clamp");
    assert.equal(run.status, 0, run.stderr);
    const row = (gate) => run.stdout.split("\n").find((line) => line.startsWith(`| ${gate} |`));
    return { md: run.stdout, hash: /Block hash: `([0-9a-f]{16})`/.exec(run.stdout)[1], proof: row("Proof (pinned Dafny, --verify-included-files)"), review: row("Independent review"), mutation: row("Mutation check") };
  };
  const before = packet();
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
  assert.match(reviewed.mutation, /^\| Mutation check \| PASS: 16 valid mutants, 10 killed by laws, 0 survived, 6 accepted /);

  const block = join(root, "blocks/demo/clamp/Block.dfy");
  writeFileSync(block, readFileSync(block, "utf8").replace("// Definition and proofs", "// Definition and the proofs"));
  const edited = packet();
  assert.notEqual(edited.hash, before.hash);
  assert.match(edited.review, new RegExp(`NOT ACCEPTED: STALE \\(reviewed ${before.hash}, current ${edited.hash}\\)`));
  assert.match(edited.mutation, new RegExp(`^\\| Mutation check \\| STALE \\(report for ${before.hash}\\) PASS: `));

  writeFileSync(block, readFileSync(block, "utf8").replace("// Definition and the proofs", "// Definition and proofs"));
  assert.equal(packet().hash, before.hash);
  const laws = join(root, "laws/demo/Clamp.dfy");
  writeFileSync(laws, readFileSync(laws, "utf8").replace("is returned unchanged.", "is returned as it is."));
  const lawEdited = packet();
  assert.notEqual(lawEdited.hash, before.hash);
  assert.match(lawEdited.review, new RegExp(`NOT ACCEPTED: STALE \\(reviewed ${before.hash}, current ${lawEdited.hash}\\)`));
});
