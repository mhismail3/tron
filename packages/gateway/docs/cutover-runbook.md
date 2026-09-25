# Tron integrations cutover runbook (operator-owned)

This is the one ordered operator runbook for the machine-internal, delegated,
Mac wizard-state, and integration-state cutovers. Owner docs linked below
define schemas and invariants; they do not provide alternate operator
sequences.
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
the Pi SDK packages pinned in `packages/gateway/package.json`, and the delegated
provider `pi-subagents` installed in the agent home. Run `cd packages/gateway && npm run check:pi-sdk && npm run build`;
record the resulting artifact digest and path. Do not patch installed
packages or use an artifact built from another commit.

The migration helpers are:

- delegated provider tree and references: this runbook and
  `scripts/tron delegated-migrate` (marker schema 3);
- Mac wizard state: the [Mac wizard-state cutover](../../mac-app/docs/wizard-state-cutover.md)
  and `scripts/tron wizard-migrate`.

## 1. Read-only preflight and writer inventory

Resolve paths without expanding symlinks or guessing homes. The Stable and
Debug homes are intentionally distinct for state, but the machine-group
identity is shared at the canonical `<userHome>/.tron/internal/machine-group-id`
path for both profiles. An explicit approved override remains authoritative.
Inventory all writers
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
scripts/tron delegated-migrate preflight --destination-root <tronHome>/internal/subagents --legacy-root <tmp-provider-root>
```

The delegated inventory must account for every provider directory/file,
owner, mode, size/digest, absolute provider-root reference, terminal proof,
and retained resumable session reference. It must stop on active work,
missing resumable sessions, symlinks, path traversal, unsafe ownership or
permissions, collision, unknown/newer state, or an unproven reference.
The pinned provider created legacy directories/files with its process umask
(often 0755/0644). Schema 3 admits owner-controlled sources with no group/other
write access, while preserving exact source modes/digests in the journal and
publishing a private copy (owner bits only). It never chmods the source. Links,
foreign owners, special modes, and writable-by-others paths still refuse. The
512 MiB temporary-tree bound remains unchanged; project history size is not
part of that bound. The provider temporary store is the pinned package's exact
`<tmpdir>/pi-subagents-uid-<uid>` root (or an explicitly configured provider
root). Never scan all `pi-subagents-*` directories: tests and retired copies
are not active provider authorities. Project `.pi/subagents` and session
`subagent-artifacts` remain provider-configured history destinations, are
included in the backup/reference inventory, and are not moved by a temporary
root cutover. Moving them would strand references and the provider would
recreate their original locations. Before
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

Use the operation ID created by the app-preparation checkpoint in step 4.1 to
prepare a private `~/.tron-maintenance/pre-cutover-<operation-id>/` staging root,
with backup and restore evidence under `pre-migration/`. Once the maintenance
operation is verified and finished, the archive-only recovery command registers
and moves the complete staging root to `<operation-id>/pre-cutover/` in the same
store. Original journals retain historical paths; current archive verification
does not use them to inspect live state or depend on the former location.
Do not create another backup root in a checkout, Workspace or Downloads. This
pre-write checkpoint remains separately owned and verified; it is not one of the
reinstall helper's post-write `backups/` components. Follow the
[local recovery location and retention contract](../../mac-app/docs/development.md#local-recovery-location-and-retention).
Keep original historical journals unchanged during relocation; archive-only
registration preserves their observed paths while verification resolves all
current paths relative to the registered operation root. It does not authorize
another migration or a source-state rewrite.

The user/maintainer creates and verifies one consistent, protected backup of
all related stores: both Tron homes and internal files, Pi agent/session JSONL,
settings/packages/resources, Gateway state, Knowledge catalog SQLite plus WAL/
SHM and immutable records/objects, ConnectionOwner state, delegated trees and
retained references, Mac wizard record, Automation state, and the external
browser/native configuration needed for restoration. Include a manifest of
bytes, modes, owners, digests, and source revisions. Validate that the backup
can be read in an isolated restore fixture. Do not export or copy Keychain
secret values; record only the credential-store dependency and opaque refs.
On macOS, preserve the observed source `com.apple.provenance` in the manifest,
but allow the OS to assign copies their own attribution as documented by the
[reinstall copy contract](../../mac-app/docs/development.md). Do not remove or
forge it. File bytes, owners, modes (including links), ACLs and all other xattrs
must match; live-source inventories stay exact. Stable-channel retirement also
admits OS-reassigned provenance on the renamed root directory only, while
retaining the original inventory and checking every nested entry exactly.
Do not proceed without a protected backup and proven restoration of the
non-secret stores.

## 4. Stage, verify, and publish in order

This is one coordinated maintenance window, not one command. The Mac reinstall
helper has a deliberate checkpoint contract: `--confirm-offline` freezes its
own source manifests and protected app/state backup, and any later data change
is refused as `source-changed`/`state-inventory-changed`. Since these migrations
intentionally change state, never run `--confirm-offline` before migration
publication and then resume migrations. Do the following in this exact order:

1. Prepare the signed app checkpoint only (this validates and records the
   candidate; it does not take the offline snapshot):

   ```bash
   scripts/tron mac reinstall --app <prepared-Release.app>
   ```

2. Using the old installed wrapper, retire the native helper through
   **Permissions… → Disable Helper for Update**, then choose **Pause Tron** and
   quit. Stop Debug, mobile clients, workers, schedulers, package operations,
   and every other writer. Do not replace or launch the new app yet.
3. Run every read-only owner preflight, create and verify the protected backup,
   then stage, verify, and publish the migrations below while all writers remain
   stopped. Use private same-filesystem staging directories and preserve each
   helper’s journal. Commands are exact; replace angle-bracket values only with
   paths from preflight.
4. After **all** migration publications and their exact post-publication checks
   succeed, the maintainer selects the approved bundled payload while still
   offline, before the reinstall snapshot:

   ```bash
   scripts/tron mac reinstall --select-bundled-offline
   ```

   This explicit operation attests to the same retirement/quiescence boundary,
   revalidates the prepared and installed app identities, and atomically retires
   the entire Stable channel store into the existing maintenance operation.
   Current, previous, pending-attempt state and payloads remain together as
   protected rollback evidence. No Gateway is started and no pointer is edited.
   A missing channel makes the existing signed launcher select the app bundle.
   An interrupted operation is resumed with this same command; journal and
   full tree evidence must match. It never automatically restores old code.
   If any source changes or reappears, stop; do not delete it to get a passing
   checkpoint. Existing active profiles must remain stopped throughout.
5. Then freeze the Mac reinstall operation exactly once:

   ```bash
   scripts/tron mac reinstall --confirm-offline
   ```

   Do not rerun this as a migration checkpoint or use it between publications.
   If it stops, preserve the maintenance operation and migration journals; do
   not rewrite a receipt or continue with an unproven order. Only then may the
   user replace/launch the app and choose Resume as described in Section 5.

Stage/verify delegated roots with
`--acknowledge-quiescence --acknowledge-backup`. The helper preserves provider
directory layout and terminal artifacts, rewrites only exact old provider-root
references in provider artifacts, never canonical transcript JSONL, and records
source/staged digests plus file and directory metadata. Journals use the same
64 MiB read/write bound as migration files; directory-heavy inventories can
legitimately exceed 256 KiB. A completed stage must pass `verify` before any
source is retired. The exact commands are:

```bash
scripts/tron delegated-migrate stage \
  --destination-root <stable-tron-home>/internal/subagents \
  --legacy-root <legacy-provider-root> \
  --staging <private-delegated-staging> \
  --acknowledge-quiescence --acknowledge-backup
