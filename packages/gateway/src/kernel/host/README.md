# gateway/host

## Purpose

K3, the module host ([K-0 §3](../../../../../docs/restructure/k0-kernel.md#3-module-host-contract-and-descriptor)):
the contract a capability module implements and the owner of the started modules of
one Gateway.

## Owns

`module-host.ts`: `ModuleDescriptor`, `ModuleInstance`, `GatewayHost`,
`SessionContext`, its narrow context/compaction lifecycle ports, `RpcHandler`, the
K3 hook table (`KERNEL_HOOKS`) and `ModuleHost`. `settlement-module.ts` owns the
ordinary profile's first extension and joins canonical receipt writes before input.
`request-policy.ts` is the neutral activation/request-stage contract; evidence and
concrete refusal errors stay with the implementing module. `canonical-append.ts`
carries live writer facts and an opaque module-issued authority, never a copy of
chapter state or a second Stop fence. `input-admission.ts` carries delivery identities,
bounds and live envelope readers; delivery state and budgeting remain module-owned.
`session-profile.ts` owns the neutral immutable runtime recipe and ordinary defaults.

## Contract

- **Composition.** `main/modules.ts` is the one ordered list. `ModuleHost.start`
  runs each descriptor's `start` once, in that order, with a `GatewayHost`; `stop`
  runs in reverse at shutdown, after the session registry is disposed, and a
  failing stop does not skip the rest.
- **Contracts.** `GatewayHost.contract(m)` returns module `m`'s started contract
  only when `m` is in the reader's `dependsOn` and started earlier.
  `ModuleHost.contract` is composition's read.
- **Session extensions.** `registrations(names, session)` asks the named modules
  for their Pi extensions in recipe order, without reordering or normalizing
  module metadata (K-0 §3). SessionContext
  carries per-runtime identity, presentation, receipt joining, late-bound settings
  access for the session actor and policy operations;
  concrete policy owners remain outside the host and are resolved at each callback.
  The session model runtime and live profile are kernel facts, not module services.
  `registrations(names, session)` keeps each profile's exact order and optionality;
  `summaries(names)` reads those same descriptors' metadata.
- **Profiles (D7).** Started instances own named recipes; `profile(name)` reads
  those definitions, not a second store. `ordinary` and `unrecorded` are reserved.
  Admission freezes recipe metadata. `profileDecision` reads the owner at each
  runtime build and canonical append; only `unrecorded` uses a same-id one-shot
  creation recipe, consumed after selection. The runtime retains its selected
  object. Its request-policy selector resolves the live K3 hook at the original cut.
- **RPC (D5).** A module's `rpc` methods are routed before `GatewayService`'s
  switch. `read` handlers are admitted while the Gateway drains; `mutation`
  handlers run under the command receipt and are refused while draining.
  Capabilities are listed in composition order.
- **Hooks (D6).** A `policy` hook has one implementer; `observers` hooks run every
  implementer in composition order. Dispatch reads each module's `hooks` at the
  call, never a copy taken at start. Notification hooks resolve optional owner
  availability before the run samples terminal or interaction facts; notifications
  admits the alert, while the run owns presence and waiting-episode state.
  Home owns `runSettled`: the run awaits `quiescent` before changing to idle,
  then notifies `idle` synchronously only for a user activation or delivered wake.
  Home schedules pending wakes before its resource-idle callback; neither is cached.
  `requestPolicy` resolves an existing policy once per selected runtime, preserving
  its inner stream guard and outer context/preparation stages. Refusal recognition
  resolves at the error cut; the kernel never imports a module's concrete error.
  `appendGuard` surrounds each canonical write synchronously, revalidates admission
  after its awaits, and receives the committed microtask. Home owns its weakly
  slot-bound chapter-limit fence; the Pi adapter still binds the sole writer.
  `inputAdmission` runs in the session lane before SDK admission. Its module owns
  the envelope/slow diagnostic, releases an unpersisted trigger before terminal
  settlement, and settles deliveries only after the canonical terminal receipt.
- **Fail at start.** A module composed twice, an unknown hook, a second policy
  implementer, duplicate/reserved profile or an RPC method served twice refuses `start`; modules
  already started are stopped.

## Invariants

- The host imports no module; modules reach each other only through declared
  contracts.
- `GatewayHost` carries platform facts and kernel operations, nothing
  module-specific. Composition captures explicit per-module owner resolvers; no
  resolver runs during `start`, before the registry exists. No service bag enters
  `SessionContext`, and no registry owner is copied or cached by composition.

## Entry points

`ModuleHost.start` (gateway-main, and `test-support/gateway-registry.ts` for test
registries), `ModuleHost.contract`, `profile`, `registrations`, `rpc`, `capabilities`, `policy`,
`observers`, `stop`.

## Signals

None of its own; a module logs through `GatewayHost.log`. Shutdown records the
`modules-stop` step (`gateway.shutdown-step`).

## Verify

```bash
scripts/tron verify --module gateway/host
```

Kernel contract: `module-host.integration.test.ts`.

## Not here

Each module's own behavior, stores and locks live in its module folder.
