---
name: tron-jev
description: Use Tron's explicit typed Jev decision adapter for bounded workflow decisions, never for chat completion.
---

# Jev typed decisions

Jev evaluates caller-supplied JSON state against named typed `choice`, `noul`,
and `score` questions. It is not a chat model, source store, scheduler, or
workflow policy engine. The first-party `jev` tool sends only the explicit
state/questions supplied by that call; loading the capability does not inspect
Knowledge, Raindrop, files, or interests.

## Safety and authority

The Gateway reads `connector:jev:personal` only through the existing Mac
Keychain credential owner (`Tron Connector Credentials`). Missing credentials
leave core Knowledge and capture available; an explicit Jev call reports that
the capability is not configured. Never put keys in source, environment
variables, argv, chat, or workspace files.

Every caller supplies its own rubric, disclosure boundary, and budget/admission
seam. The shared client owns only fixed TypeSafe endpoint/schema validation,
conservative JSON/body/response bounds, cancellation, and redacted errors. It
allows only configured cost-qualified model revisions and never substitutes an
unknown model or endpoint. Paid POSTs are not automatically retried.

Choice criteria must include the exact candidate keys and the selected answer
must be the highest-probability candidate. Noul answers are numeric 0–1.
Score criteria have 2–10 ordered levels; legends are objects keyed by numeric
strings and probabilities must sum to one with a fractional expected score.
Do not use usefulness as evidence quality or claim novelty without corpus
evidence.

`maxChargeCents` is an explicit per-call guard, not a workflow grant or global
ledger. Resource intake keeps its own durable ≤10-item/≤$1 approval and
per-item attempt receipts. Other workflows must provide their own approval and
before-dispatch authority. No recurring Jev work is implied.

## Validation

Use synthetic fixtures only. Run the focused Gateway Jev/client tests and
`npm run check`; do not perform live provider calls or read credentials while
implementing or testing. Runtime registration is source-only until a maintainer
manually updates the Gateway and confirms the tool availability.
