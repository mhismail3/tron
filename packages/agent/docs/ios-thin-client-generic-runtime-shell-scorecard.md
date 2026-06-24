# iOS Thin Client / Generic Runtime Shell Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/ios-thin-client-generic-runtime-shell-current`
Baseline: `codex/release-install-upgrade-rollback-discipline-current` at `084efb4d807eb39c8f3a36508c12541a477c58ce` (`Harden release install rollback discipline`)
Lineage: SACB remediation -> OPSAA cleanup -> ODA -> DSEMD -> PPACD -> OPSAA reconciliation -> PMBD -> PERF -> CPE -> RIURD -> IOSTC.

Stale branch quarantined as quarry-only: `codex/ios-thin-client-generic-runtime-shell` at `3cec727e19505aa4c58a18bcc4e54560c6829cce`. It was not merged, cherry-picked, copied wholesale, or used as completion evidence.

| Row | Name | Weight | Status | Closure |
| --- | --- | ---: | --- | --- |
| IOSTC-0 | Baseline, lineage, and stale-branch quarantine | 5 | passed | Verified the worktree started at `084efb4d8`, created `codex/ios-thin-client-generic-runtime-shell-current`, and recorded stale `codex/ios-thin-client-generic-runtime-shell` as quarry-only. |
| IOSTC-1 | Whole iOS client inventory and ownership map | 8 | passed | Added markdown and TSV inventories covering protocol DTOs, events, settings, pairing/auth, persistence, chat/session state, timeline/runtime rendering, diagnostics/logs, onboarding, project generation, docs, CI/local gates, and tests. |
| IOSTC-2 | Thin-client boundary and deleted product-surface guards | 12 | passed | Source guards prove iOS owns no server semantics, provider implementations, product panels, resource mutation policy, launch/deploy behavior, repo-managed skills, or successor self-adapting-agent UI. Existing Swift SourceGuard tests and the new Rust invariant gate deleted product residues. |
| IOSTC-3 | Pairing, auth custody, and connection robustness | 10 | passed | Pairing parser/validator/persistor tests prove strict bare-host parsing, Keychain token custody, rollback on failed setup hydration, forgotten-server token deletion, unauthorized repair, reconnect policy, offline/unpaired states, and actionable generic errors without token leaks. |
| IOSTC-4 | Settings parity and sparse update contract | 10 | passed | Server settings decode/update/state/page references are source-guarded. User-editable server settings have one UI/state mutation path, sparse updates encode only the mutated group, reset returns server defaults, malformed payloads throw, and Mac-owned `tailscaleIp` is documented as decode-only pairing metadata. |
| IOSTC-5 | Generic chat, timeline, and primitive/result rendering | 12 | passed | Chat/timeline reconstruction, event classification/projection, capability invocation display, generated UI renderer, and streaming recovery tests prove generic server-event and primitive/result rendering without fixed product panels or catalog-specific sheets. |
| IOSTC-6 | Server error, restart, offline, and recovery semantics | 10 | passed | Error projection, server restarting plugin, reconnect policy, streaming recovery, send-disabled state, and settings unavailable state tests prove deterministic disconnected, unauthorized, protocol-error, restart, catch-up, and retry behavior without masking failed server state. |
| IOSTC-7 | Diagnostics, logs, redaction, and local persistence | 8 | passed | Diagnostics redactor, bundle builder, client-log ingestion, MetricKit retention, SQLite schema/cache, drafts, paired-server storage, and event-store sync tests prove bounded local-only diagnostics/cache ownership and redacted secret handling. |
| IOSTC-8 | Simulator and generated project drift discipline | 8 | passed | `xcodegen generate` is wired into local/release/CI validation, the tracked `TronMobile.xcodeproj` is diff-checked, and iOS 26.5 focused simulator commands cover settings, pairing, events, timeline/runtime display, diagnostics, and error projection. |
| IOSTC-9 | Docs, README, predecessor inventories, and CI wiring | 9 | passed | Added IOSTC scorecard/evidence/inventory artifacts, README living-doc and iOS references, iOS docs verification notes, predecessor inventory rows, local `scripts/tron.d/quality.sh` wiring, and GitHub static-gates wiring. |
| IOSTC-10 | Targeted static gates and broad closeout | 8 | passed | Added `ios_thin_client_generic_runtime_shell_invariants.rs` with artifact, inventory, deleted-product, successor-residue, settings parity, generated project, simulator evidence, predecessor wiring, and closeout guards. |

## Source Corrections

No iOS runtime source changes were required. The audited implementation was already thin in the required areas; this slice closes the missing current-lineage proof with source-backed inventories, guards, docs, CI wiring, and simulator evidence.

## Settings Exception

`settings.server.tailscaleIp` is decoded by iOS because it can appear in the server settings payload, but CPE classifies it as Mac-wrapper pairing metadata. It is not user-editable from iOS and is not exposed as a `SettingsMutation`; iOS pairing uses scanned/pasted/manual host fields and local paired-server storage instead.
