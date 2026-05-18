# Resource Materialization And Enforcement Checkpoint

## Phase Boundary

This checkpoint implements **Resource Materialization and Enforcement**.

The secure substrate has engine-owned grants, typed resources, resource wrappers,
clean storage generation reset, and historical audit observations. This phase
closes the output gap: covered durable output paths must produce resource refs
through canonical capabilities or be rejected before execution.

This is still not the iOS control plane or generated UI phase. Those surfaces
depend on trustworthy resource lineage, materialization, and enforcement first.

## First Principles

- Durable output is a resource version, not an incidental file, transcript,
  process side effect, or in-memory return blob.
- Filesystem writes are scratch until a capability materializes them into a
  `materialized_file` resource or updates a typed artifact resource.
- Agents and workers do not decide whether output is worth keeping by writing
  directly into durable storage. They propose, update, link, promote, discard,
  or materialize resources under grants.
- The engine enforces output contracts at invocation prepare/finish boundaries.
  Handlers should not be trusted to self-report correctness after the fact.
- Enforcement must be deny-by-default for new paths. Existing audited paths get
  converted module by module until the audit count reaches zero, then the audit
  mode is removed.
- There is no compatibility reader, fallback route, alias, or silent coercion
  for retired output shapes.

## Target Outcome

This phase establishes:

- `filesystem::*`, `process::*`, `program::*`, and `agent::*` durable-output
  paths either return resource refs or fail with a policy error.
- `materialized_file` is a registered first-party resource kind with explicit
  read/write/promote/delete/materialize capabilities.
- Program output and agent final outputs are stored as typed resources with
  lineage to the invocation, goal, worker, and grant that produced them.
- Output contracts are declared in capability metadata and enforced by the
  engine, not by convention in handlers.
- The output audit path is retained only as read-only conversion telemetry; it is
  not an acceptance path for converted filesystem/process/program/agent outputs.

## Workstream 1: Resource Type And Contract Hardening

Completed first-party resource definitions:

- `materialized_file`: durable file bytes or path-backed file record with hash,
  size, MIME/type hint, workspace root, relative path, owner invocation, and
  retention policy.
- `patch_proposal`: structured patch/diff intent with base resource/version,
  target materialization, validation status, and merge result.
- `execution_output`: normalized process/program stdout/stderr/log preview,
  exit status, resource refs, and redaction policy.
- `agent_result`: final answer, decision refs, promoted resources, open claims,
  and follow-up subgoal refs.

Contract rules now enforced:

- Every mutating capability declares produced resource kinds or explicitly
  declares `producesDurableOutput = false`.
- Every durable-output capability declares materialization rules, retention, and
  redaction.
- Resource create/update validates payload schema before persistence.
- Resource version bytes are content-addressed and hash-verified.
- Delete/discard is lifecycle-first; byte deletion only happens after retention
  proves no live references.

Tests/gates:

- Invalid resource payloads fail before persistence.
- A resource version cannot point to missing bytes without being marked damaged.
- Resource kind definitions cannot omit lifecycle/versioning/link rules.
- Mutating capability registration fails without an output contract.

## Workstream 2: Materialization Capabilities

Canonical capabilities:

- `artifact::materialize`
- `materialized_file::create`
- `materialized_file::read`
- `materialized_file::update`
- `materialized_file::promote`
- `materialized_file::discard`
- `materialized_file::inspect`
- `materialized_file::hash_verify`
- `patch::propose`
- `patch::apply`
- `patch::merge`

Rules:

- Materialization must require a grant selector for the target resource and file
  root.
- Writes outside allowed file roots are rejected before execution.
- Materialized paths are workspace-relative where possible; absolute paths are
  allowed only when the grant explicitly permits that root.
- Hash, size, and content owner are recorded before a version becomes current.
- Partial writes are quarantined and inspectable; prior current versions remain
  current.

Tests/gates:

- File materialization outside grant roots fails.
- Concurrent materialization uses CAS or a lease.
- Hash mismatch marks the version damaged and does not promote it.
- Discard does not delete shared bytes still referenced by another resource.

## Workstream 3: Convert Filesystem And Process Paths

Filesystem:

