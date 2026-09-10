# Native tool settlement qualification

This is a qualification contract for a future computer-use adapter, **not an
implemented native capability**. No native tool is registered by these tests.

## Keep the existing owner

The pinned Pi runtime awaits a registered tool's `execute` promise, and its
`AgentSession.abort()` waits for agent idle. Tron's `RuntimeSlot.abort` and
`GatewayWorkRegistry` then retain the foreground operation through terminal
settlement. A native adapter whose promise joins actual native cleanup can reuse
that ownership; do not add a second work registry simply because the executor is
outside the Gateway process.

A caller's AbortSignal must request cancellation at the exact native owner while
continuing to await its cleanup/quiescence receipt. Do not reject `execute` just
because the client socket or JS waiter was cancelled. Native dispatch or a local
abort acknowledgement is not a completed application effect, and uncertain
mutations must not be replayed. An uncertain effect and confirmed native
quiescence are distinct facts.

If a concrete integration admits work beyond the tool promise's lifetime, that
work needs an exact existing Gateway work handle until real retirement. An early
promise rejection cannot hide it behind a successful Stop or completed drain.

## Executable boundary and negative control

`src/sessions/native-tool-settlement.integration.test.ts` loads a real trusted
Pi extension into the production `RuntimeRegistry`, with a private canonical
session, an in-memory credential store, and the SDK's faux model. Its loopback
peer models independently accepted work; it deliberately remains active after a
client cancellation until the test permits cleanup.

The joined case proves:

- stale operation IDs cannot cancel the current tool;
- native cancellation is requested once, while Stop, foreground work and drain
  remain unsettled;
- cleanup permits exactly one canonical tool result, with an explicitly
  uncertain effect and confirmed quiescence;
- no duplicate action occurs, and the existing work registry drains afterward.

The intentionally bad waiter-only case demonstrates that the same runtime can
settle Stop and drain while the peer is still active if `execute` rejects early.
It is an outcome control, not a supported adapter mode or production ablation.

Run the focused boundary with the repository's Node/npm toolchain:

```sh
cd packages/gateway
npx vitest run src/sessions/native-tool-settlement.integration.test.ts
```

## Evidence limits

The peer does not send macOS input. These tests do not prove Accessibility,
Screen Recording, a signed GUI host, native cancellation, key/button release,
foreground takeover, capture transforms or model perception. Those require the
selected native executor and independent fixture effects. They establish the
Gateway/SDK promise boundary that that executor's adapter must preserve.
