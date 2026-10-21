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

## Contract

- **Composition.** `main/modules.ts` is the one ordered list. `ModuleHost.start`
  runs each descriptor's `start` once, in that order, with a `GatewayHost`; `stop`
  runs in reverse at shutdown, after the session registry is disposed, and a
  failing stop does not skip the rest.
- **Contracts.** `GatewayHost.contract(m)` returns module `m`'s started contract
  only when `m` is in the reader's `dependsOn` and started earlier.
  `ModuleHost.contract` is composition's read.
- **Session extensions.** `extension(m, session)` asks module `m` for its Pi
  extension for one runtime; its position in each profile's extension list is
  the kernel's (K-0 §3), so the model-visible order is unchanged. SessionContext
  carries per-runtime identity, presentation, receipt joining, late-bound settings
  access for the session actor and policy operations;
  concrete policy owners remain outside the host and are resolved at each callback.
- **RPC (D5).** A module's `rpc` methods are routed before `GatewayService`'s
  switch. `read` handlers are admitted while the Gateway drains; `mutation`
  handlers run under the command receipt and are refused while draining.
  Capabilities are listed in composition order.
- **Hooks (D6).** A `policy` hook has one implementer; `observers` hooks run every
  implementer in composition order. Dispatch reads each module's `hooks` at the
  call, never a copy taken at start.
- **Fail at start.** A module composed twice, an unknown hook, a second policy
  implementer or an RPC method served twice refuses `start`, and the modules
  already started are stopped.

## Invariants

- The host imports no module; modules reach each other only through declared
  contracts.
- `GatewayHost` carries platform facts and kernel operations, nothing
  module-specific.

## Entry points

`ModuleHost.start` (gateway-main, and `test-support/gateway-registry.ts` for test
registries), `ModuleHost.contract`, `extension`, `rpc`, `capabilities`, `policy`,
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
