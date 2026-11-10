# Asynchronous full-main batches and causal revert

Pre-merge evidence is the fast [affected check](README.md). Full E2E coverage runs after landing,
asynchronously, through `verify --batch` in a persistent clean worktree on fetched main;
feature landings never wait for it ([P2](../../docs/PRINCIPLES.md#p2-whole-system-health-is-a-batch-signal-not-a-commit-gate)).
The trigger is a separate owner (Home's batch Automation); this owner never schedules,
installs, deploys or restarts anything. Every terminal run prints one JSON `batchResult`
line with head, report path and each repair's state and next step; the caller delivers it.

**Coverage.** First use needs `--base <main-anchor>`, not a claim of green.
`<git-common-dir>/verify/green.json` names the last raw-green head and is the next base;
`--base` cannot override it. Every run takes the nonwaiting repository `batch.lock` (held refuses,
exit 2). Every Gateway Vitest and Python run the batch starts runs on the Mac mini, never beside
its Apple chain here: the Gateway default/nested lanes and their case probes through `mini.py`, and
`verify --all` and the affected-check candidate with `--gateway-host mini` ([runner](README.md)); only
the groups that need this host, `mac-terminal` and `python-here`, run here. Each waits its turn for
the mini's job lock up to 45 minutes (`TRON_MINI_JOB_WAIT_SECONDS`), never interrupting the holder.
A lane the mini gives no result for (unreachable, off-pin, or still waiting at the cap) is uncovered
naming the mini's reason, never red or run here. During attribution or repair a no-result concludes
nothing: the attribution is unresolved for that batch only (not memoized) and a repair stays
`pending`, so both resume on the next batch. A
caller's `TRON_FULL_GATEWAY_LOCK_HELD` never reaches a lane, so a local Gateway run inside one
(the Mac Terminal group) queues for this host's lock itself.
Same green HEAD does nothing once its turn comes; `--repeat` reruns all nine lanes there. `--plan` is read-only. After pinned Gateway/relay dependency preparation every
required lane runs, even after failures: locks and every declaration (`verify --all`), full
default and nested Gateway Vitest (on the mini), signed Mac integration, relay Workers Vitest, unsigned
shipping iOS compile, UI smoke `checkpoint`, real-Gateway boundary and real-UI journeys
(installation disabled; Mac uses scratch HOME/TMPDIR). The lanes run as two concurrent chains, each
in plan order: **Node** (`verify --all`, Gateway default, nested, Mac integration, relay) and
**Apple** (compile, smoke, boundary, UI journeys under host slots); the console prints both
chains, each lane's live log and its result, and `report.json` keeps `results` in plan order
with `activeLane` naming every running lane. The Apple chain's simulator lanes run on their own
persistent named lane (`batch-apple-<hash of the git common directory>`, smoke products in this
worktree's own DerivedData), so they never contend with the verifier's iOS steps for this worktree's
lane lease. The repository owns that lane and its UI journey lanes (`TRON_IOS_TEST_LANE_REPOSITORY`),
so any worktree a batch runs in reuses the same warm simulators; they are reaped only with the
repository or after the idle TTL, never with a batch worktree. A chain that errors (for
example changed source) or an interrupt stops the other chain's running lane (a mini job waiting for
its lock or running ends with its session); both join before fixture cleanup,
freeze, attribution and verdict. iOS lanes release host slots between lanes; all slots held by other
work at admission is deferred, while a slot this batch's own worktree holds frees when its
lane ends, so the lane is admitted and waits for it. The UI journey lane runs its journeys on
three owned lanes (`TRON_IOS_E2E_UI_LANES=3`, one host slot each), longest first by the newest
earlier batch's per-journey seconds (`previous-journey-seconds.json` in the lane directory);
its attribution probe runs the one failed journey on one lane. **Green** means every lane executed and passed.
Missing owners/reports, empty/skipped/deferred evidence, a non-`passed` verifier verdict,
failed setup/cleanup or changed source is **uncovered**; any executed failure is **red**.
Neither advances `green.json`. Immutable `verify/batches/<range>/` keeps commands, logs,
counts and wall times. Each lane's `timing` in `report.json` is read-only observation
([`timing.py`](timing.py)), never a verdict input: start/end,
verifier step seconds, per-file Vitest wall seconds, `-showBuildTimingSummary` buckets, per-journey
wall seconds, and per-case and top-level activity seconds (idle waits counted) from each result
bundle the log names (`xcresulttool get test-results tests|activities`); an unreadable source is
listed under `errors`. On a red, `first-report.json` and the `evidence.json` hash manifest
freeze the first failure after every lane joined and before any probe runs.

**Attribution** probes one exact case (Vitest file plus `-t` anchoring the describe and test
titles joined with ` > `, as Vitest matches them; XCTest class/method;
or the owner's `--only-testing` selector) in one disposable worktree; it never reruns a suite.
A red lane with no such selector is uncovered and filed unresolved, naming the range by its commit and file counts (the full lists stay in `report.json`).
Main's first-parent chain is the landing history: an ordinary commit or a two-parent
integration is one unit; octopus history is unresolved. Proof requires two fresh failing
executions with the identical normalized signature at the head, a binary search proposal
(cached `verify/probes/` outcomes are hints only), then two fresh passes at the culprit's
first parent and two fresh identical failures at the culprit. Any mixed, unknown, setup,
empty or changed-signature execution is **unresolved**, except that an exact-case Vitest head
control selecting no tests is a broken selector: the batch errors (exit 2) naming the command. Unresolved, the red stays red and is
root-caused; nothing is guessed or reverted. `verify/attributions/` memoizes per range.

**Repair** (`verify/repairs/<culprit>.json`, one journal per landing, written before each
effect) fetches the remote main tip without touching FETCH_HEAD or tracking refs and
requires the culprit on its first-parent history. A changed tip must still fail twice
(passing twice is `stale`: no revert); an exact existing inverse is `already-reverted`.
An unreadable remote is `pending`; it and an interrupted `building` journal resume when a
later red batch re-attributes the same culprit, as does `publication-disabled` once enabled.
Migration paths or owners with `persistence`, `security` or `mac-installer` risk refuse.
`git revert --no-edit [-m 1]` builds the candidate on the tip; a conflict is preserved
unresolved. The candidate must pass the case twice and pass `verify --changed --base <tip>`,
and the frozen evidence hashes must still match; then a review request binds culprit, parent, tip, candidate tree, patch-id, recipe,
signature and evidence digest. **Publication is off by default** (`publication-disabled`:
local `revert/<culprit>` only). Enable it once per batch repository with
`git config tron.verify.revertRemote origin`; repairs then stop at `review-required`.
A non-author agent reviewer records ACCEPT or BLOCK against the exact `bindingDigest`:
`--review <culprit> --decision … --reviewer <id> --binding <digest>`. A wrong binding
records nothing; BLOCK is terminal. Evidence changed after binding refuses publication.
The reviewer identity is recorded, not authenticated: the caller must use a non-author agent. ACCEPT on a moved tip never publishes: it rebuilds and
reproves once at the new tip and asks for a fresh review. Otherwise the reviewed tree is
committed onto the tip (trailers `Tron-Auto-Revert`, `Tron-Review-Binding`, `Tron-Reviewer`),
journaled as `push-intent`, and pushed with plain non-force `git push <remote> <commit>:main`.
The push exit settles nothing: `ls-remote` plus fetched ancestry decides `published`, a
retryable unchanged remote, or `push-uncertain`. Every batch and review first reconciles
dispatched pushes, so a crash after remote acceptance never creates a second revert.
The red stays recorded; the landing's owner root-fixes and re-reviews before relanding.
Code reverts never undo migrations, data, installs or production effects.

Guarded issue writes journal before dispatch in `verify/issue-writes/`, keyed by lane and
normalized signature; later ranges and a published revert comment on the same issue.
Refused, uncertain or unfinished writes are reconciled, never replayed. Conflicts and
refused or interrupted resource cleanup preserve the probe worktree and `progress.json`.

## Verify

`scripts/tron test tooling tools/verify/tests/test-verify-batch.py` drives the shipped CLI with real
Git and a disposable bare remote: merge and fast-forward culprits reverted after a bound ACCEPT
then green; disabled publication, then enabled; innocent concurrent landing with stale-ACCEPT
rebind; uncertain push, crash after remote acceptance and an owner killed mid-repair (one
revert each); stale red; unreadable remote; migration and `security` owner boundaries; BLOCK;
conflict; an inverse that leaves the failure; failing affected checks; mutated frozen evidence;
mixed controls, suite-level errors, skipped/missing coverage and octopus history; Gateway lanes,
verifier and candidate runs only on a stand-in mini carrying the wait cap, and a mini without a
result leaving them uncovered; a stand-in
Vitest that matches `-t` like Vitest 5, a head probe selecting nothing (error, exit 2),
chains that each wait on the other's lane (only concurrent chains finish), the Apple chain's
own simulator lane beside the verifier's iOS steps, a red Node lane
beside a full Apple chain, UI journey lanes with the previous batch's seconds, a slot held by
this batch's own worktree, and interrupted cleanup preservation. The fixture runs the real `mini.py` with its job handed to a
stand-in mini host in the fixture checkout; the ssh hop and mini side are `test-mini.py`'s.
