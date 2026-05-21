# Manual Testing Readiness

This checklist is the clean-state gate before broad manual testing of the
capability-native Tron stack. Existing local development databases, sessions,
and iOS caches are disposable for this cutover.

## Reset And Build

1. Stop any running dev takeover with `scripts/tron dev --stop`.
2. Remove disposable local state as needed: `~/.tron/internal/database/`,
   `~/.tron/internal/run/Tron-Dev.app`, and iOS simulator app data.
3. Keep `~/.tron/profiles/default/` managed by the agent. Startup repairs
   stale bundled defaults, including the capability context manifest, from the
   repo defaults before profile validation.
4. Run `cargo fmt --all -- --check && cargo check` from `packages/agent`.
5. Run `scripts/tron ci fmt check clippy test` before a checkpoint intended for
   manual QA.
6. Run `cd packages/ios-app && xcodegen generate`, then targeted simulator
   tests for the touched iOS areas.
7. Run `cd packages/relay && npm test` when relay or onboarding smoke paths are
   part of the testing pass.

## Helper Packaging

1. Build and stage the local Mac helper:
   `packages/mac-app/scripts/bundle-agent.sh --profile debug`.
2. Confirm both executables exist:
   `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron`
   and
   `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron-program-worker`.
3. Start a dev takeover with `scripts/tron dev`.
4. Confirm the dev bundle contains both sibling executables under
   `~/.tron/internal/run/Tron-Dev.app/Contents/MacOS/`.
5. Do not set `TRON_PROGRAM_WORKER_BIN` for manual QA. That variable is only for
   focused tests and should not be required by normal dev or packaged flows.

## Capability Runtime Smoke

1. Pair iOS to the running server.
2. In chat, verify the provider surface is exactly one primitive: `execute`.
3. Use intent-only `execute` to resolve a core first-party contract such as
   `filesystem::read_file`, then use explicit-target `execute` for
   `process::run`.
4. Run a mutating or high-risk capability and verify the engine prepares
   freshness/approval before child execution.
5. Execute a safe first-party capability through the intent-shaped execute
   request: `intent`, optional `target`, and target-only `arguments`.
6. Run a simple JavaScript program through the Engine Console program form:
   `return args;` with args `{ "ok": true }`.
7. Confirm the program run has a durable run id, code hash, args hash, trace id,
   redacted logs, and no ambient host access.

## Engine Console

1. Overview shows connection, catalog revision, registry revision, vector index
   state, plugin/implementation counts, audit rows, program runs, and a plain
   readiness card.
2. Capabilities search works from either the search field or suggestion chips.
   If local vectors are not ready, the result banner must explicitly say the
   console is using degraded lexical search.
3. Program Runs supports the inspect-to-run flow and blocks submit until the
   fresh handle, revision, and schema digest are available.
4. Advanced sections are hidden by default. Toggle Advanced and confirm Plugins,
   Workers, Bindings, Policies, Audit, Traces, and Primer remain available for
   operator work.
5. Plugins show manifests, trust/signature/conformance state, namespace claims,
   and support conformance, promotion, quarantine, and disable actions through
   capability admin functions.
6. Bindings show selected implementations, policy, scope, enabled state, and
   allow enable/disable through capability admin functions.
7. Policies show the active capability policies and search/primer policy ids
   without requiring end users to understand them during normal testing.
8. Audit, traces, and program runs show redacted summaries by default.
9. Disconnect the server and confirm the console is cache-only with mutations
   disabled.

## Provider And History Smoke

1. Start a session on one provider and allow a capability invocation to complete.
2. Switch to a different provider.
3. Continue the session and confirm canonical capability history is serialized
   into the new provider format without losing invocation/result context.
4. Confirm no provider-native function-call or tool-use shape is persisted as
   the canonical session record.

## Mac Wrapper Smoke

1. Run `packages/mac-app/scripts/bundle-agent.sh --profile debug`.
2. Run `cd packages/mac-app && xcodegen generate`.
3. Use `xcodebuild build-for-testing -project TronMac.xcodeproj -scheme TronMac
   -destination 'platform=macOS'` as the reliable local compile gate.
4. Open the app from Xcode for wizard/menu-bar behavior. App-hosted
   `xcodebuild test` can hang on local macOS runners; treat `build-for-testing`
   plus focused Swift tests as the automated gate.

## Failure Cases To Exercise

- Missing `tron-program-worker` beside `tron` prevents bundle creation or
  program execution with a clear error.
- Stale managed profile defaults are repaired before validation; a copied
  default context manifest with retired provider-surface values must not block
  `tron dev`.
- Program form opened before inspection cannot submit.
- Catalog revision or schema digest changes after inspection force re-inspect.
- Offline console disables all mutations.
- Vector index unavailable under the default policy returns a structured error.
- Worker disconnect during a program run records a failed program run.
- Approval-required child work pauses and cannot be self-approved.
