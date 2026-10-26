# gateway/automations-contract

## Purpose

Capability-owned persisted identity codecs shared by Automations and session
catalog discovery, independent of scheduling, dispatch and admission policy.

## Owns

`identity.ts`: the Automation UUID predicate, operation-ID encoder and decoder.
The scheduler, executor, durable-record validator and cold catalog reader import
this owner directly; none needs the L3 scheduler's admission implementation.

## Contract

UUID versions 1–5 and the existing variant are matched case-insensitively.
Operation IDs retain the `automation:<UUID>` shape; decoding preserves the
captured UUID's case. Invalid encoder input throws; unmatched decoding returns
`undefined`. These codecs do not normalize persisted identifiers.

## Lifecycle

Stateless: no timers, IO, runtime references or registration. Scheduling and
record/action/trigger admission remain in `../../automations/`.

## Verification

The manifest selects unchanged real Gateway/Pi owned-run, durable store and
scheduler journeys. The existing `runtime-registry.integration.test.ts` case
“recovers Automation session creation origin from the first canonical invocation
binding” covers catalog discovery through cold and durable-indexed Registry reads.
