<!--
Thanks for the PR! A few things below help reviewers move fast.

Title format: prefer Conventional Commits — e.g. `feat(ios-onboarding): add pairing step`,
`fix(rpc): handle missing token gracefully`, `docs: refresh README RPC table`.
-->

## Summary

<!-- 1–3 bullets describing what this PR does and why. -->

-
-

## Test plan

<!-- What did you do to convince yourself this works? Reviewers will run these too. -->

- [ ]
- [ ]

## Checklist

<!-- Code, tests, and docs ship together (project CLAUDE.md rule #1). -->

- [ ] Tests added or updated (TDD: tests before implementation where practical).
- [ ] `cd packages/agent && cargo check && cargo test -- --quiet` is green locally.
- [ ] iOS changes: `xcodegen generate && xcodebuild test -scheme Tron …` is green locally.
- [ ] `scripts/personal-info-guard.sh` is green (no leaked usernames, paths, or domains).
- [ ] [README.md](../README.md) updated per the [README maintenance table](../.claude/CLAUDE.md#readme-maintenance) for any of: new RPC method, new event, new setting, new tool, new CLI command, new module, new migration, new path constant, new iOS top-level directory.
- [ ] Progressive disclosure docs updated (`mod.rs` submodule tables, `.claude/rules/*.md`) for any module that gained or lost responsibilities.
- [ ] Settings parity: any new server setting has a matching iOS UI control (per [project CLAUDE.md "Settings Parity"](../.claude/CLAUDE.md#settings-parity)).
- [ ] Managed-skill changes synced to `~/.tron/skills/<name>/` (if applicable).
- [ ] No personal info, secrets, or `/Users/<my-username>` paths in the diff.

## Screenshots / output

<!-- Optional. Helpful for UI changes or new CLI commands. -->

## Related

<!-- Issues, prior PRs, plan-file sections (e.g. `~/.claude/plans/*.md §C`). -->
