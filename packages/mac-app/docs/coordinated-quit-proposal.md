# Coordinated Mac Quit proposal

Status: preserved prototype on `feature/mac-coordinated-quit`; **not merge-ready**.
No build, runtime qualification, or production lifecycle action was performed as
part of preservation. The branch starts from historical commit `53c6f82c9`, not
current main. Its source, tests, and architecture edits must be reviewed together.

## Decision before implementation

Main's architecture intentionally says quitting the wrapper does not stop
accepted Gateway work. This draft changes that contract: an owned Quit requests
Gateway shutdown, observes the exact process/launch identity reach clean exit,
retires the native helper, and unregisters the service before terminating the UI.
Do not merge it as a missing bug fix or infer approval for that product change
from the existence of this branch.

## Useful starting points

- `Sources/App/Lifecycle/MacQuitCoordinator.swift` owns the ordered quit attempt,
  exact runtime identity, retry receipt, and replacement checks.
- `Sources/Server/Health/GatewayShutdownClient.swift` and the Gateway transport/
  supervisor changes propose an administrative shutdown distinct from restart.
- `Tests/App/Lifecycle/MacQuitCoordinatorTests.swift` and
  `Tests/Server/Health/GatewayShutdownClientTests.swift` capture the draft's
  behavioral intent. Existing source/docs changes include launchd exit policy,
  startup maintenance, permission-host retirement, and menu/wizard routing.

## Resuming safely

1. Obtain an explicit decision on whether Quit should stop the Gateway and what
   happens to accepted work. Preserve the current behavior until then.
2. Create a new isolated worktree from current main and port only the approved
   behavior. Review the current launchd, drain, native-host, and receipt owners;
   do not wholesale merge this historical snapshot.
3. Reconcile tests with current contracts and run focused Gateway/Mac checks.
   Validate rejection, interrupted/lost responses, retries, runtime replacement,
   native retirement failure, and normal wrapper-only quit.
4. Any running Gateway transition, signed application replacement, or production
   qualification remains a manual maintainer action under root project rules.

Generated payloads, dependency links, and build outputs are not part of this
proposal. The feature branch is the durable source; no temporary worktree path is
required to resume it.
