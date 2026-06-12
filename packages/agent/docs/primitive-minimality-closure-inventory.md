# Primitive Minimality Closure Inventory

Status: PMC-9 `passed`; 25 runtime/proof/documentation surfaces inventoried and
classified.

Machine-readable rows live in
[`primitive-minimality-closure-inventory.tsv`](primitive-minimality-closure-inventory.tsv).

## Controlled Vocabulary

`closure_action` values:

| Value | Meaning |
| --- | --- |
| `removed` | Source or tests were deleted because focused checks proved another owner already held the behavior. |
| `collapsed` | A facade or duplicate helper was removed and the canonical owner remains. |
| `retained_contract` | The surface looks suspicious but is kept because removal would alter a config, catalog, public, storage, or audit contract. |
| `historical_evidence` | Artifact is retained as provenance, not current runtime behavior. |
| `static_gate` | Test, README, CI, or inventory guard that prevents regression. |
| `baseline` | Branch and command evidence anchoring the closure slice. |

## Source Findings

### Removed Runtime Residue

- Anthropic request helper constructors were deleted from `types`; production
  conversion already builds JSON blocks in `message_converter` and request
  assembly in `provider`.
- Anthropic `convert_context` and converter-local `convert_tools` were removed;
  provider request assembly keeps the single live tool-definition owner.
- Google stream state no longer stores unused completed-tool IDs, and the
  test-only done-event synthesizer was removed.
- Shared SSE JSON parsing no longer has an unused wrapper; the shared stream
  pipeline deserializes immediately after line parsing.

### Retained Contracts

- Provider config and provider settings structs remain wider than current call
  sites because they are serde/profile/auth contract surfaces.
- Provider catalog metadata remains even when one field is not read in the
  narrow cargo-check path because catalogs feed API metadata and model-support
  decisions.
- Engine trace and resource query helpers remain because ODA, DSEMD, SOL, and
  replay evidence rely on inspectable substrate, not only current transport
  callers.
- Historical scorecards and inventories remain append-oriented proof. PMC
  reduces live behavior and classifies proof artifacts; it does not erase
  provenance.

## Closeout Policy

Every removed or collapsed row names its owner, why the surface was
non-essential, and the focused gate that preserves behavior. Every retained row
names the contract that would break if the surface were deleted. Future
primitive-minimality work should extend this inventory instead of relying on
chat context.
