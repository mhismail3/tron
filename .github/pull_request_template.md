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

<!-- Code, tests, and docs ship together (project AGENTS.md rule #1). -->

- [ ] Tests added or updated (TDD: tests before implementation where practical).
- [ ] `cd packages/agent && cargo check && cargo test -- --quiet` is green locally.
- [ ] Workflow/docs/static-gate changes: `scripts/tron ci fmt check clippy test`, `git diff --check`, and `git ls-files -ci --exclude-standard` are green locally.
- [ ] iOS changes: `xcodegen generate && xcodebuild test -scheme Tron …` is green locally.
- [ ] `scripts/personal-info-guard.sh` is green (no leaked usernames, paths, or domains).
- [ ] [README.md](../README.md) updated per the [README maintenance table](../AGENTS.md#readme-maintenance) for any of: new RPC method, new event, new setting, new tool, new CLI command, new module, new migration, new path constant, new iOS top-level directory.
- [ ] Progressive disclosure docs updated (`mod.rs` submodule tables and package docs) for any module that gained or lost responsibilities.
- [ ] Settings parity: any new server setting has a matching iOS UI control (per [project AGENTS.md "Settings Parity"](../AGENTS.md#settings-parity)).
- [ ] No repo-managed first-party skill surface was added.
- [ ] No personal info, secrets, or `/Users/<my-username>` paths in the diff.

## Screenshots / output

<!-- Optional. Helpful for UI changes or new CLI commands. -->

## Related

<!-- Issues, prior PRs, or plan-file sections. -->
