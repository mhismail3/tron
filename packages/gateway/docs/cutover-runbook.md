# Tron integrations cutover runbook (operator-owned)

This is the one ordered operator runbook for the machine-internal, delegated,
Mac wizard, and integration-state cutovers. Owner docs linked below define
schemas and invariants; they do not provide alternate operator sequences.
Agents may prepare source/build artifacts and synthetic fixtures only. A user or
maintainer must perform quiescence, backup, publication, Gateway activation,
app replacement, and cleanup.

## 0. Approved source and prerequisites

Before a maintenance window, record the exact reviewed feature-branch commit
in the change record. Record the exact reviewed source commit for the cutover;
do not activate an older revision or an artifact built from another worktree.
The delegated integrity implementation requires the current marker schema and
focused regressions in `delegated-root-migration.test.ts`. Record the final value with:

```bash
git rev-parse HEAD
git status --short --branch
git diff main...HEAD --stat
```

Stop if `main...HEAD` contains unexpected changes or the worktree is dirty.
The prepared Gateway artifact must be built from that exact commit, with
`packages/gateway/package.json` version `0.1.0-beta.7`, Node `>=22.19.0`,
pinned Pi SDK packages `0.84.4`, and the installed delegated provider
`pi-subagents 0.59.0`. Run `cd packages/gateway && npm run check:pi-sdk && npm run build`;
record the resulting artifact digest and path. Do not patch installed
packages or use an artifact built from another commit.

The migration helpers are:

- machine identity/internal files: [`internal-workspace.md`](internal-workspace.md)
  and `scripts/tron internal-migrate`;
- delegated provider tree and references: this runbook and
  `scripts/tron delegated-migrate`;
- Mac agent-home/wizard state: the [Mac cutover runbook](../../mac-app/docs/agent-home-cutover.md);
- Knowledge/ConnectionOwner catalog: [`connections.md`](connections.md) and
  `scripts/tron connection-migrate`.

## 1. Read-only preflight and writer inventory

Resolve paths without expanding symlinks or guessing homes. The stable and
Debug homes are intentionally distinct for state, but the machine-group
identity is shared at each home’s approved internal path. Inventory all writers
before any stage operation: Stable Gateway, Debug Gateway, Mac wrapper and
wizard, iOS clients, browser/native adapters and profiles (external and not
copied), `pi-subagents` delegated runners, Automation scheduler/executor,
Knowledge connector workers, ConnectionOwner, session/runtime writers,
backup/sync tools, and any maintainer shell/editor touching these paths.
Keychain and other credential stores are external dependencies: verify their
availability and backup policy without exporting, reading, or copying secret
values.

Run every owner preflight in no-write mode against an isolated or explicitly
user-approved home. Include:

```bash
scripts/tron internal-migrate preflight --source <legacy-machine-id> --destination <tronHome>/internal/machine-group-id
scripts/tron delegated-migrate preflight --destination-root <tronHome>/internal/subagents --legacy-root <tmp-provider-root> [--legacy-root <project>]
scripts/tron connection-migrate preflight --tron-home <tronHome>
scripts/tron agent-home-preflight --source <old-agent-home> --destination <new-agent-home>
scripts/tron agent-home-cutover --status
```

The delegated inventory must account for every provider directory/file,
owner, mode, size/digest, absolute provider-root reference, terminal proof,
and retained resumable session reference. It must stop on active work,
missing resumable sessions, symlinks, path traversal, unsafe ownership or
permissions, collision, unknown/newer state, or an unproven reference. The
provider root is not a broad temporary-directory move; only the exact
provider-root shapes and explicitly listed project roots are admitted. Before
any source retirement, `verify`/`publish` re-inventories every source path and
separately checks the complete staged tree: source digests describe unchanged
bytes, while staged digests describe approved provider-reference rewrites.
Unlisted staged files/directories, changed modes/owners, removed or added
source paths, and parent substitutions are refused without a destination.

## 2. Quiesce and prove zero work

The user/maintainer stops new mobile prompts, Automation scheduling and
connector admission, then waits for accepted work to settle through its owner.
Use the supported delegated stop/control operation; never suspend a process
with `SIGSTOP`. Drain and verify both Stable and Debug independently. Confirm
no active session prompts, Gateway work, provider runs, workflow children,
Knowledge/connector effects, pending remote receipts, browser/native leases,
Mac wizard writes, package/resource reload, or iOS mutation receipt is in
flight. Re-run the read-only inventory and require zero active runs and stable
source revisions. A disconnected client is not proof of quiescence.

## 3. Protected backup (before first write)

The user/maintainer creates and verifies one consistent, protected backup of
all related stores: both Tron homes and internal files, Pi agent/session JSONL,
settings/packages/resources, Gateway state, Knowledge catalog SQLite plus WAL/
SHM and immutable records/objects, ConnectionOwner state, delegated trees and
retained references, Mac wizard record, Automation state, and the external
browser/native configuration needed for restoration. Include a manifest of
bytes, modes, owners, digests, and source revisions. Validate that the backup
can be read in an isolated restore fixture. Do not export or copy Keychain
secret values; record only the credential-store dependency and opaque refs.
Do not proceed without a protected backup and proven restoration of the
non-secret stores.

## 4. Stage, verify, and publish in order

Use a private same-filesystem staging directory and preserve each helper’s
journal. Commands below are exact only for the prepared helpers; replace
angle-bracket values with paths from preflight, and do not invent flags.

1. Stage/verify machine identity with quiescence and backup acknowledgements;
   check source/destination bytes, mode `0600`, owner, digest, and conflict
   marker. Publish only after verification.
