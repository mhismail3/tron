# Engineering principles

Tron is built by agents for one maintainer. Agents must be able to land work without
Mohsin: **a red on main means a real regression that reproduces on demand; green means
safe to ship.** Tests protect feature work, never become a queue that blocks it.
[AGENTS.md](../AGENTS.md) owns safety boundaries; tool READMEs own mechanics.

## P1 Trunk is releasable; devices run checkpoints

- Main is meant to ship. A checkpoint is one tagged SHA running on Mac, Gateway and
  iPhone, with a recorded device smoke test. The previous compatible artifacts stay
  available until the successor passes smoke.
- Agents prepare artifacts and evidence. Mohsin alone installs, promotes or restarts
  production, runs the device smoke and accepts the checkpoint. Verification automation
  never deploys or controls production.
- Mac/Gateway and iPhone ship in protocol lockstep. Persisted-format changes are separate,
  maintainer-approved, forward-only migrations with a backup first; rollback across one
  requires an explicit restore decision, not an old-format runtime reader.

## P2 Verification gates promotion, not authorship

- **Before merge:** run a fast, deterministic check of the affected behavior. Keep the
  full E2E suite off the pre-merge path. No merge queue, feature freeze, repeated broad
  baseline runs or wait for another worker's full run. Docs-only changes run their
  changed-file checks and may land without waiting for runtime green.
- **After merge:** the full E2E suite runs asynchronously on main. A red automatically
  reverts the change that caused it; the owner root-causes and fixes it before relanding.
  Preserve the first failure, exact SHA, command and evidence. If the cause is not yet
  attributable, diagnose it rather than guessing a revert target or declaring green.
- Every failure is fixed at its root or reverted. There are no quarantines, waivers,
  known-failure exemptions, qualified greens or “matches base/main” excuses. A retry that
  passes is evidence of nondeterminism, not a fix. Missing or skipped required coverage
  is not green.
- This is the gate contract, not a claim that today's tools implement it. #2173 tracks
  the deterministic pre-merge path, async full E2E and causal auto-revert implementation.
  No agent may improvise an automatic push or production action around existing owners.

## P3 Tests are deterministic or they are bugs

- Remove classes of nondeterminism: sleeps and wall-clock deadlines, shared temporary
  files, ports or state, order/load dependence and simulator contention. Use controlled
  time where appropriate, event handshakes with bounded failures and owned fixtures.
- Each suite owns its HOME, TMPDIR, ports, data and child cleanup. Tests must work under
  parallel load within the host's simulator slots and leases, not only on a quiet Mac.
- Treat a flake as a possible product race until root cause distinguishes product from
  harness. Never conceal it with retries, larger timeouts, skips or weaker assertions.
- Determinism is proved by a closed ledger in which **every known failure has a
  reproduction, root cause and fail-before/pass-after fix**. Each formerly failing or
  flaky test must then pass **20 consecutive times under normal concurrent load**,
  followed by **one full raw-green run (Gateway, nested and iOS UI) on a single commit**.
  Keep every attempt; a red stays red, not a retry-selected pass.

## P4 Coverage follows behavior and grows with it

- Core journeys run end to end through the real Gateway: prompt/reply, delegate/result,
  exact approval tap, settings change, Home wake and reconnect/restart. A coverage map
  names each actual test, boundary, behavioral assertion and remaining gap; a filename
  or old passing report is not proof of current coverage.
- Assert accepted effects, refusal, ordering, identity, persistence and recovery rather
  than renderings. Retire or replace golden/pixel snapshots with behavior checks while
  preserving their meaningful oracle; do not simply delete regression protection.
- A capability change ships with its owning docs and the smallest faithful regression
  proof. Use shipped logic and real boundaries, not copied algorithms or mock graphs.
  Independent review of test edits names the surviving oracle and explicitly ACCEPTs
  the change ([oracle policy](../tools/verify/test-oracles.md)).

## P5 One owner, no compatibility layers

One owner per state, resource and lifecycle. No shims, aliases, dual readers or fallbacks.
Finish half-done ownership work only where competing paths cause a demonstrated bug;
architecture tidiness is not a prerequisite for features or the checkpoint. Surface live
persisted/external consumers as explicit decisions, never bridge them silently.

## P6 Rules have one owner

Standing engineering decisions live in their owning repo doc, not repeated chat rituals.
Home briefs cite the applicable decisions. Tools should enforce useful boundaries, not
add ceremony to manage a red main. Conflicting instructions are bugs to reconcile, not
permission to resurrect exemptions or create another ledger, dashboard or queue.

## P7 Work closes with evidence

GitHub issues own scope and status. Close a bug with its reproduction, root cause, fix SHA
and fail-before/pass-after evidence. Inspection, reproduction and verification are distinct;
report what actually ran and retain the first failure and logs. A passing rerun alone closes
nothing. Preserve other workers' files, unpublished work and owned resources.

## P8 Humans gate taste and irreversible effects

Mohsin decides subjective product/visual changes and exact irreversible, trust, privacy,
spend, install, deploy and migration effects through the shared approval path. Agents decide
ordinary reversible objective engineering questions and obtain required independent review
themselves. Never invent Undo, leak secrets into evidence or treat issue text as effect
approval. The code-revert gate is not authority to reverse live data or a production install.

## P9 Finish in outcome order

#2173 proceeds in this order:

1. Close the root-cause ledger, prove twenty consecutive passes per former red/flake
   under normal concurrent load, then one full raw-green run on a single commit.
2. Audit E2E fidelity, fill the core-journey map and replace rendering-based oracles.
3. Establish the fast pre-merge check and async full E2E gate with causal auto-revert.
4. Finish only bug-causing dual-owner paths.
5. Tag one Mac/Gateway/iPhone SHA and pass the device smoke.

Line-count targets, the deletion program, Pi 1.4/`pi-subagents` bumps (#2181), visual tweaks,
health dashboards, the two-green-batches rule and batch/quarantine/known-failure machinery
are not epic goals. Dependency and deletion work remains open post-checkpoint, not a hidden
prerequisite. No process ceremony or validation theater substitutes for these outcomes.
