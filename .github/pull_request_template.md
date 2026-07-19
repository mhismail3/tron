<!--
Thanks for the PR! A few things below help reviewers move fast.

Title format: prefer Conventional Commits — e.g. `feat(ios-onboarding): add pairing step`,
`fix(events): reject a mismatched session`, `docs: update protocol reference`.
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

- [ ] Existing tests cover the change, or tests were added/updated for changed behavior or a genuine gap.
- [ ] Validation is proportionate to the changed owners; exact commands and results are listed above.
- [ ] Rust or CI changes: `scripts/tron ci fmt check clippy test` and `git diff --check` are green locally.
- [ ] iOS changes: `cd packages/ios-app && xcodegen generate && xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` is green locally.
- [ ] Mac changes: `cd packages/mac-app && ./scripts/bundle-agent.sh --profile debug && xcodegen generate && xcodebuild test -project TronMac.xcodeproj -scheme TronMac -destination 'platform=macOS' -configuration Debug` is green locally.
- [ ] `scripts/personal-info-guard.sh` is green (no leaked usernames, paths, or domains).
- [ ] Documentation updated at the narrowest owner per the [documentation maintenance map](../AGENTS.md#documentation-maintenance); the root README changed only when product-level setup or workflow changed.
- [ ] Progressive disclosure docs updated (`mod.rs` submodule tables and package docs) for any module that gained or lost responsibilities.
- [ ] Settings parity: any new server setting has a matching iOS UI control (per [project AGENTS.md "Settings Parity"](../AGENTS.md#settings-parity)).
- [ ] No repo-managed first-party skill surface was added.
- [ ] No personal info, secrets, or `/Users/<my-username>` paths in the diff.

## Screenshots / output

<!-- Optional. Helpful for UI changes or new CLI commands. -->

## Related

<!-- Issues or prior PRs. -->