scripts/tron delegated-migrate verify --destination-root <stable-tron-home>/internal/subagents --staging <private-delegated-staging>
scripts/tron delegated-migrate publish --destination-root <stable-tron-home>/internal/subagents --staging <private-delegated-staging>
```

Include one `--legacy-root` for every admitted legacy root reported by
preflight. Run the exact focused owner regression before an operator cutover:

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
   after the journal enters `source-retired`, run `recover --destination-root <tronHome>/internal/subagents --staging <staging>`;
   recovery revalidates staged bytes, retained roots, and the published tree
   before completing or refusing the operation. Re-running `recover` after a
   verified publication is a no-op; it does not trust the journal as proof of
   bytes.
Stage/verify/publish the Mac wizard-state record with the exact commands in
[Mac wizard-state cutover](../../mac-app/docs/wizard-state-cutover.md). Use an
explicit Stable/Debug profile and home; the helper reads only
`tron.mac.wizardStep` through `/usr/bin/defaults`, refuses malformed/newer
data, conflicts, unsafe paths and links, and retains private rollback
evidence. `.onboarded` remains completion authority and is never changed. If
publication is interrupted, `verify` must refuse the ambiguous destination; use
the owner’s explicit `recover --staging <staging>` only after its digest/source
proof passes.

For every step, compare source and destination bytes/digests, permissions,
owners, identity, revision, receipts/request hashes, and journal phase. A
publication interruption must use that helper’s `recover` operation and marker;
never rerun a non-idempotent publication or choose an authority by timestamp.
There are no permanent dual writes, symlinks, broad fallbacks, or old-path
writers after publication.

## 5. Activation (manual user action only)

After all staged artifacts pass independent review and the Mac
`--confirm-offline` checkpoint succeeds, the user/maintainer manually replaces
and launches the approved Mac app, chooses **Resume Tron**, and only then
performs any separately approved Gateway/iOS activation in documented lockstep.
Agents must not restart, rebuild, promote, replace, or activate a Gateway or
installed app. The iOS protocol models/fixtures and Gateway protocol must be
from the same approved source revision; reject mixed wire revisions.

App replacement alone does **not** select a new Gateway payload. Use the
explicit offline selection step above **before the reinstall snapshot**. The bundled payload
is used only when no admissible external selection remains under the documented
launcher contract. A stale external payload with the same protocol can override
the new bundle; do not infer an upgrade from app replacement.

The existing `gateway-payload-deploy.mjs promote` operation performs an
authenticated drain/restart against a running Gateway. It is **not an offline
selection command** and must not be inserted between Pause and Resume. Only
`mac reinstall --select-bundled-offline` owns offline bundle selection. This
operation is refused after the reinstall snapshot starts. Preserve its
`stable-selection.json` manifest and `retired-stable-payloads` directory with
the pre-migration backup; rollback across a migration is an explicit maintainer
decision, not pending-attempt recovery or an automatic older-payload launch.

After Resume, run `scripts/tron mac verify --require-bundled` and require `system.info` to report
the reviewed revision, payload fingerprint, protocol, and app/runtime identity.
Stop on any mismatch; do not repair it with a source-only rebuild or an
unreviewed pointer edit.

## 6. Post-cutover checks and observation window

Immediately verify, without secrets or broad scans:

- shared machine identity bytes are unchanged; Stable and Debug state remain
  separate;
- historical terminal delegated runs, retained resumable records, completion,
  admission, recovery, cancellation and cleanup work from the new provider
  root; private references point only to the new root;
- the published wizard record is consumed by `WizardState`, wizard progress
  survives relaunch with cold-resume clamping, and `.onboarded` remains
  authoritative;
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
