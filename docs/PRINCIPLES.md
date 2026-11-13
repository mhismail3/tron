# Engineering principles

Tron is built by agents for one maintainer. Each rule below gives the evidence it rests on and
what enforces it; a rule with no enforcement is cut. Safety boundaries live in
[AGENTS.md](../AGENTS.md), and scope and status live in GitHub issues.

## P1 A module owns its code and its tests

**Rule.** The repository is a monorepo: code, tests and fixtures sit in the module that owns them
(its `*.module.json`). Tests reach other modules only through their public interfaces. A commit is
gated by the local tests of the modules it touches, plus the E2E journeys that prove any behaviour
it deletes.
**Evidence.** At def6e931c, 209 of 240 JS/TS test files imported another module (counting
`test-support`); 150 of 228 Gateway test files imported another module's internals; and 92 test
files (55,866 lines) booted the whole Gateway registry (#2316 baseline). Under that coupling the full
suite (about 16 minutes) became the gate, and load-sensitive reds blocked unrelated work: 21 flake
issues were open.
**Enforced by** `scripts/tron verify --changed`, which runs the changed modules' owned tests and those of
modules whose untyped code imports a changed file.
**Not yet enforced:** the public-interface rule and the deleted-behaviour E2E proof. The
boundary check in #2316 T2.9 adds them.

## P2 Whole-system health is a batch signal, not a commit gate

**Rule.** The full suite and the core E2E journeys (prompt/reply, delegate/result, approval tap,
settings change, Home wake, reconnect/restart; [map](../tools/verify/core-journeys.md)) run as a
batch on landed main and at device checkpoints. A red is filed against the module that owns it,
which fixes it at the root or reverts its change. A retry that passes is evidence of
nondeterminism, not a fix.
**Evidence.** The full canonical batch takes 45–55 minutes. Each journey's remaining gaps are
tracked as #2230–#2235.
**Enforced by** `scripts/tron verify --batch` and the checkpoint device smoke.

## P3 Clear owners, clean modules

**Rule (Mohsin, 2026-11-10).** Every Tron component and capability, core or feature, has one
clear owner module with a separated concern. Each change leaves the module it touches clean:
minimal for what it does, no dead code, no legacy or compatibility paths, no comments, and no unnecessary tests. Agents minimize, where possible, the code a
module needs per unit of functionality, and this applies the same way to a file, a module, a package or
the whole repository. Line counts may be reported as a signal, never as a target or a gate.
Code, tests, scripts and docs must trace to a named consumer, contract or journey.
Anything that cannot is deleted. A replacement deletes the path it replaces in the same change.
Tests default to fewer: agents read the code itself, so a test earns its place only by catching a
real behaviour fault at a boundary. A fix's proof strengthens the owning E2E/integration test, or adds
nothing when one already proves it; tests that restate code (structure locks, duplicate unit tests,
implementation snapshots) are retired. Loosening an assertion that guards real behaviour is never
allowed. Rendering needs a built-UI witness; accepted exception (#2332): `TronUILockTests` keeps only
whole-tree accessibility witnesses, with no rendered (pixel) witness. Other additions are a fix, a consolidation into one owner, or a type
change that deletes the runtime checks it replaces. No backward-compatibility code: no shims,
aliases, old-format or fallback readers, flags or "just in case" wrappers; live old data moves once
through a backed-up migration. Simplify by reusing and hardening existing primitives (approval
requests with log/Undo, the one generalized app UI, Home memory, inline display/artifacts), not
per-feature machinery. A deletion removes the machinery but keeps its process value: each kept
behaviour is listed and E2E-proven before the deletion lands. Never cut code by dropping a whole
capability; each capability's module stays clean, proven and self-contained.
**Evidence.** The #2297 structure program added custom governance tooling and ended at net +227
lines. Governance tooling alone was about 14,000 lines (#2316 §0). Tests reached about 127,000 lines:
fail-before/pass-after named no owner for the proof and only deleting a test needed evidence, so each
fix added a file. In the 60 days to 2026-11-08, 69 of 657 new test files sat beside a test sharing
their name prefix (17 the same stem), and 792 added product-source lines named legacy, compat or shim code (#2327).
**Enforced by** the Gateway compiler's `noUnusedLocals` setting for dead locals, and the `verify`
delta that reviewers ACCEPT against: each new test file beside an existing owner and each added
line naming compatibility code (its line counts are a signal only). **Not yet enforced:** the
unused-export and unused-file check (knip) is #2316 Phase 7; one owner per capability, reuse of existing primitives, kept-behaviour E2E proof before a deletion, and
whole-capability preservation rely on review.

## P4 Parity is proven, and a fix is never mixed into a refactor

**Rule.** A refactor changes no observable behaviour: wire output, persisted bytes, errors callers
match on, user-visible effects and their order. It leaves contract assertions untouched. A fix
changes behaviour on purpose; its fail-before/pass-after proof goes in the owning test, in the
same change. Commits are prefixed `test:`, `delete:`, `refactor:`, `fix(#n):`, `docs:` or `chore:`.
**Evidence.** #2279 converted four whole-trace locks into behaviour checks. Each conversion was
proven by injecting 8 mutants that failed both the old check and the new one.
**Enforced by** the wire goldens (`protocol-wire`, `client-event-schemas`), the persisted-format
goldens (`store-*`, `tron-corpus`, the pi-sdk corpus), and reviewer ACCEPT for any test or
assertion edit. **Not yet enforced:** commit prefixes and expected-fail regression tests
(#2316 Phase 7).

## P5 One owner per state; contracts change only by decision

**Rule.** Every state, resource and lifecycle has one owner that holds its transitions and
recovery, documented beside the code. Make invalid states unrepresentable rather than guarding
them. Wire protocol, RPC shapes, persisted `~/.tron` formats and user-visible features change
only through a maintainer decision. They ship in Mac, Gateway and iPhone lockstep, with
forward-only migrations that take a backup first.
**Evidence.** Fourteen *Likely* state-machine defects (#2316 F1–F14) sit where two owners or an
implicit boolean state meet.
**Enforced by** the protocol version check (`scripts/gateway_protocol_contract.py`) and the
Gateway refusing a mismatched client.

## P6 Tests are deterministic and own their resources

**Rule.** A test owns its HOME, TMPDIR, ports and children, and uses events or injected clocks
instead of sleeps. Each test run records its identity, commit/tree, outcome, duration and execution-host
CPU idle/free-memory reading in the external [test ledger](../tools/verify/README.md#test-ledger).
A test is flaky only when it both passes and fails on the same committed tree; an always-failing
test is broken. Mark known contention with `TRON_TEST_CONTENDED=1`: flake ranking excludes those
records, while verify and batch retain raw verdicts. Host readings inform that annotation;
concurrency or a load threshold does not classify it automatically. Use `scripts/tron flakes` to
triage same-tree evidence, preserve first failures and measure repeat counts before and after a fix.
A flake is its module's bug: it gets one timeboxed root-cause attempt, then shipped logging
that catches the next occurrence and a maintainer decision on deleting the case. Never delete it
without that approval. It never blocks another module.
**Evidence.** 21 flake issues were open at the baseline, mostly timeouts under host load. Test stop
paths that sent SIGKILL leaked `/tmp/tron-gateway-tests-*` roots; they now send SIGTERM first.
**Enforced by** the Gateway test isolation preflight (`tron-home-environment` guard), simulator
leases (`scripts/ios-test-lock.py`), and one issue per flake.

## P7 Humans gate taste and irreversible effects

**Rule.** Mohsin decides subjective design, and every irreversible, trust, privacy, spend,
install, deploy or migration effect, through one exact approval tap. Agents decide reversible
objective questions and obtain independent review themselves. Issue text grants no authority.
**Evidence.** #2297 found that `scripts/tron dev handoff` had no maintainer-only check; it now
refuses agent shells (44e5ed905).
**Enforced by** the shared change card (#2128), the maintainer-only `scripts/tron dev handoff`
(it refuses agent shells, exit 77), and Gateway channel-bound admin RPCs.
