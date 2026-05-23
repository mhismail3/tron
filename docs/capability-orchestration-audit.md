# Capability Orchestration Audit

This document owns the manual-test loop for the model-facing capability
surface. The invariant is deliberately small: provider models see one
primitive, `execute`; the engine owns resolve, prepare, approval, run, replay,
and observe.

## Current Decision

`capability::search` and `capability::inspect` remain normal engine/operator
capabilities for the Engine Console, program composition, and administrative
debugging. They are no longer provider-visible model primitives. The
model-visible schema for `execute` is intent-shaped:

- `intent`: natural-language goal;
- `target`: optional provider-safe capability id string, such as
  `process::run`;
- `contractId`, `capabilityId`, `functionId`, `implementationId`: optional
  direct target aliases for callers that already know the id;
- `arguments`: the selected target capability arguments only;
- `constraints`: optional v1 bounds (`riskMax`, `effect`,
  `allowedContracts`, `allowedNamespaces`);
- `idempotencyKey` and `reason`: wrapper-level orchestration fields.

The exported provider schema intentionally stays plain JSON Schema: one object
with scalar target fields, no `oneOf`, `anyOf`, `allOf`, top-level `enum`, or
`not`. That is the portability boundary for OpenAI, Anthropic, Gemini, Kimi,
and Ollama. Flexibility lives in the runtime normalizer: target aliases, the
`payload` alias, nested wrapper-field correction, freshness, idempotency, and
constraint handling are accepted when safe and recorded in orchestration audit
diagnostics.

The direct invoke/program shape remains internal/operator API for existing
engine clients and program execution. It is not exported as provider tool
metadata.
Unsupported constraint fields and malformed constraint values are rejected
instead of ignored, because a constraint that does not affect resolution or
preparation is a false safety signal. For intent-only calls, constraints filter
candidate capabilities before the engine picks a target.

## Orchestration Scorecard

| Axis | Status | Evidence | Next Improvement |
|---|---|---|---|
| Single model-visible tool | Complete | `capability::contract::tests::only_execute_has_model_metadata`; `threat_model_invariants` model-primitive gate | Keep provider conversion tests in lockstep with any new provider |
| Prompt/doc drift | Complete | `threat_model_invariants` checks default prompts for single-`execute` guidance and rejects retired `search.queries` / `inspect.targets` choreography; README and iOS docs separate model-facing `execute` from operator/internal catalog reads | Keep prompts, docs, and provider metadata aligned whenever capability routing changes |
| Resolve quality | Implemented | `execute` resolves intent through the live registry, recipes, tags, health, trust, and search score | Add manual-session audits for misresolution and improve recipes/aliases from observed misses |
| Prepare correctness | Implemented | Freshness, schema, idempotency, target-policy, and approval preflight happen before child execution | Add more target-specific correction tests as new high-use capabilities appear |
| Correction safety | Implemented | Shape corrections are recorded as `correctionsApplied`; mutating/elevated-risk calls still require freshness/approval | Track correction kinds in audit queries and remove noisy correction classes when recipes improve |
| Auditability | Implemented | `capability.orchestration` events include candidates, selected target, rejected candidates, corrections, phase, child invocations, and resource refs | Add dashboard/reporting only if manual audit volume warrants it; do not add a new table |
| Error guidance | Implemented | Structured `needs_input`, `needs_selection`, `needs_capability`, target-payload, and target-policy results | Continue rewriting ambiguous target errors into exact missing fields and safe next calls |

## Known Confusion Classes

