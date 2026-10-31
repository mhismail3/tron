# Engineering principles

Tron is built by agent workers on one Mac for one maintainer. This file owns how a change
moves from a worker's branch to Mohsin's devices so features keep landing while what he runs
stays correct. [AGENTS.md](../AGENTS.md) keeps the safety boundaries and short binding rules;
tool READMEs own mechanics. A rule lives in one place; contradicting text elsewhere is a bug.
`Enforced by` names today's check, or the open issue that will add it.

**Outcomes:** escaped regressions (found on a device or by Mohsin), main-red duration (first
failure to the fix or revert landing), open quarantines (count, oldest age, owner) beside
uncovered-main age, request→main time, deploy lag and maintainer interruptions, each a `scripts/tron health`
field or reported unavailable. **Non-goals:** suite wall time, line
counts, a green-rate number. None of these is a quota.

## P1 Trunk is releasable; devices run checkpoints

- main is always meant to ship. Gateway/Mac, iPhone and relay are installed only from a
  checkpoint: a main SHA whose complete batch (P2: every lane, including the full Gateway
  suites) has no unqualified failure. Until the batch has those lanes, nothing is eligible.
- Agents prepare the checkpoint issue: SHA, batch report, every quarantined case, deploy lag,
  migrations, and the Mac payload, iPhone build and relay versions to install. Mohsin
  installs, runs the device smoke and tags `checkpoint-<date>`; agents never deploy.
- Mac/Gateway and iPhone move together (protocol lockstep). The previous checkpoint's payload
  and build are kept until the successor passes smoke. Rollback reinstalls them only when no
  persisted-format migration lies between; across a migration, rollback is restore-from-backup
  and Mohsin's decision.
- Enforced by: Mac install verification. Batch eligibility, the checkpoint issue and retained
  payloads: #2182 (`scripts/tron checkpoint` is today a Mac smoke, not this gate).

## P2 Verification gates promotion, not authorship

- **Pre-land, every worker, no coordination:** `scripts/tron verify` runs the affected checks.
  A selection whose simulator slot is unavailable is recorded as deferred to the batch, never
  as passed, and the worker may land. One classification rerun is allowed; it records a
  defect and never turns it green: a failure that passes on it is recorded as flaky (both attempts on its flake
  issue) and the worker lands; a reproducing failure is the worker's to fix. Workers never run
  full suites, paired/ABBA or whole-suite reruns. A review is repeated only when integration
  changes the reviewed diff against its base, resolves a conflict or changes a contract it
  relied on.
- **Post-land, one batch owner:** `verify --batch` covers each new main range, one batch at a
  time, coalescing commits that land while it runs. A complete batch runs every lane even
  after one fails: locks, the full default and nested Gateway suites, Mac and relay suites, iOS
  compile, smoke, real-Gateway boundary and UI journeys. A missing or skipped lane is uncovered, never green. Batch iOS
  lanes take host slots like any simulator job. A lane whose failures all match unexpired
  entries is covered but qualified: the covered head advances, and the record says qualified,
  never green. The first base is the first main SHA with no unqualified failure in any lane.
- **Trigger:** a durable Tron Automation starts or resumes the batch. Every batch result
  (green, qualified, red, uncovered) is reported to Home, which re-raises each unsettled red
  to its owner at every wake, and flags an uncovered range older than 12 h. Until that
  Automation is verified, Home starts a batch when a worker reports a landing and none is
  running, and again whenever a batch ends with main ahead of its covered head.
- **Red:** the batch reruns only the failing cases, at both range ends. A failure that does not
  reproduce at the head is a flake (P3): every attempt is kept, the lane is qualified, not
  green, and its flake issue gets a registry entry like any known red. A reproducing failure is
  bisected over main's first-parent chain, its integration history: landings keep the previous
  main as first parent ([Git/gh skill](../.agents/skills/tron-work/SKILL.md)); ranges with
  other shapes yield candidates, not culprits. A culprit is proven only when the same
  signature reproduces twice at it and never at its parent; otherwise attribution is
  inconclusive. A signature is attributed once; later batches reuse that proof and update its
  one issue per lane and signature. A proven culprit gets a prepared revert branch. The batch
  never pushes. Home names an owner within an hour and settles each red within a day:
  fix-forward, landing the revert as an ordinary reversible change, or a registered
  quarantine. Reverting a migration, or a capability already in an installed checkpoint, is
  Mohsin's decision.
