# Off-Plan Successor Teardown Cleanup Inventory

Status: **complete**.

Machine-readable inventory:
[`off-plan-successor-teardown-cleanup-inventory.tsv`](off-plan-successor-teardown-cleanup-inventory.tsv)

The TSV contains 160 rows: 155 files changed by
`git diff --name-status e781a6aef..2da96a848` plus 5 DISEMD bookkeeping rows
that replace the old SAASTC predecessor dependency with OPSTC.

## History Range

`git log --oneline e781a6aef..2da96a848` identified 24 commits:

- `4b530e014` Harden promotion governance
- `125d58efd` Activate governed external workers
- `2d3cf28eb` Orchestrate governed worker launches
- `899910502` Hand off worker activation bundles via stdin
- `d70165530` Launch workers from reviewed trigger plans
- `9e9393acd` Add governed worker schedule dispatch
- `9e8ccb1cf` Add bounded worker schedule scanning
- `6b09d7a45` Add SAA successor teardown cleanup inventory harness
- `189638351` Remove autonomous worker schedule polling
- `f4d875c37` Tighten SAA execute resource boundaries
- `fa145d752` Narrow SAA activation grant file authority
- `8a1a9a4a8` Tighten SAA promotion governance resource scope
- `3bb44c022` Remove SAA trigger launch timeout override
- `f42f79307` Prove SAA bundle orchestration retention
- `b5f7c3bd1` Tighten SAA schedule state retention
- `19c402fc3` Prove SAA transport boundary retention
- `917cef652` Prune SAA resource type listing
- `13eafc61c` Harden SAA provider execute boundary
- `b695bfdfc` Remove SAA host promotion shortcut
- `18e623ebd` Tighten SAA primitive activation governance
- `60645ffe8` Prove SAA external worker lifecycle retention
- `96429e23f` Prove SAA engine catalog module retention
- `e0a7f5907` Tighten SAA execute grant shape
- `0c50bac63` Prove SAA test quality retention
- `2da96a848` Close SAA successor teardown cleanup

## Action Classes

- `remove_successor_worker_surface`: deleted worker activation, process launch,
  trigger autostart, schedule scan/dispatch, and tests/docs that existed only
  for those future SAA surfaces.
- `replace_cleanup_harness`: deleted the old SAASTC/prove-retention harness and
  replaced it with OPSTC absence and truthfulness guards.
- `restore_pre_off_plan_boundary`: restored modified files to `e781a6aef` when
  the delta existed only to support successor work.
- `retain_bounded_external_worker_substrate`: retained the generic loopback
  external-worker protocol substrate from the primitive boundary, without
  activation bundles, launch plans, or schedules.
- `predecessor_bookkeeping`: retained DISEMD original-list storage artifacts and
  rewired their cleanup reference from deleted SAASTC to OPSTC.

## Retained Primitive Surfaces

Retained engine code is limited to generic catalog, trigger, queue, stream,
state, grant, resource, storage, worker listing/health/disconnect, and loopback
external-worker protocol substrate that already existed before the off-plan
range. These are internal primitive infrastructure; the cleanup did not add a
new public `/engine` feature surface or provider-visible tool.

## Removed Successor Surfaces

Removed surfaces include the worker activation primitive and governance helper,
promotion governance host helper, activation bundle vault, worker process
orchestration, trigger-created launch, worker schedule runtime/contracts/tick
state, worker schedule resource schemas, SAA successor worker invariant targets,
and all active docs claiming those features as retained teardown work.
