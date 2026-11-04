# Draft "Layout" sections (≤12 lines each) and the root README map

Each package README gets one `## Layout` section, the breadcrumb an agent reads on arrival.
Budget: ≤12 lines per section; `check-documentation-policy.py` keeps package READMEs ≤ 2×200.

## Root README.md "Repository" block (replaces the current block)

```text
packages/gateway/    TypeScript Gateway, its tests, Pi pins and package tooling
packages/ios-app/    SwiftUI iPhone app, share extension and XCTest targets
packages/mac-app/    macOS app, Gateway payload build and Mac tests
packages/push-relay/ closed Cloudflare/APNs transport
packages/web/        Builds mini-app sources, UI-test previews, shared tron.css
packages/protocol-fixtures/ wire constants shared by Gateway, scripts and iOS
scripts/             `scripts/tron` and repo tooling by area (scripts/README.md)
config/              version, toolchain pins, protocol and push configuration
docs/                principles and the repository runbook
```

## packages/gateway/README.md

```markdown
## Layout
- `src/<module>/` code with its `*.integration.test.ts` / `*.e2e.test.ts` beside it, never in
  a `tests/` folder; goldens in `src/<module>/locks/`, small fixtures in `src/<module>/fixtures/`.
- `test-support/` shared harness code; `test-fixtures/` recorded corpora (rewritten only by the
  corpus config). Production code never imports either (`tsconfig.json` rootDir is `src/`).
- `scripts/` Gateway-only tooling (Pi SDK/pi-subagents updaters, release dates) with
  `*.integration.test.mjs` beside it; `artifacts/` and `third_party/` hold only what
  `pi-subagents-pin.json` and `pi-coding-agent-patch.json` reference.
- Each module directory has its `<name>.module.json`; a new module gets one and a layer.
```

## packages/ios-app/README.md

```markdown
## Layout
- App code: `Sources/` (UI by feature, State, Auth, Notifications), frameworks `Core/` and
  `SwiftAppEngine/`, `ShareExtension/`, SwiftPM `MacTerminalSSH/`.
- Tests only in XCTest targets: `UITests/` (locks and goldens in `UITests/Locks/`),
  `E2ETests/`, `ProfilingTests/`, `SwiftAppUITests/`. No `*Tests.swift` under `Sources/`.
- `Fixtures/` hosted fixtures compiled into the app target; `scripts/` iOS-only build and
  source-policy tooling; `Configuration/`, `TestPlans/`, `project.yml` build inputs.
- Edit `project.yml`, then `scripts/tron ios generate`; never edit the generated project.
```

## packages/mac-app/README.md

```markdown
## Layout
- App code `Sources/<area>/`; SwiftPM packages `native-computer-control/`, `native-gateway-client/`.
- Tests: `Tests/Integration/`; helper probes `Tests/Fixtures/<Probe>/`.
- `scripts/` owns the Gateway payload build (bundle, stage, hash, verify, deploy helper,
  install-input fingerprint) and its tests; `Sources/Resources/Gateway/` is generated, ignored.
- Edit `project.yml`, then `scripts/tron mac generate`.
```

## packages/push-relay/README.md

```markdown
## Layout
- Worker code `src/`; Workers-pool tests `tests/` (`*.integration.test.ts`, run by
  `vitest.config.ts`); build output `dist*/` is ignored.
```

## packages/web/README.md (moved from tools/web/README.md, add)

```markdown
## Layout
- `apps/builds/` the Builds mini-app offered by Home; `apps/builds-preview/` UI-test copies
  bundled by `packages/ios-app/project.yml`; `tron.css` shared by static share pages.
```
