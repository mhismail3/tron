# Primitive Minimality Closure Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**
Total weight: **100**

Current implementation branch: `codex/primitive-minimality-closure-current`.
Baseline: `7b03b51f5476f5764e3813666137897af2f3cd3d`
(`docs: harden runtime readiness evidence`). `git merge-base --is-ancestor
7b03b51f5476f5764e3813666137897af2f3cd3d HEAD` is the lineage gate for this
slice.

Scope quarantine: PMC is a minimality closure pass over the primitive-engine
lineage. It removes or collapses only source-backed non-essential residue whose
behavior is covered by focused tests and predecessor invariants. It does not
implement successor features, widen `/engine`, add provider/settings/auth/DB/iOS
DTO surface area, or touch deploy behavior.

| Row | Name | Points | Status | Closure |
| --- | --- | ---: | --- | --- |
| PMC-0 | Baseline lineage and regression contract | 5 | passed | HEAD descends from SSARR baseline `7b03b51f5476f5764e3813666137897af2f3cd3d`; baseline CI, personal-info guard, and XcodeGen drift checks were green before teardown edits. |
| PMC-1 | Dead Anthropic request-helper removal | 12 | passed | Removed unused `SystemPromptBlock::text_cached` and Anthropic JSON request block helper constructors from `types`; retained provider-native request construction and focused Anthropic provider tests. |
| PMC-2 | Anthropic converter facade collapse | 10 | passed | Removed the unused `convert_context` facade and duplicate private `convert_tools`; provider-owned `build_tools` remains the single Anthropic tool-definition path with cache control. |
| PMC-3 | Google stream-state residue removal | 10 | passed | Removed unused `completed_tool_ids` state and test-only `synthesize_done_event`; Gemini finish handling remains owned by `handle_finish` and stream-handler tests. |
| PMC-4 | Shared SSE parse helper collapse | 8 | passed | Removed unused `parse_sse_data`; the shared stream pipeline continues to deserialize provider SSE lines directly after `parse_sse_lines`. |
| PMC-5 | Runtime suspicious-surface retention audit | 12 | passed | Retained provider config/catalog fields and engine list/query helpers only where removal would break serde/config/catalog/resource audit contracts or weaken public substrate proof. |
| PMC-6 | Proof-layer and predecessor inventory parity | 12 | passed | Added PMC scorecard, evidence, inventory, machine inventory, and invariant target; local/GitHub closeout target sets and predecessor inventories classify the new artifacts. |
| PMC-7 | README and progressive-doc current-truth sync | 8 | passed | Updated README living-doc/testing maps and provider docs so canonical docs describe the current provider conversion paths rather than removed helper history. |
| PMC-8 | Focused teardown validation | 8 | passed | Focused Anthropic, Google stream-handler, shared SSE, and PMC invariant checks cover each deletion batch and replacement path. |
| PMC-9 | Broad final closeout and clean handoff | 15 | passed | Full local CI, personal-info guard, XcodeGen drift, diff whitespace, ignored-file, and status checks are recorded in the evidence manifest with failed attempts and fixes. |

## Closure Verdict

The primitive engine is smaller after this pass in three runtime areas:
Anthropic request helper scaffolding, Google stream residue, and shared SSE JSON
parse indirection. The retained warnings are classified as provider wire/config
contracts, catalog metadata, engine audit substrate, or historical proof
artifacts. Further reduction should start from the PMC inventory rather than
from chat history.
