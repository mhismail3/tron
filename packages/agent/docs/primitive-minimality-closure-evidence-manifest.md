# Primitive Minimality Closure Evidence Manifest

Status: **complete**
Current score: **100/100**
Scorecard: [`primitive-minimality-closure-scorecard.md`](primitive-minimality-closure-scorecard.md)
Inventory: [`primitive-minimality-closure-inventory.md`](primitive-minimality-closure-inventory.md)
Machine inventory: [`primitive-minimality-closure-inventory.tsv`](primitive-minimality-closure-inventory.tsv)
Invariant target: `packages/agent/tests/primitive_minimality_closure_invariants.rs`

## Source Audit

PMC starts from SSARR HEAD
`7b03b51f5476f5764e3813666137897af2f3cd3d` on
`codex/primitive-minimality-closure-current`. The slice audits runtime provider
code, proof artifacts, README wiring, CI target parity, and predecessor
inventories. The branch does not change `/engine` schemas, provider model
catalog IDs, settings/auth/profile DTOs, database migrations, iOS Swift source,
Mac source, or deploy commands.

## Baseline Verification

| Command | Result | Rows |
| --- | --- | --- |
| `scripts/tron ci fmt check clippy test` | exit 0 | PMC-0 |
| `scripts/personal-info-guard.sh` | exit 0 | PMC-0 |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | exit 0 | PMC-0 |

## Reduction Batches

| Batch | Removed or collapsed surface | Owner | Non-essential reason | Replacement or retained owner | Proof |
| --- | --- | --- | --- | --- | --- |
| 1 | `SystemPromptBlock::text_cached` plus `text_block`, `image_block`, `document_block`, `thinking_block`, `tool_use_block`, and `tool_result_block` request helpers in Anthropic `types` | Anthropic provider types | Only test-owned constructors remained; production conversion already emits provider JSON blocks directly. | `message_converter` and `provider` build the request body from internal messages and provider config. | `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::anthropic --lib -- --quiet` exit 0 |
| 2 | `convert_context` and private Anthropic `convert_tools` in `message_converter` | Anthropic provider conversion | No production caller used the facade; provider-owned `build_tools` is the actual request path. | `AnthropicProvider::build_tools` remains the single Anthropic tool-definition path and keeps last-tool cache control. | Anthropic focused tests plus `cargo check --manifest-path packages/agent/Cargo.toml` exit 0 |
| 3 | Google `StreamState.completed_tool_ids` | Google provider stream handler | No reader or writer used the set after Gemini capability completion was centralized. | `capability_invocations` and `handle_finish` remain the stream state and completion source. | `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::google::stream_handler --lib -- --quiet` exit 0 |
| 4 | Google `synthesize_done_event` test-only fallback | Google provider stream handler | Production stream completion already goes through finish-reason handling; no caller synthesized missing finish events. | `handle_finish` maps Gemini finish reasons into canonical done/capability events. | Google stream-handler focused test exit 0 |
| 5 | Shared `parse_sse_data` helper | Shared provider SSE parser | Stream pipeline deserializes JSON directly after `parse_sse_lines`; no caller used the wrapper. | `stream_pipeline::sse_to_event_stream` owns deserialize-and-warn behavior. | `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::shared::sse --lib -- --quiet` exit 0 |

## Retained Suspicious Surfaces

| Surface | Owner | Retention reason | Guard |
| --- | --- | --- | --- |
| Provider `retry` fields and token-expiry settings warnings | Provider config/settings owners | Config structs deserialize profile/provider settings and are intentionally wider than every current call site. Removing fields would be a settings/auth contract change. | PMC inventory row plus `cargo check` and provider settings tests in broad CI |
| Provider catalog `id`, `short_name`, `supports_capabilities`, and cache price metadata warnings | Provider catalog owners | Catalog structs back provider model metadata, API JSON, UI/settings display, and provider support flags. Removing fields would be a catalog/API semantics change, not a primitive-minimality refactor. | PMBD/PERF predecessor invariants plus broad CI |
| Engine trace-list and resource-kind inspection paths | Engine durability owners | Public inspection now goes through accepted trace/log/resource projections; unused lower-level `list_by_trace` and `list_types` helpers were removed after proving no caller remained. | ODA/DSEMD/SOL predecessor invariants plus focused warning cleanup |
| Historical scorecards and inventories | Docs/proof owners | Historical evidence remains append-only provenance. PMC classifies it rather than deleting proof needed by predecessor static gates. | DESI and PMC predecessor inventory guards |

## Failed Attempts And Fixes

| Finding | Fix | Evidence |
| --- | --- | --- |
| After the first Anthropic helper deletion, `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` reported formatting drift. | Ran `cargo fmt --manifest-path packages/agent/Cargo.toml --all`, then reran fmt check successfully. | PMC-1, PMC-8 |
| The shared SSE deletion was discovered as an unclassified pre-compaction edit. | Re-audited `parse_sse_data`, confirmed zero references with `rg -n "parse_sse_data" packages/agent/src packages/agent/tests README.md scripts .github`, and added it as a named reduction batch. | PMC-4, PMC-8 |
| Provider and engine dead-code warnings included fields/methods whose removal would weaken config, catalog, resource, or audit contracts. | Retained them with explicit inventory rows rather than weakening guards or changing public substrate behavior. | PMC-5 |
| First broad `scripts/tron ci fmt check clippy test` run failed at the SACB inventory vocabulary guard for one PMC predecessor row. | Reworded the SACB row to use accepted authority-boundary vocabulary, then reran SACB and broad CI successfully. | PMC-6, PMC-9 |

## Verification Log

| Command | Result | Rows |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | PMC-8, PMC-9 |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::anthropic --lib -- --quiet` | exit 0 | PMC-1, PMC-2, PMC-8 |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::google::stream_handler --lib -- --quiet` | exit 0 | PMC-3, PMC-8 |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::shared::sse --lib -- --quiet` | exit 0 | PMC-4, PMC-8 |
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | PMC-1, PMC-2, PMC-3, PMC-4, PMC-5 |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_minimality_closure_invariants -- --nocapture` | exit 0 | PMC-6, PMC-7, PMC-8, PMC-9 |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_sufficient_agent_runtime_readiness_invariants -- --nocapture` | exit 0 | PMC-6 |
| `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture` | exit 0 | PMC-6, PMC-7 |
| `cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture` | exit 0 | PMC-6, PMC-7 |
| `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | exit 0 | PMC-6 |
| `scripts/tron ci fmt check clippy test` | exit 0 | PMC-9 |
| `scripts/personal-info-guard.sh` | exit 0 | PMC-9 |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | exit 0 | PMC-9 |
| `git diff --check` | exit 0 | PMC-9 |
| `git ls-files -ci --exclude-standard` | exit 0 with empty output | PMC-9 |
| `git status --short` | exit 0 with only committed changes absent after commit | PMC-9 |

## iOS No-Touch Rationale

No Swift, XcodeGen schema, protocol DTO, settings UI, or iOS runtime-shell source
changed in PMC. Validation is therefore XcodeGen drift checking plus inherited
IOSTC static/source gates. iOS 26.5 simulator tests are reserved for Swift,
protocol, or UI behavior changes.

## Residual Risk

The remaining dead-code warnings are not all reducible in one closure pass
without converting provider config/catalog, engine audit query helpers, or
historical proof artifacts into behavior changes. PMC records those surfaces as
retained contracts. A future reduction slice can safely start by proving one
retained contract at a time has no config, catalog, audit, or predecessor-gate
dependency.
