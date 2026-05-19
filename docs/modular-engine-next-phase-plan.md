# Post-100 Production Hardening And Generated-Shell Replacement Plan

## Current Checkpoint

The repo-wide production-grade rubric is complete at `100/100`:

- Prompt Library durable truth is `artifact:prompt-*` resources;
- Prompt Library management is server-authored generated UI over
  `resource_collection` surfaces;
- `PromptLibrarySheet` is a gated selection-only local composer insertion
  affordance;
- static gates forbid fixed Prompt Library management, local generated-action
  construction, prompt-table runtime truth, compatibility readers,
  `control::act`, dynamic UI catalogs, and raw-scope authority.

`100/100` means there are no known unclassified source artifacts, duplicate
durable state planes, legacy runtime readers, or unmanaged fixed product-shell
exceptions. It does not mean future generated UI replacement, soak testing, or
dependency tooling work is finished.

## Next Objective

Use the product-shell reachability map to replace the next fixed shell only
when generated/resource coverage can preserve the current operator role. The
highest-value candidates remain:

1. notification inbox/detail views after notification delivery and read
   receipts have a resource-backed contract;
2. source-control review sheets after generated git/worktree review surfaces
   can cover conflict review and deferred source-change prompts;
3. subagent sheets after child invocation/resource lineage fully replaces
   event/plugin pending-result state.

Do not delete a fixed shell just to reduce surface area. Every removal still
requires caller/route/test/doc proof plus an absence gate.

## Implementation Plan

1. Pick one shell from `docs/product-shell-reachability-map.md`.
2. Define the substrate truth it should render: resources, invocations, grants,
   events, streams, or generated UI surfaces.
3. Build the generated/resource replacement first, with tests proving it
   covers the current operator role.
4. Remove the fixed Swift surface only after the replacement is live and
   navigable.
5. Delete stale DTO/client/state/tests/docs/project references in the same
   checkpoint.
6. Add static gates preventing the retired symbols and any compatibility path
   from returning.
7. Keep iOS/Mac clients thin: they may render server truth and submit stored
   actions, but must not own policy, grants, lineage, target functions, payload
   templates, or durable state.

## Verification

For any generated-shell replacement:

- targeted Rust tests for the server/resource/generated UI path;
- targeted iOS tests for navigation, renderer state, source guards, and the
  removed/replaced shell;
- `cd packages/ios-app && xcodegen generate` when Swift files or project
  membership change;
- `cd packages/agent && cargo test --test threat_model_invariants -- --nocapture`;
- `git diff --check`;
- `scripts/tron ci fmt check clippy test`.

Run Mac verification only if Mac files or XcodeGen inputs change.

## Out Of Scope

- New storage tables, resource kinds, generated UI catalogs, compatibility
  readers, fallback DTOs, or control mutation paths.
- Remote package distribution or marketplace work.
- Product redesign of chat.
- Client-owned policy or generated UI mutation construction.
