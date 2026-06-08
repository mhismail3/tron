# Primitive Code Cleanup Evidence Manifest

Created: 2026-06-08

Current score: **17/100**

Status: **active**

Scorecard:
[`primitive-code-cleanup-scorecard.md`](primitive-code-cleanup-scorecard.md)

## Baseline Evidence

| Evidence | Result |
|----------|--------|
| Branch | `codex/primitive-engine-teardown` |
| Worktree status | `git status --short` produced no output before setup edits. |
| Plan source | `/Users/moose/Downloads/PLAN.md` |
| Cleanup skill | `scorecard-goal-runner` loaded for scorecard-driven execution. |
| README/context | Root `README.md` describes the primitive branch and canonical build/test entry points. |
| Ledger context | Prior Tron ledger lessons queried before implementation. |
| Tracked junk scan | `git ls-files \| rg '(^\|/)__pycache__/\|\\.pyc$\|\\.xcresult/\|(^\|/)target/\|(^\|/)node_modules/'` returned exit 1/no matches. |
| Current top-level tracked directories | `.claude`, `.codex`, `.github`, `packages`, `scripts`. |
| Current Rust source roots | `app`, `transport`, `engine`, `domains`, `shared`, `platform`. |
| Current iOS source roots | `App`, `Core`, `Database`, `Extensions`, `IconLayers`, `Models`, `Protocols`, `Resources`, `Services`, `Theme`, `Utilities`, `ViewModels`, `Views`, `Assets.xcassets`. |
| Current Mac source roots | `MenuBar`, `Services`, `Theme`, `Wizard`, `Resources`, `Assets.xcassets`. |

## Row Evidence Ledger

| Row | Status | Evidence | Verification | Residual risk |
|-----|--------|----------|--------------|---------------|
| PCC-0 | passed_after_fix | Added `primitive-code-cleanup-scorecard.md`, `primitive-code-cleanup-evidence-manifest.md`, `primitive_code_cleanup_invariants.rs`, README living-doc links, initial folder-justification table, large-file budget table, and living-doc wording that keeps deleted product terms out of ordinary docs/source. Red proof: `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants` -> exit 101, 4 passed/1 failed because `packages/ios-app/.claude/rules/app-lifecycle.md` still contained a retired media workflow title. Second red proof after that fix -> exit 101, 4 passed/1 failed because `packages/ios-app/Tests/Views/Settings/AgentContextSettingsPageTests.swift` still contained a retired extension-source title in a non-static test. Green proof after generalizing those strings: same command -> exit 0, 5 passed. Deleted-term scan `rg -n "AgentControl|Agent Control|PromptLibrary|Prompt Library|VoiceNotes|Voice Notes|SourceControl|Source Control|AuditDetails|Audit Details|Plugin Sources|SessionTree|postProcessing" README.md packages/ios-app/docs packages/mac-app/docs AGENTS.md packages/ios-app/.claude .claude .codex .github packages/agent/src packages/ios-app/Sources packages/mac-app/Sources scripts packages/ios-app/Tests packages/agent/tests --glob '!primitive-engine-teardown-*' --glob '!primitive-code-cleanup-*' --glob '!primitive_engine_teardown_plan_invariants.rs' --glob '!primitive_code_cleanup_invariants.rs' --glob '!SourceGuardTests.swift'` -> exit 1/no matches. | `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants` -> exit 0, 5 passed. | None. |
| PCC-1 | passed_after_fix | Added `primitive-code-cleanup-inventory.md` and `primitive-code-cleanup-file-inventory.tsv`. Source audit commands: `git status --short` -> clean after PCC-0; `git ls-files` -> 1337 tracked files before inventory artifacts; `find packages/agent/src -name mod.rs -print | sort` listed Rust progressive-disclosure module docs; `find packages/ios-app/Sources packages/mac-app/Sources -maxdepth 3 -type d -print | sort` captured current client source trees; package count command reported `.claude` 6, `.codex` 2, `.github` 8, root 5, `packages/agent` 533, `packages/ios-app` 644, `packages/mac-app` 115, `scripts` 24. The generated inventory covers 1339 paths including the two new inventory artifacts: 686 retain, 551 collapse, 74 asset, 21 delete, 7 generated. Delete candidates are `packages/agent/assets/capability-search/embeddings/all-MiniLM-L6-v2/` and `packages/agent/examples/local-packs/`; no files were deleted in this row. | `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants` -> exit 0, 6 passed; `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `git diff --check` -> exit 0. | Collapse/delete work remains owned by PCC-3 through PCC-9. |
| PCC-2 | pending | Initial tracked-junk scan was clean. | Pending row proof. | Unknown. |
| PCC-3 | pending | Not run. | Pending. | Unknown. |
| PCC-4 | pending | Not run. | Pending. | Unknown. |
| PCC-5 | pending | Not run. | Pending. | Unknown. |
| PCC-6 | pending | Not run. | Pending. | Unknown. |
| PCC-7 | pending | Not run. | Pending. | Unknown. |
| PCC-8 | pending | Not run. | Pending. | Unknown. |
| PCC-9 | pending | Not run. | Pending. | Unknown. |
| PCC-10 | pending | Not run. | Pending. | Unknown. |

## Checkpoint Rules

- Record every command with exit code and relevant artifact paths.
- Record exact file moves/deletions and static-gate updates.
- Do not award points for intended cleanup; points require committed code,
  docs, tests, and evidence.
- If a row fails, stop breadth work, classify the owner, fix the owning module,
  rerun the exact failed proof, update this manifest, and commit the coherent
  checkpoint.
