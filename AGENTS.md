# Tron Project Guidelines

## Rules

1. **Code, tests, and docs ship together.** Update the owning documentation and
   focused tests in the same change.
2. **Tron is the user-facing agent.** Pi is the pinned backing SDK and may be
   named in technical source/dependency documentation, not as a second product
   users operate.
3. **Canonical truth stays canonical.** Runtime JSONL, settings, credentials,
   packages, resources, compaction, and retries are authoritative. iOS caches
   and gateway snapshots are bounded projections, never mirrors.
4. **Root-cause fixes only.** Do not recreate Engine, workers, event journals,
   SQLite session mirrors, or compatibility branches for retired architecture.
5. **Personal data stays out of source; secrets stay in owned stores.** Run
   `scripts/personal-info-guard.sh`. Provider credentials remain in the Mac
   runtime store; mobile device tokens remain in Keychain; only hashes persist
   in gateway state.
6. **Production behavior justifies production code.** Test-only hooks stay test
   only; speculative runtime surfaces should be deleted.
7. **Never run or add automated production deployment.** Production release and
   deployment are manual maintainer actions.
8. **Gateway rebuilds are user-initiated only.** Agents must never invoke a
   Gateway rebuild, update, rollback, promotion, restart, any mutating
   `scripts/tron dev` lifecycle command, or the corresponding control-plane RPC.
   This applies even when the requested change needs a newer Gateway. Agents may
   prepare and validate source or build artifacts and report the exact user
   action, but the user or maintainer must perform the action that transitions a
   running Gateway.
9. **Do not OS-freeze Gateway-owned agent work.** `SIGSTOP` or equivalent
   suspension does not update Pi's authoritative lifecycle, so Tron still
   projects the run as active and a drain-aware Gateway restart remains blocked.
   Use the owning session's soft interrupt or stop control. If that route is
   unavailable, state the limitation; only settle the exact child after explicit
   user authorization, preserve its isolated worktree, and verify both terminal
   run state and release of the Gateway drain.

## Architecture invariants

- One live gateway runtime owns each canonical session.
- Mutations serialize per session; distinct sessions may run concurrently.
- Accepted prompts continue after iOS disconnects.
- Reconnect receives an authoritative snapshot; prompts are never automatically
  replayed after interruption.
- Mutation requests carry command IDs and use bounded idempotency receipts.
- Project trust gates executable project resources but is not a sandbox.
- Tailscale exposure binds explicitly to its interface; developer default is
  loopback.
- The Mac wrapper's local credential is separate from mobile device credentials
  and legacy authentication.
- Do not open one canonical session concurrently in another runtime client; the
  session format has no cross-process lock.

## Agent routing

- Project skills live only under `.agents/skills/`; do not create harness-specific
  copies or duplicate detailed procedures in this file.
- For iOS build, test, simulator, signing, archive, or physical-device work, load
  `.agents/skills/tron-ios/SKILL.md` and use its routing table.
- Use repository device helpers rather than inventing scheme/configuration pairs.
  Physical development uses `Tron Device` + `LocalDevice`; `Release` is
  archive-only, and signed artifacts are the authority for Apple environments.
- Never erase iOS application or Keychain data to recover from a build/signing
  mismatch, and do not install on a device another session currently owns.

## Validation

Prefer focused checks while iterating. Do not repeatedly run full or multi-minute
end-to-end suites during diagnosis. Start with the owning unit, contract, fixture,
or state test; use the narrowest integration case that can reproduce the boundary.
Reserve full end-to-end suites for final cross-module/release checkpoints or an
explicit maintainer request.


```bash
# Gateway
cd packages/gateway
npm run build
npx vitest run <owning-test-file>

# iOS: canonical owned test simulator, bounded process, and focused owner
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileTests/<Suite>

# Mac
cd packages/mac-app && xcodegen generate
xcodebuild build-for-testing -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'
xcodebuild test-without-building -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:TronMacTests/<Suite>
```

Run full gateway/native suites at cross-module checkpoints or after focused
owners pass. Stage the Mac payload with `packages/mac-app/scripts/bundle-gateway.sh`
only when packaging/build validation needs generated resources.

## Documentation ownership

- Product front door: `README.md` (keep under 250 lines)
- Gateway contracts and invariants: `packages/gateway/README.md`
- iOS architecture/development/events: `packages/ios-app/docs/`
- Mac architecture/development: `packages/mac-app/docs/`
- Contributor workflow: `CONTRIBUTING.md` and `scripts/tron --help`

### Local Mac reinstall runbook

When a user explicitly requests a local Mac app reinstall, read and follow
`packages/mac-app/docs/development.md` → **Reinstall a local Release build**.
That runbook is the canonical sequence for staging the Gateway, building the
Release app, preserving `~/.tron`, and refreshing the LaunchAgent registration.
An agent may prepare the build and report the exact `.app` artifact path, but
must not silently replace `/Applications/Tron.app` or perform production
release/deployment; the user must explicitly approve and perform that local
application replacement. After the user replaces it, run `scripts/tron mac verify`
and do not claim success until it passes. Never delete `~/.tron` or reset
credentials as part of an update. Restarting the Gateway is not an app
reinstall: it only restarts the currently registered Gateway image.

When behavior changes, update the nearest owner. Legacy claims must be removed,
not retained as audit ledgers.
