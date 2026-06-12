# Documentation / Evidence / Scorecard Integrity Inventory

This inventory maps the documentation, evidence, scorecard, inventory, and
static-gate surfaces that DESI depends on. It is paired with
`documentation-evidence-scorecard-integrity-inventory.tsv`, which is
machine-checked by
`documentation_evidence_scorecard_integrity_invariants`.

## Taxonomy

- `root_doc`: root repository documentation and project rules.
- `scorecard`: retained weighted scorecards.
- `evidence_manifest`: retained command/source evidence manifests.
- `inventory`: retained narrative and machine-readable inventories.
- `invariant_test`: Rust static gate targets and closeout tests.
- `local_gate`: local quality script and local closeout target list.
- `github_gate`: GitHub workflow static gate list.
- `review_template`: pull request checklist surface.
- `platform_docs`: iOS and Mac package docs referenced by README.
- `predecessor_inventory`: older inventories that must classify DESI artifacts.
- `branch_handoff`: branch, stale-branch, and pickup evidence.

Classifications:

- `active_current`: current closeout artifact or doc surface that must describe
  current behavior.
- `historical_evidence`: append-style evidence that may retain old failures,
  old branch names, or red/green transition text as provenance.
- `source_truth`: source or rule file that defines current behavior.
- `predecessor_index`: retained inventory index that cross-references later
  slice artifacts.
- `quarry_only`: stale branch or external branch evidence that is not current
  completion evidence.

## Required Handoff Facts

- Current implementation branch:
  `codex/documentation-evidence-scorecard-integrity-current`.
- Base commit:
  `687dc1e1f4b51701452f2ba25c92f34bc018a950`.
- Stale branch:
  `codex/documentation-evidence-scorecard-integrity` at
  `f931c3126a2ee62940f42512278715c9c65c2079`, quarry-only.
- Pickup command:
  `git status --short`.
- Handoff guarantee: another thread can continue without chat history.
- Focused target:
  `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`.
- Broad closeout:
  `scripts/tron ci fmt check clippy test`,
  `scripts/personal-info-guard.sh`, iOS XcodeGen drift check,
  `git diff --check`, `git ls-files -ci --exclude-standard`, and
  `git status --short`.

The TSV rows are explicit so another worker can inspect active artifacts,
historical evidence, predecessor indexes, and gate wiring without reconstructing
the chat.