- **Known reds:** a failure is qualified only by an exact case and failure-digest match
  with an unexpired registry entry (owner issue, at most 7 days). An open issue alone waives
  nothing; a changed signature is a new red. A case is renewed at most once across all its
  entries, on a fresh reproduction; after that only a fix or a revert settles it. A pre-land failure that reproduces with the same digest at
  the worker's base is a main red: the worker registers it and lands, adding no new failing
  case or signature. An expired entry never fails pre-land work: selections report it as an
  expired red. It stops Home from proposing a checkpoint until fixed; a checkpoint Mohsin
  requests anyway lists it, and his install is the acceptance.
- Enforced by: `tools/verify` (selection, registry digests, batch, bisection). Full-suite
  lanes, all-lane runs, case-only attribution and issue dedupe: #2174. Expiry and renewal
  semantics and deferred iOS selections: #2175, due before #2130's entry expires on
  2026-11-05 (today an expired entry fails every run). Trigger and staleness: #2176.

## P3 Tests are deterministic or they are bugs

- Time, scheduling and randomness are injected; waits are event handshakes with a bounded
  failure. No wall-clock assertion runs on a loaded host.
- Every suite process owns its HOME, TMPDIR, ports and data directories, so suites run in
  parallel with workers and each other, within the host's simulator slots and leases.
- A test that fails only under load is a test defect unless it reproduces a product race,
  which is then a product bug. Neither is fixed by retries, longer timeouts or skips.
- Performance is guarded by deterministic budgets (operation, sync and byte counts); timings go
  to a trend-tracked benchmark lane that never passes or fails.
- Enforced by: `tools/verify/gateway.py` isolation, oracle review; conversions: #2177.

## P4 Coverage follows behavior and grows with it

- Every user-visible capability names a surviving E2E or integration outcome, tested at the
  lowest boundary that faithfully observes it; unit tables only where they add signal
  ([oracle policy](../tools/verify/test-oracles.md)). A change that adds or changes a
  capability lands with that outcome in the same change.
- Suite time is handled by parallelism and capacity, never by deleting a surviving oracle.
- Enforced by: oracle review; capability map: #2142.

## P5 One owner, no compatibility layers

One owner per concept, state and lifecycle. Never add shims, aliases, dual readers or
fallbacks. An existing reader of live persisted or external data is surfaced as a decision
and stays, tracked by an issue, until a one-shot, forward-only, backup-first migration that
Mohsin approves; that migration change deletes it. Enforced by: review; the remaining dual
owners are epic children.

## P6 Rules live in the repo and are enforced by tools

- A rule that matters is a check or one short line in AGENTS.md or here; otherwise delete it.
- Home orchestrates and does not legislate in chat. A standing decision that binds code lives
  in its owning repo doc; briefs cite paths. Profile holds Mohsin's personal preferences, and
  Home copies the applicable ones into each brief.
- Enforced by: `scripts/check-agent-policy.sh`, `scripts/check-documentation-policy.py`;
  single-source checks: #2134; brief discipline: #2180.

## P7 Work state is durable and closed by evidence

- GitHub issues own engineering work state; an issue closes with commands and results.
- Obligations Mohsin takes on in Home conversation live in one typed ledger in canonical Home
  history: request, reported done, verified, reopened. One tied to an issue references it and
  closes with it; a summary can never reopen a closed item.
- Enforced by: `scripts/tron work`; Home's canonical `obligation` tool; joined feedback in health: #2178.

## P8 Humans gate only taste and irreversibility

Mohsin decides subjective visuals and product behavior (including retiring a user-visible
capability), and every irreversible, trust, privacy-expansion, spend, install, deploy or
data-migration effect, plus the P2 cases reserved for him. Other reversible objective
questions (landing, reverting, quarantining test defects, dependency bumps without a behavior
delta) are decided by automation or Home, never sent up. Creating a recurring unattended
Automation is his decision once (cadence, budget). Edits that change existing tests, goldens,
registry entries, selection rules or checks need a non-author reviewer's ACCEPT that the
worker obtains itself, with no queue; a main-red registration lands with its reproduction and
is ACCEPTed afterwards.

## P9 Small batches, regular checkpoints, self-updating dependencies

- Slices land small and often. Home proposes a checkpoint when a batch qualifies and
  user-visible change is pending, at most weekly unless Mohsin asks.
- Dependencies move through the same pipeline: an agent prepares bumps on a schedule; they
  land through P2 like any change. Every bump needs a non-author ACCEPT of its lockfile diff
  (new packages, install scripts, network or credential access); a red batch is settled the
  same way, and the checkpoint issue lists dependency changes. A Pi SDK or `pi-subagents`
  bump lands without Mohsin only when its
  [maintenance checks](../packages/gateway/docs/pi-sdk-maintenance.md) pass with zero golden
  or baseline diff and the non-author reviewer finds no unexplained or behavior-changing hunk
  in its candidate review; any behavior delta is his decision.
- Enforced by: Pi updaters; scheduled bumps: #2181.
