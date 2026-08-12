## Summary

-
-

## Test plan

- [ ] Focused owner checks (list exact commands/results)
- [ ] Broader checkpoint checks when applicable

## Checklist

- [ ] Implementation, focused tests, and owning docs changed together.
- [ ] Gateway changes: `cd packages/gateway && npm run build && npm test && npm audit --omit=dev`.
- [ ] iOS changes used incremental `build-for-testing` plus focused `test-without-building`; full unit/UI checkpoints are listed when run.
- [ ] Mac changes used `bundle-gateway.sh` when packaging was affected, then incremental focused tests.
- [ ] `scripts/personal-info-guard.sh` and `git diff --check` pass.
- [ ] User-facing terminology calls the product and agent Tron.
- [ ] No provider credentials, device tokens, personal paths, handles, or domains entered source/fixtures.
- [ ] New mutations carry command IDs and preserve per-session serialization.
- [ ] Trust/executable-resource copy does not imply sandboxing.
- [ ] No automated production deployment path was added or invoked; the existing internal TestFlight beta lane remains beta-only.

## Screenshots / output

## Related
