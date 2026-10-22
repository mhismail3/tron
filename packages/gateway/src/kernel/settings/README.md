# gateway/settings

## Purpose

The kernel-neutral settings tool contract, shared by the session context and
settings implementation. This boundary carries values, not settings owners.

## Owns

`tool-contract.ts`: layer/tier/qualifier vocabulary, retired scope-name mapping
shared by session readers and store migration, and tool request, resolution,
result and worker-state interfaces.

## Contract

`SettingsToolAccess` resolves and changes the current session settings and drains
its pending outcomes. Concrete precedence, validation, approvals and writers stay
in admin; the session runtime supplies its own identity and appliers.

## Invariants

- No settings data, wire shape, persisted schema or policy is defined twice.
- Tool access is resolved at call time, never captured before settings start.

## Entry points

`SettingsToolAccess`, `ChangeRequest`, `ChangeResult`, `Resolution`.

## Signals

None; the settings implementation owns its change records.

## Verify

```bash
scripts/tron verify --changed
```

The real settings and run locks cover consumers of this contract.

## Not here

Settings implementation and UI metadata: [admin](../../admin/README.md).