- Convert write/patch/create operations to produce `materialized_file` refs;
  patch operations also produce `patch_proposal` refs.
- Keep direct file reads as read-only capabilities, with optional resource
  hydration when the caller needs a durable reference.
- Remove any durable write path that bypasses resource version registration.

Process:

- Require write-like process commands to use `executionMode =
  "sandbox_materialized"` and declare expected output resources.
- Capture stdout/stderr/log previews as `execution_output` resources when they
  are retained beyond the invocation result.
- Commands that mutate the workspace without declared materialization fail
  before execution.
- Read-only command classifier remains strict and test-covered.

Tests first:

- `filesystem::write_file` returns resource refs and creates a version.
- `filesystem::patch` creates a patch proposal or materialized version.
- Write-like `process::run` without output contract fails.
- Read-only `git status/log/diff/show` remains allowed under read grants.

## Workstream 4: Convert Program And Agent Outputs

Program worker:

- Reject loose `artifacts` output and require resource refs.
- Store retained stdout/stderr/log previews as `execution_output` resources.
- Enforce output byte limits before resource version creation.
- Link child capability outputs to the parent program invocation.

Agent runtime:

- Completed prompt runs emit `agent_result` resources.
- Goal-bound decision linking remains the next coordinator concern because this
  phase intentionally does not introduce a new `agent::run_goal` coordinator.
- Subagent outputs should attach to the goal as `claim`, `evidence`,
  `artifact`, or `decision` resources in the coordinator phase.
- Final chat text is a projection over resources and invocation state, not the
  durable source of truth.

Tests first:

- Program artifact without resource refs fails after conversion.
- Agent final output without promoted resource refs fails after conversion.
- Context overflow uses resource summaries/refs, not full bodies.
- Child outputs remain trace-linked after worker crash or disconnect.

## Workstream 5: Enforcement Switch And Audit Removal

Conversion sequence:

1. Keep audit observations readable while adding resource-backed paths.
2. Add per-namespace enforcement through contracts and static gates.
3. Convert one namespace at a time and update tests to expect policy failures.
4. Remove audit-only acceptance branches after covered paths enforce resources.
5. Keep any audit schema read-only if historical records still matter.

Static gates:

- No mutating capability without `producedResourceKinds` or explicit
  non-durable contract.
- No filesystem write helper reachable without resource registration.
- No process write-like command without output resource contract.
- No program result `artifacts` array.
- No completed agent run without an `agent_result` resource ref.
- No output-audit-only acceptance path for converted durable-output paths.

## Workstream 6: Security And Abuse Cases

Threats to test explicitly:

- Prompt-injected worker asks for broader resource selectors.
- Child worker attempts to materialize outside its file roots.
- Process command writes through shell redirection or tool-specific flags.
- Resource payload contains secrets that should be `secret_ref`.
- Symlink or path traversal escapes the allowed root.
- Concurrent workers race to update the same artifact.
- Worker crashes after writing bytes but before registering a version.
- Blob exists without live resource owner.
- Resource exists with missing blob bytes.
- Malicious generated patch edits grant/policy files without approval.

Required behavior:

- Reject broader grants before handler execution.
- Canonicalize paths before policy checks.
- Treat symlinks as resolved target paths for grant enforcement.
- Quarantine partial outputs.
- Record damaged resources rather than silently repairing truth.
- Require approval for high-risk materialization or policy/config file writes.

## Verification

Targeted tests first:

- Grant-rooted materialization tests.
- Filesystem write/patch resource tests.
- Process write-like enforcement tests.
- Program artifact resource tests.
- Agent decision/promoted-resource tests.
- Crash/quarantine/damaged-resource tests.
- Symlink/path traversal tests.
- Static gates for output contracts.

Full verification:

```bash
scripts/tron ci fmt check clippy test
git diff --check
```

iOS verification is required only if protocol DTOs or client-visible resource
schemas change:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:<targeted-test>
```

## Exit Criteria

- All new durable outputs flow through resource refs.
- Audit observations for converted paths are zero in targeted tests.
- Static gates prevent reintroducing non-resource durable outputs.
- README and architecture docs describe the enforced model, not the temporary
  audit model.
- No runtime compatibility, fallback renderers, old output aliases, or retired
  DTO readers remain.
