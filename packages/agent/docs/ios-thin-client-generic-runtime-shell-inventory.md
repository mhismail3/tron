# iOS Thin Client / Generic Runtime Shell Inventory

This inventory maps the current iOS app as a thin `/engine` client and generic runtime shell. It is source-backed by the iOS docs, Swift source/tests, generated project files, root README, local/GitHub quality gates, and predecessor hardening inventories.

## Taxonomy

- `campaign_harness`: IOSTC scorecard, evidence, inventory, and invariant target.
- `ios_protocol`: `/engine` DTOs, protocol constants, settings/auth/model/session/capability/generated-UI request and response types, and canonical failure decoding.
- `ios_events`: live event stream, event registry, plugins, payloads, stored reconstruction helpers, and generic projection into chat.
- `ios_persistence`: local SQLite projection cache, paired server metadata, drafts, sync cursors, event-store refresh, and schema tests.
- `ios_chat_session`: mounted chat session state, coordinators, messaging, streaming recovery, connection state, sheet policy, session switching, and input gating.
- `ios_timeline_runtime`: generic capability invocation display, primitive/result rendering, token/activity state, generated runtime surface validation, and action submission coordinates.
- `ios_settings`: server-authoritative settings decode, sparse updates, reset/default behavior, settings state, and settings pages.
- `ios_pairing_auth`: pairing URL parsing, host validation, token Keychain custody, local paired-server store, onboarding setup hydration, unauthorized repair, and forget/re-pair flows.
- `ios_diagnostics`: bounded local logs, diagnostics bundle assembly, redaction, MetricKit retention, client-log ingestion, feedback delivery, and copied logs.
- `generated_project`: XcodeGen source and tracked generated project discipline.
- `docs_ci`: README, iOS docs, local quality, and GitHub static gate wiring.
- `ios_tests`: focused Swift simulator tests used as behavioral proof for the rows.
- `predecessor_inventory`: current-lineage hardening artifacts updated or referenced so future agents can find IOSTC proof.

## Canonical Rules

1. iOS is a client shell over `/engine`; Rust owns provider communication, model routing, session/event truth, execution, state, logs, settings persistence, and generated runtime data.
2. iOS may cache and reconstruct server facts locally, but local SQLite, drafts, stream cursors, and paired-server metadata are projections or device preferences, not canonical server truth.
3. iOS renders server events, capability invocations, primitive results, and generated runtime surfaces generically. It must not add fixed product panels, repository workflow panels, assistant-management panels, extension-source panels, prompt libraries, audio/voice products, rules/memory surfaces, or self-adapting-agent UI.
4. Pairing accepts only bare DNS names, IPv4 addresses, or unbracketed IPv6 addresses plus a bearer token; full URLs, paths, query strings, userinfo, bracketed hosts, malformed IPs, and malformed DNS labels fail before network probing or persistence.
5. Bearer tokens live in Keychain under per-server ids. Forgetting a server removes the token before metadata; failed setup hydration rolls back token and paired-server metadata.
6. User-editable server settings flow through `ServerSettings`, `ServerSettingsSnapshot`, `SettingsState`, `SettingsMutation`, a settings page control, and sparse `ServerSettingsUpdate`. `tailscaleIp` is Mac-wrapper-owned pairing metadata and stays decode-only in iOS.
7. Server-authored errors use `CanonicalFailurePayload`; local client errors are used only when there is no server response.
8. Diagnostics bundles and client-log ingestion are bounded, redacted, and local-client-owned until explicitly uploaded through `logs::ingest`.
9. `packages/ios-app/TronMobile.xcodeproj` is tracked and must match `project.yml` after `xcodegen generate`.

## Source Findings

- The current iOS implementation already matches the intended thin-client shape. No product-specific source root, provider implementation, deploy/launch service owner, repo-managed skill copy path, or successor self-adapting UI was found under `packages/ios-app/Sources`.
- Existing Swift tests already cover the required behavioral seams: settings decode/update/reset/parity, pairing parsing/validation/persistence/token custody, event registry/projection, chat/timeline reconstruction, generated UI/runtime surfaces, diagnostics/redaction/log ingestion, SQLite schema/cache ownership, reconnect/offline/send-disabled states, and source guards.
- The generated Xcode project already contains the focused test files used by the IOSTC evidence set.
- `tailscaleIp` is an intentional decode-only setting for iOS. CPE records the Mac wrapper as the owner of writes to this sparse server setting; iOS does not expose a user mutation for it.

The machine-readable inventory is `ios-thin-client-generic-runtime-shell-inventory.tsv`.
