# Ground-up structure program (#2297)

Goal: for every unit (file, module, work area) an agent can say what it is for, what reaches it,
what it reaches and which named check goes red when it breaks, from that module's card alone.
If nobody can tell what a cleanup would break, the structure is the defect. Builds on the
[structure plan](structure-plan.md) (#2276), whose layout guards stay; its S3/S4 folder moves
are folded in here: a file moves only when a removal probe shows the move is needed.

## Tools

| Need | Owner | Gate |
|---|---|---|
| Every tracked file has exactly one owner | `scripts/tron ownership` | verify step 1 |
| Purpose card: purpose, inbound interfaces with consumers, guardians; outbound derived | [cards](../../tools/ownership/README.md#purpose-cards) | same step; undeclared, stale or half-moved references and dead files fail |
| Read one module's card and found dependents before editing | `scripts/tron ownership --card <path>` | none (read) |
| What would break if a unit were removed or moved | [`scripts/tron probe`](../../tools/verify/README.md#removal-probes) | measures; verdict precise, cascade or silent |
| Agent residue | `scripts/tron tidy --here` | `--landing` part is a verify step; the full check before `report` (AGENTS.md) |
| Sprawl over time | `scripts/tron metrics` `M4.structure` and the [scorecard](scorecard.md) | measures |

Exemptions shrink only: `layout.uncarded` in `root.module.json` lists modules not yet carded,
and a new module is carded from birth.

## Per-slice method

Bottom-up, leaves of the dependency graph first (modules nothing else names).

1. Card the module: one-sentence purpose, interfaces from `--card`'s found dependents plus
   outside invokers, guardians. Remove it from `layout.uncarded`.
2. Probe every owned non-test file. Decide keep, merge, move or delete from first
   principles (what need it serves today, who else serves it).
3. Fix structure defects: **silent** (dead: delete; unguarded: add a test that fails before
   and passes after), **cascade** (make the failing check name what it needs), hidden links
   the card exposed (one owner for a duplicated value or rule).
4. Gates: fail-before/pass-after for every new or changed test, `scripts/tron verify
   --changed`, a fresh independent reviewer's ACCEPT, a plain-Git `--no-ff` land; the async
   full run follows (PRINCIPLES P2).

Golden or screenshot re-records and timeout, tolerance or assertion changes are allowed with
an independent ACCEPT plus fail-before/pass-after, recorded in the commit message and on the
epic; never to make a red go green. Persisted-format changes need the maintainer.

## Order

1. Pilot: `scripts/` and `tools/` (16 modules).
2. `packages/push-relay` (isolated leaf), then `packages/mac-app` scripts and payload modules.
3. `packages/gateway` from leaves inward: contract modules, `modules/*`, `providers`,
   `sessions`, then the kernel (`kernel/run`, `kernel/session`) last.
4. `packages/ios-app`: Swift reachability comes from the index store (`scripts/tron layers
   ios`), not path references; feature UI first, `AppModel.swift` last.
5. The two largest files last: `packages/gateway/src/sessions/runtime-registry.integration.test.ts`
   and `packages/ios-app/Sources/State/AppModel.swift`.
