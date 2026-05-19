# Deferred Product-Shell And Domain Output Finalization Phase

## Current Checkpoint

The operator consequence and voice-notes resource conversion checkpoint is
complete:

- control/module/trust-audit/generated UI action summaries now share one
  bounded consequence projection helper;
- generated UI stored actions still execute only through canonical target
  capabilities;
- `voice_notes::save` produces `artifact` and `materialized_file` refs;
- `voice_notes::list` and `voice_notes::delete` use resource truth rather than
  filesystem scans or physical deletion as durable state;
- static gates prevent direct voice-note file write/read/delete APIs from
  becoming source truth again;
- the maturity scorecard baseline is now `97/100`.

## Objective

Close the remaining cleanup gap by auditing and simplifying the product-shell
and deferred domain surfaces that still predate the collapsed substrate.

This phase should be proof-driven and may remove code only when reachability
evidence proves it has no current caller, route, test, or durable contract. It
must not add public capability ids, request/response schemas, storage
generation, resource kinds, generated UI catalogs, compatibility readers,
fallback DTOs, package/source/policy/trust/audit tables, `control::act`, iOS
policy, remote package fetch, or alternate worker-spawn paths.

## Implementation Plan

### 1. Product-Shell Reachability Map

Build a current iOS/server reachability map for:

- AgentControl sheets and cards;
- SourceChanges sheets;
- Subagent result notification views;
- notification inbox/detail views;
- prompt library sheets and state;
- display stream views;
- voice recording affordances.

For each surface, record the entrypoint, navigation path, DTO/client, server
capability or event dependency, tests, and current operator role. Classify it as
`keep thin shell`, `convert to generated UI`, `remove candidate`, or `defer with
reason`.

### 2. Remove Or Consolidate One Proven-Unreachable Surface

Delete exactly one product-shell or DTO path only if the reachability map proves
it is unreachable or duplicated by current generated UI/control projections.
The same change must delete navigation references, DTO/client references,
previews/tests/docs, and add a static absence gate. Do not remove active chat
affordances or device/runtime infrastructure without a replacement path.

### 3. Deferred Domain Output Decisions

For `notifications`, `prompt_library`, `browser`, `display`, `device`, and
`transcription`, classify each durable output path as resource-backed,
ephemeral/projection-only, acceptable chat/session harness state, remove
candidate, or convert-to-resource candidate. Add tests or static gates for the
decision. If a low-risk domain output can be converted without wire/schema/iOS
changes, convert it; otherwise document the exact future conversion boundary.

### 4. Operator Consequence Consumption

If Swift DTOs already tolerate the added action consequence fields, keep iOS
unchanged. If decoding drops or rejects the fields, update only the Engine
Console/generated UI DTO layer to decode and display server-provided
consequence metadata. iOS must still submit only stored action coordinates,
user input, and idempotency key.

## Verification

Run focused checks for any touched product shell/domain, then:

- `cd packages/agent && cargo test generated_ui --lib -- --nocapture`;
- `cd packages/agent && cargo test module_ --lib -- --nocapture`;
- `cd packages/agent && cargo test voice_notes --lib -- --nocapture`;
- targeted domain tests for audited/removed domains;
- `cd packages/agent && cargo test --test threat_model_invariants -- --nocapture`;
- `git diff --check`;
- `scripts/tron ci fmt check clippy test`.

Run `cd packages/ios-app && xcodegen generate` plus targeted Engine Console or
surface tests only if Swift/project files change.

## Out Of Scope

- New package trust features or signature algorithms.
- Remote package distribution, marketplace install, or remote key discovery.
- Control-plane mutation shortcuts.
- Client-side policy or local action construction.
- Storage deletion/archive execution.
- Broad iOS redesign.