2. Stage/verify delegated roots with
   `--acknowledge-quiescence --acknowledge-backup`. The helper preserves
   provider directory layout and terminal artifacts, rewrites only exact old
   provider-root references in provider artifacts, never canonical transcript
   JSONL, and records source/staged digests plus file and directory metadata.
   Run the exact focused owner regression before an operator cutover:

   ```bash
   cd packages/gateway
   PATH=/opt/homebrew/bin:$PATH npx vitest run src/sessions/delegated-root-migration.test.ts
   ```

   The connector pagination/cohort regression is also part of the pre-cutover
   evidence. Its 51-item case retains a full ten-item cohort, a partial head,
   and effect-before-response recovery; its 51-item all-partial case crosses
   the provider's 50-item API boundary and asserts page 1 discovery without a
   second full capture/assessment corpus. Test synchronization must observe
   provider admission and join accepted drain completion, not infer either
   from elapsed time or an intermediate persisted record. Run it without
   changing its per-test deadline or global worker/pool settings:

   ```bash
   cd packages/gateway
   PATH=/opt/homebrew/bin:$PATH npx vitest run src/knowledge/raindrop-intake-multipage.test.ts
   ```

   Publish retires each legacy root only after source and staging verification,
   then exposes `<tronHome>/internal/subagents`; verify the new root’s private
   permissions and that no old root remains writable. If publication stops
   after the journal enters `source-retired`, run `recover --staging <staging>`;
   recovery revalidates staged bytes, retained roots, and the published tree
   before completing or refusing the operation. Re-running `recover` after a
   verified publication is a no-op; it does not trust the journal as proof of
   bytes.
3. Stage/verify the Mac agent-home and versioned wizard-key record using its
   owner runbook. `.onboarded` remains completion authority; malformed/newer
   wizard data is not reset.
4. Prepare/stage/verify/publish the Knowledge catalog and ConnectionOwner
   authority through the production `TronWorkspace` and catalog-control paths.
   Preserve records, source counts, checkpoints, pending identities, cohorts,
   usage, receipts, pending remote effects, opaque refs, and account/scope
   policy. Current status must be read from the ConnectionOwner
   revision/observations; Knowledge progress is not a second admission
   authority. Run the focused readiness regression before an operator cutover:

   ```bash
   cd packages/gateway
   PATH=/opt/homebrew/bin:$PATH npx vitest run src/knowledge/multi-account-connectors.test.ts
   ```

   Do not publish a provider JSON sidecar or edit canonical evidence.

For every step, compare source and destination bytes/digests, permissions,
owners, identity, revision, receipts/request hashes, and journal phase. A
publication interruption must use that helper’s `recover` operation and marker;
never rerun a non-idempotent publication or choose an authority by timestamp.
There are no permanent dual writes, symlinks, broad fallbacks, or old-path
writers after publication.

## 5. Activation (manual user action only)

After all staged artifacts pass independent review, the user/maintainer
manually replaces/activates the approved Mac/Gateway artifact and iOS build in
the documented lockstep. Agents must not restart, rebuild, promote, replace,
or activate a Gateway or installed app. The iOS protocol models/fixtures and
Gateway protocol must be from the same approved source revision; reject mixed
wire revisions. Verify the running Gateway reports the recorded artifact
revision/digest before client use.

## 6. Post-cutover checks and observation window

Immediately verify, without secrets or broad scans:

- shared machine identity bytes are unchanged; Stable and Debug state remain
  separate;
- historical terminal delegated runs, retained resumable records, completion,
  admission, recovery, cancellation and cleanup work from the new provider
  root; private references point only to the new root;
- wizard progress survives relaunch and `.onboarded` remains authoritative;
- Knowledge source/record counts, catalog revisions, checkpoints, receipts,
  pending work and remote-effect uncertainty are unchanged;
- two same-provider connection accounts remain isolated through setup, reads,
  disable/reconnect and ambiguous receipts; MCP tools show only negotiated
  capabilities and stale policy is rejected;
- browser/native/external credential dependencies remain external; no secret
  or credential value appears in state, logs, DTOs or backups;
- no retired path is written, no unexpected provider root is discovered, and
  Gateway drain/reconnect/session history remain correct.

Observe for the agreed maintenance window with path/write monitoring and
repeat owner health, receipt, source-count, and private-permission checks.
Retain retired roots and journals through the observation window. Cleanup is a
separate manual decision after evidence is copied to the protected change
record and a fresh backup is available.

## 7. Rollback and GO/NO-GO

**Before the first publication write:** stop and clean only unconsumed staging
through the owning `cleanup` command, preserving the old authorities. A
preflight/staging conflict is an automatic NO-GO.

**After activation or any accepted write:** do not overwrite a newer authority
with an old snapshot, do not replay an uncertain effect, and do not run an old
binary against a new schema. Stop admission, preserve all new writes, use the
current helper’s recovery/forward repair path, and have the maintainer choose
a source/version-specific rollback that accounts for post-activation writes.
Restore the protected backup only when the owner contract proves no accepted
new work would be lost. Never create a permanent dual-write or fallback mode.

GO only when every item is true: exact approved commit/artifact recorded;
main divergence reviewed; all writers inventoried and quiesced; zero-work and
drain evidence is current; protected non-secret backup restores in isolation;
all preflights are no-write and clean; every staged manifest/permission/
receipt/reference check passes; journals recover deterministically; iOS/Gateway
wire versions match; post-cutover identity/history/count/receipt/account/MCP
checks pass; and observation monitoring is active.

NO-GO and stop immediately for active or retained-unresolvable work, unsafe
references, changed bytes, path/owner/mode conflict, destination collision,
missing/unknown receipts, unproven restoration, credential export request,
protocol mismatch, retired-path writes, or any result that is merely inferred
rather than verified. Manual-only actions remaining after this implementation
are protected backup, writer quiescence, migration publication, Gateway/app
activation, live-provider validation, observation, and cleanup.
