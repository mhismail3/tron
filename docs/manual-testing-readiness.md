# Manual Testing Readiness

This checklist is the clean-state gate before broad manual testing of the
capability-native Tron stack. Existing local development databases, sessions,
and iOS caches are disposable for this cutover.

## Reset And Build

1. Stop any running dev takeover with `scripts/tron dev --stop`.
2. Remove disposable local state as needed: `~/.tron/internal/database/`,
   `~/.tron/internal/run/Tron-Dev.app`, and iOS simulator app data.
3. Run `cargo fmt --all -- --check && cargo check` from `packages/agent`.
4. Run `scripts/tron ci fmt check clippy test` before a checkpoint intended for
   manual QA.
5. Run `cd packages/ios-app && xcodegen generate`, then targeted simulator
   tests for the touched iOS areas.
6. Run `cd packages/relay && npm test` when relay or onboarding smoke paths are
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
2. In chat, verify the provider surface is still exactly `search`, `inspect`,
   and `execute`.
3. Search for core first-party contracts such as `filesystem::read_file`,
   `process::run`, `web::search`, and `program::run_javascript`.
4. Inspect a mutating or high-risk capability and verify the response includes
   an inspection handle, expected revision, and schema digest.
5. Execute a safe first-party capability through `execute(mode: "invoke")`.
6. Run a simple JavaScript program through the Engine Console program form:
   `return args;` with args `{ "ok": true }`.
7. Confirm the program run has a durable run id, code hash, args hash, trace id,
   redacted logs, and no ambient host access.

## Engine Console

1. Overview shows connection, catalog revision, registry revision, vector index
   state, plugins, implementations, bindings, audit rows, and program runs.
2. Capabilities search, inspect, and program execution work only while online.
3. Plugins show manifests, trust/signature/conformance state, namespace claims,
   and support conformance plus state changes through capability admin
   functions.
4. Bindings show selected implementations, policy, scope, and enabled state.
5. Policies show the active capability policies and search/primer policy ids.
6. Audit, traces, and program runs show redacted summaries by default.
7. Disconnect the server and confirm the console is cache-only with mutations
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
- Program form opened before inspection cannot submit.
- Catalog revision or schema digest changes after inspection force re-inspect.
- Offline console disables all mutations.
- Vector index unavailable under the default policy returns a structured error.
- Worker disconnect during a program run records a failed program run.
- Approval-required child work pauses and cannot be self-approved.