| Class | Engine Handling | Audit Filter |
|---|---|---|
| `payload` used instead of `arguments` | Safe top-level alias becomes `arguments` with `payload_to_arguments` correction | `correctionKind=payload_to_arguments` |
| Target fields nested under arguments | Moved to `target` when they do not conflict with an explicit target | `correctionKind=nested_target_to_target` |
| Wrapper fields nested under arguments | `idempotencyKey` and `reason` move out; stale freshness fields are removed | `correctionKind=nested_idempotency_key_to_wrapper` |
| `expectedOutputs.kind` / `role` / `type` for `process::run` | Removed because process outputs are path-driven | `correctionKind=process_expected_outputs_shape` |
| `expectedOutputPath(s)` aliases for `process::run` | Converted to `expectedOutputs: [{"path":"..."}]` before schema validation | `correctionKind=process_expected_outputs_alias` |
| `sandbox_materialized` without `expectedOutputs` | Rejected during prepare before approval or child execution with the exact required shape | `orchestrationStatus=target_policy_rejected` |
| Sandbox output verification after approval | `process::run` returns bounded `materializedOutputs` with target path, resource/version refs, file content hash, byte size, and content preview; relative materialization targets resolve to the active session worktree | `result.materializedOutputs[*]` |
| Duplicate approved sandbox execution | Replays the prior approval/result as provenance with `approvalReplayed=true`; it must not expose a fresh `approvalState`, publish a new `approval.pending` stream event, create a new approval chip, or report a new child invocation | `details.approvalReplay`; `engine_stream_events.topic=approvals` |
| Attempting unknown interpreters for verification | Rejected as unproven read-only; use `materializedOutputs`, `materialized_file::read`, or the returned materialized path instead of ad hoc Python/hash commands | `orchestrationStatus=target_policy_rejected` |
| Missing required target fields | Returns `isError=true` with exact missing fields and no child invocation | `orchestrationStatus=target_payload_invalid` |
| Ambiguous natural-language intent | Returns `needs_selection` with ranked candidates | `orchestrationStatus=needs_selection` |
| No matching capability | Returns `needs_capability` and a proposed capability shape | `orchestrationStatus=needs_capability` |
| Unsupported or malformed constraints | Returns `constraints_rejected` before child invocation | `orchestrationStatus=constraints_rejected` |
| Path-read intent ranks an unrelated capability | Deterministic path-read routing promotes `filesystem::read_file` when the intent asks to read/open/cat file content and target arguments include `path` | `matchedBy=deterministic_path_read` |
| Line-bounded file read | `filesystem::read_file` accepts optional 1-based `startLine`/`endLine` instead of forcing agents into `process::run` for simple excerpts | `selectedTarget=filesystem::read_file` |

## Manual Test Rewind

The single-`execute` clean break changes the model-facing contract, so manual QA
must restart the capability foundation tests before testing higher-level product
flows. Previously verified Prompt Library and Engine Console presentation fixes
do not need a full restart unless their generated-UI action submission path is
touched, but every capability-call ergonomics test below should be rerun because
resolution, correction, freshness, and audit events now originate from one
primitive.

Minimum rewind set:

1. Provider/session bootstrap: confirm provider metadata exposes only
   `execute`, while Engine Console operator search/inspect still works.
2. Intent-only read and explicit-target read: prove both resolve through one
   `execute` call with no approval and no durable output.
3. Read-only process allow and write-like read-only denial: prove the classifier
   distinguishes safe checks from unsafe commands without approval confusion.
4. Sandbox materialized process plus approval: prove freshness, approval,
   child invocation, and resource refs remain intact through the orchestrator.
5. Duplicate idempotency replay: prove no duplicate child execution, approval,
   resource version, or materialized file.
6. Shape correction and constraints: prove harmless shape mistakes are audited,
   unsupported constraints fail closed, and allowed constraints filter intent
   resolution before execution.
7. Audit query: prove `capability::audit_query` can find recent attempts by
   `orchestrationStatus`, `correctionKind`, and `phase`.

## Manual Test Matrix

Run these tests one at a time during device QA. After each test, ingest iOS logs
and query the server database before moving on.

1. **Intent-only read:** ask for a filesystem read without naming the target.
   Expected: one `execute` call, a resolved filesystem target, no approval, and
   no durable output unless the target contract produces one.
2. **Explicit target read:** call the filesystem read through `target` or the
   `contractId` alias with target-only `arguments`.
   Expected: the read succeeds, and audit records the selected target plus any
   alias correction.
