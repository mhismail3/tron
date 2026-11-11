# Protocol v9 lockstep delivery (#2350, option (b))

Maintainer checklist for adopting option (b): the Gateway writes declared session values with the
generated encoders, so their keys move to declaration order. Values and shapes are unchanged. It
applies only if Mohsin adopts (b); delete this file in the same change that delivers it, or with
the branch if (b) is closed.

## What changes on the wire

Measured on the lock scenarios (protocol-wire, prompt-stream, compaction, queue-control,
extension-ui; 236 frames on v8 main, 233 on the candidate):

| Frame | Typed values canonical on v8 | On v9 |
|---|---|---|
| `session.snapshot`, `session.rebaseline` `.snapshot`, `session.open` `.session` (SessionSnapshot) | 0 / 76 | 75 / 75 |
| `session.progress` `.data.message`, `session.transcript` `.items[]` (TranscriptItem) | 0 / 72 | 76 / 76 |
| `session.history.list` `.nodes[]` (SessionTreeNode) | 85 / 111 | 111 / 111 |
| `session.tree` (SessionTreeNode) | 43 / 43 | 43 / 43 |
| `session.toolProgress` `.data` (ToolExecutionState) | 2 / 4 | 4 / 4 |
| `session.extensionPresentation` `.data` (ExtensionPresentationMutation) | 1 / 2 | 2 / 2 |
| `session.list` `.sessions[]`, `session.commands` `.commands[]` | 100% | 100% |
| Every other frame (hello, untyped responses, other events) | byte-identical | byte-identical |

Order-only: every frame keeps its value and its byte length. Clients do not depend on key order:
the iOS hand models (Core compiled with `swiftc` on macOS, Foundation `JSONDecoder`) decode the
v8 and canonical orders of all 315 captured values to `==`-equal models, and the generated Swift
decoders (main's generator and #2380's working-tree generator) decode both orders to the same
canonical value as TypeScript.

## Preconditions (agents, before Mohsin starts)

1. #2380's generated Swift decoders have landed, or Mohsin decides (b) ships without waiting.
2. Rebase the candidate onto main; the change set is one merge:
   - `packages/gateway/src/protocol/frames.ts` and its use in `transport/server.ts` and
     `transport/session-sync.ts`;
   - the v9 contract: `config/GatewayProtocol.json` and its mirrors, checked by
     `python3 scripts/verify-gateway-protocol-contract.py`;
   - every literal `8` hello or contract value in tests, fixtures and script tests (45 files today;
     `rg -l "protocolVersion: 8|PROTOCOL_VERSION = 8|PROTOCOL_VERSION: \"8\""`);
   - the `Protocol.dfy` header comment and `packages/core/README.md` (`protocol v8`). This is a
     comment-only `Protocol.dfy` edit: `scripts/tron proof wire --protocol --check` must pass.
3. Mohsin approves the one golden re-record: `protocol-wire.golden.json` changes exactly
   `declared.gatewayProtocol` 8/8 → 9/9, `handshake.accepted.protocolVersion` 8 → 9 and the
   refusal reason's `gatewayProtocol`/`minProtocol` 8 → 9 (`scripts/tron verify --update-locks
   gateway/e2e`). `client-event-schemas.golden.json` does not move.
4. Green on the rebased branch: `scripts/tron verify --changed --gateway-host mini`, including
   its iOS and Mac lanes through the host-slot tooling, and a Debug check on simulators.
   Debug note: the installed Mac launcher accepts only a payload whose protocol equals its own,
   so a v9 Debug Gateway (9848) cannot start under the v8 Mac app. Validate v9 on the mini or a
   fixture launcher; on this Mac, v9 Debug works only after step 1 below.
5. Park every worker and announce the window: from the merge until step 3 finishes, the v8
   iPhone cannot connect, and no agent can restart Debug from main until step 1 finishes.

## Delivery (Mohsin, in this order)

The Mac app owns the Gateway payload and its launcher, so the Mac goes first; the iOS install
tooling refuses an iPhone build whose protocol differs from the Stable Mac app.

0. **Land.** The agent merges the v9 change to main (`--no-ff`) only when Mohsin says go, right
   before step 1. Record the merge SHA.
1. **Mac app and its Gateway (one full replacement).** From the Mac terminal, since the v8
   iPhone cannot request it:
   ```bash
   scripts/tron mac replace --plan                            # must say: full
   scripts/tron mac replace --start --allow-protocol-change
   scripts/tron mac replace --status --follow
   ```
   Check after: the journal ends `finished`; `scripts/tron mac verify --require-bundled` passes;
   `python3 scripts/verify-gateway-protocol-contract.py --mac-app /Applications/Tron.app` prints
   v9; Gateway `system.info` reports `protocolVersion: 9`. The iPhone now shows "This app is older
   than the Mac gateway … Update Tron on this iPhone." and does not retry (expected).
2. **Debug Gateway (agents, not a maintainer step).** After step 1 an agent may move Debug
   (9848) to v9 under the charter: `scripts/tron dev status` first, and only if no other
   worktree's candidate is still validating, `scripts/tron dev restart` from a worktree at the
   merge SHA.
3. **iPhone.** `scripts/tron-ios-device install` (it verifies the iOS build against the Stable Mac
   app first) or the TestFlight build from the merge SHA. Check after: the app connects; a
   historical chat opens with its transcript; a new prompt streams; a tool call shows progress;
   Ask User answers; the session list and tree load.

## Rollback

Every rollback goes through the same supported tools, never by hand. A revert restores v8 in the
Mac app, its bundled Gateway and the iPhone build together: v8 and v9 never interoperate (the
Gateway, the launcher, the Mac app and the iPhone all require one exact version), so a
half-rolled-back pair stays disconnected until both sides match. No persisted format changes,
so no data migration either way.

- **Step 1 fails after the swap.** `mac replace` restores and verifies the previous app and
  payloads itself (`scripts/tron mac replace --status` shows `rolled-back`); the iPhone was never
  changed and reconnects on v8. Revert the merge on main.
- **After step 1, before step 3.** Revert the merge on main (agent: `git revert -m 1 <merge>`,
  reviewed, pushed), then from the Mac terminal `scripts/tron mac replace --plan` (full) and
  `scripts/tron mac replace --start --allow-protocol-change`, `--status --follow`, and
  `scripts/tron mac verify --require-bundled`. The untouched v8 iPhone reconnects.
- **After step 3.** As above, then reinstall the iPhone from the revert commit
  (`scripts/tron-ios-device install`, which checks it against the v8 Mac app), or the previous
  TestFlight build.
