# Tron Mac architecture

`Tron.app` is a menu-bar application that installs, observes, and controls one
launchd-supervised Tron Gateway. The Login Item contains a universal launcher;
the launcher executes the exact Node runtime and Gateway payload sealed inside
the outer app.

## Supported modes

| Build configuration | Wrapper ID | Login Item | Service label | State root | Port |
|---|---|---|---|---|---|
| Release | `com.tron.mac` | `Tron Gateway.app` | `com.tron.gateway` | `~/.tron` | 9847 |
| Debug | `com.tron.mac.dev` | `Tron Gateway Dev.app` | `com.tron.gateway.dev` | `~/.tron-dev` | 9848 |

`GatewayRuntimeMode` accepts only those wrapper identifiers.
`GatewayServiceConfiguration` resolves the label, helper, plist, home, port,
credential files, state file, and lock file once. Every lifecycle component
receives that immutable configuration; no component derives a second identity.

The service plist starts the Gateway with `--host tailscale` and its exact
mode-specific port. `RunAtLoad`, crash restart, and a ten-second throttle make
launchd the only process supervisor.

## Ownership

- `App/Lifecycle/GatewayAppContext.swift` owns process-local application mode.
- `Gateway/GatewayLifecycleCoordinator.swift` is the only owner of Gateway
  installation, reconciliation, pause, resume, restart, and uninstall.
- `Gateway/Service/` is the narrow `SMAppService` and current-label launchctl
  boundary.
- `Gateway/Health/` performs authenticated protocol health checks.
- `Gateway/Paths/` owns exact identities and the atomic Mac state record.
- `Gateway/ProcessControl/SingleInstanceLock.swift` owns cross-process wrapper
  exclusivity.
- `Wizard/` renders the onboarding state machine and emits user intent.
- `MenuBar/` renders coordinator snapshots and routes actions back to the
  coordinator.
- `Support/Pairing/` creates strict invitation URLs and QR images.
- `Sources/Resources/Library/` contains the two Login Items and service plists.

The coordinator rejects a second mutation while one is active. Passive status
refreshes share one in-flight probe, and a mutation cancels an older passive
refresh. Each mutation has an operation ID; cancelled or superseded work cannot
publish a snapshot or write setup state. Snapshot streams buffer only the latest
value.

## Durable Mac state

The only onboarding and update record is:

```text
<state-root>/gateway/mac-app-state.json
```

It is atomically replaced, mode `0600`, inside a mode `0700` directory. Schema
version, onboarding completion, and the last successfully prepared app version
are required. A missing record starts onboarding. A corrupt record starts
onboarding with a repair error. Update reconciliation records the new app
version only after service registration, launch, and authenticated health all
succeed.

Gateway sessions, provider credentials, authorized devices, and enrollment
state are not part of this record.

## Health and pairing

Tailscale must report `BackendState=Running` and a live IPv4 address inside
`100.64.0.0/10`. That address is the sole host used for health and pairing. If it
is unavailable, the coordinator and wizard expose a retryable Tailscale state.

The Gateway writes owner-only local authorization and enrollment files below
`<state-root>/gateway/`. Pairing first authenticates a health request, then reads
an unexpired one-time enrollment code and emits:

```text
tron://pair?host=<tailscale>&port=<port>&code=<one-time>&label=<mac>
```

Permanent device tokens never enter QR codes or Swift presentation state. The
menu-bar pairing window creates a new in-memory model each time and does not
change onboarding progress.

## Onboarding and menu bar

The paved flow is Welcome, Tailscale, Install Gateway, Permissions, Connect
iPhone, and Done. `GatewayOnboardingModel` owns and cancels every probe and
mutation. On interruption it derives the earliest incomplete step from current
Tailscale, service, authenticated health, permission, and pairing truth.

After onboarding, `Tron.app` runs as a menu-bar application. The menu is
status-first and displays only coordinator snapshots. It can show pairing info
and logs, send feedback, pause, resume, restart, uninstall, and quit. Disposing
the controller cancels its snapshot, polling, refresh, and action tasks and
closes its windows.

## Uninstall boundary

Uninstall unregisters only the configured service and verifies it is absent.
An already absent service is success. It then removes only the Mac state record
and, when explicitly selected, the current local Gateway authorization file.
Sessions, provider credentials, enrollment files, and authorized-device state
remain untouched. Cleanup failures return typed partial results so the user can
retry safely.

## Signing order

The Xcode post-build phase copies only the configuration's service plist and
Login Item plus the staged Gateway payload, signs native Gateway files, and
signs the Node runtimes with the JIT entitlement required by V8. It signs the
nested Login Item, then seals the outer app after generated Mach-O
files are signed, so incremental builds cannot leave a stale resource seal;
Xcode's normal signing step may seal it again. Release validation inspects both
helper and outer-app signatures before packaging.