3. **Explicit read-only process:** call `process::run` with
   `{"command":"pwd && test -f README.md && sed -n '1,3p' README.md","executionMode":"read_only"}`.
   Expected: no approval, no resource refs, child invocation succeeds if the
   active worktree has `README.md`.
4. **Rejected read-only write:** call `process::run` with a write-like command
   and `executionMode=read_only`.
   Expected: structured target-policy rejection, no approval, no child
   invocation, and no file leak.
5. **Sandbox materialized write:** call `process::run` with
   `executionMode=sandbox_materialized`, declared `expectedOutputs`, and a
   stable `idempotencyKey`.
   Expected: freshness/approval pause before child execution, then resource refs
   after approval, plus `materializedOutputs` showing the exact bounded content
   preview and file content hash. Relative outputs should materialize into the
   active session worktree, not the server process cwd.
6. **Duplicate idempotency:** repeat the exact sandbox call.
   Expected: replay, no duplicate approval, child invocation, materialized file,
   or resource version. The execute result should report the prior approval as
   replay provenance (`approvalReplayed=true`), not as a fresh approval
   requirement, and no fresh `approval.pending` event should be published.
7. **Ambiguous intent:** use a broad intent such as “search”.
   Expected: `needs_selection` with candidates, no child invocation.
8. **Shape correction:** place `payload`, `contractId`, and `idempotencyKey` in
   the old nested shape, and try `expectedOutputPaths` or
   `expectedOutputs` entries with harmless `kind`/`role`/`type` metadata.
   Expected: corrected request and correction records; mutating calls still
   pause before execution.
9. **Constraint filtering:** ask for an intent that could match multiple
   capabilities and include constraints such as
   `{"riskMax":"low","allowedNamespaces":["filesystem"]}`.
   Expected: candidates outside the constraint are rejected before selection;
   malformed or unsupported constraints return `constraints_rejected`.

## Audit Queries

Use SQLite against the active Tron database after logs are ingested. Keep
payload reveal local; do not paste sensitive payloads into issue reports.

```sql
-- Latest orchestration attempts.
SELECT created_at, trace_id, json_extract(payload_json, '$.status') AS status,
       json_extract(payload_json, '$.phaseDetails.phase') AS phase,
       json_extract(payload_json, '$.intent') AS intent
FROM capability_audit_events
WHERE event_type = 'capability.orchestration'
ORDER BY created_at DESC
LIMIT 25;
```

```sql
-- Correction kinds seen recently.
SELECT created_at, trace_id, json_extract(value, '$.kind') AS correction_kind
FROM capability_audit_events, json_each(payload_json, '$.correctionsApplied')
WHERE event_type = 'capability.orchestration'
ORDER BY created_at DESC
LIMIT 50;
```

```sql
-- Failed resolve/prepare phases that should feed recipe/ranking work.
SELECT created_at, trace_id, json_extract(payload_json, '$.status') AS status,
       json_extract(payload_json, '$.phaseDetails') AS phase_details
FROM capability_audit_events
WHERE event_type = 'capability.orchestration'
  AND json_extract(payload_json, '$.status') IN
      ('needs_input', 'needs_selection', 'needs_capability',
       'target_payload_invalid', 'target_policy_rejected')
ORDER BY created_at DESC
LIMIT 25;
```

The same data is available through `capability::audit_query` with
`orchestrationStatus`, `correctionKind`, and `phase` filters. Payloads are
redacted by default.

## Iteration Rule

Every manual misresolution or confusing correction should produce one of these
outcomes:

- recipe/tag/alias improvement in the owning capability;
- clearer required-argument or error guidance;
- a new correction test if the engine can safely normalize the mistake;
- a `needs_capability` follow-up if no existing capability actually fits.

Do not add another model-visible primitive to fix ergonomics. The model mental
model stays `execute(intent, target?, arguments, constraints?)`; improvements
belong in registry recipes, ranking, preflight diagnostics, and audit-driven
iteration.
