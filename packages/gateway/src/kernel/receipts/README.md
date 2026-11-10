# gateway/receipts

## Purpose

Canonical invocation, context-delivery, extension activity and notification value
codecs. Producers construct facts here; only the live Run authority persists them.

## Owns

Strict receipt grammar, encoded bounds, duplicate/contradiction refusal, canonical
entry bindings, legal lifecycle folding, captured owner classification and bounded
history read projection. Persisted tags/versions and JSONL stay unchanged. The
invocation lifecycle fold is decided by proof block `receipts/invocation-lifecycle`
([`gateway/core`](../../core/receipts/invocation-lifecycle/facade.ts), generated from `packages/core`):
`invocationProjection` states each receipt to it as a fact (numbers for the invocation and the canonical entry;
whether its operation, source, name and origin are those of its invocation's first start receipt) and writes the
answer back from the receipts the block names. It holds no copy of the fold (`invocation-receipts.test.ts` pins
each projection's fields and order and each refusal's message).

## Not here

Run owns SDK send, persistence, cancellation and terminal decisions. Resources
owns filesystem-backed expansion and resource interpretation; Util owns bounded
summary text. ExtensionActivity owns artifact discovery; Projection renders it.
No runtime, registry, timer, watcher or secondary session is created here.

## Contract

Same-id contradictions fail closed; binding identity and branch order are facts,
not execution admission. Read folds do not authorize a write. The standalone
history module keeps type-only local imports for native source-worker loading.

## Validation

Real Gateway/Pi invocation, delivery, history, attribution and multi-resource
boundary suites remain the oracles; typechecking alone is not qualification.
