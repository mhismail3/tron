---
name: tron-dependency-upgrader
description: Upgrade Tron npm, Swift/Xcode, bundled runtime, and tool dependencies in small reversible batches with official migration research and focused verification. Use for dependency maintenance, not modernization.
---

# Tron Dependency Upgrader

Upgrade only the approved dependency scope. Newer is not inherently better.
Preserve exact pins, lockfiles, supported runtimes, signed artifact contracts,
and product behavior; attribute every failure to a small batch.

## Tron dependency constraints

- `.node-version` is the exact repository-wide Node toolchain pin; package
  `engines` are compatibility minimums.
- Use native package managers and repository generation/staging helpers. Never
  hand-edit lockfiles, generated Xcode projects, or bundled payload manifests.
- The pinned backing Pi SDK may be named in dependency/source documentation, but
  Tron remains the user-facing product. Verify supported SDK exports and Gateway
  protocol/artifact projections together.
- Signed artifacts are authoritative for Apple environments. Load `tron-ios`
  before any iOS build, scheme, signing, archive, simulator, or device work.

## Hard boundaries

Read `AGENTS.md`, `CONTRIBUTING.md`, owning package docs, manifests, lockfiles,
CI, and Git status. Preserve user changes. Never publish packages, deploy,
release, archive/upload, rotate credentials, replace `/Applications/Tron.app`,
install on a device, or initiate any Gateway lifecycle transition. Do not run
untrusted dependency lifecycle scripts outside the repository's normal safeguards.

## Workflow

1. **Inventory.** Find all manifests, lockfiles, workspace files, runtime/toolchain
   pins, registries, generated dependency metadata, bundled runtimes, CI matrices,
   and application/library/plugin/build-tool deliverables.
2. **Freeze scope.** Classify security-only, selected package, patch/minor, major,
   toolchain/runtime migration, or complete refresh. Record baseline install,
   build, focused tests, audits, advisories, deprecations, and peer conflicts.
3. **Research exact transitions.** Use official release notes, migration guides,
   support tables, advisories, registries, and upstream source for consequential
   updates. Check runtime/OS/architecture support, defaults, peer constraints,
   APIs, config, generated output, license, provenance, and exploit reachability.
4. **Trace usage.** Search imports, symbols, plugins, scripts, dynamic loading,
   generated code, build settings, artifact staging, and runtime registration.
   Treat removal of unused/abandoned dependencies as separate scope requiring
   evidence and approval when not requested.
5. **Plan batches.** Order package manager/runtime, build tools, foundational
   libraries, frameworks, integrations, then leaves. Group only inseparable peer
   families or generated clients. Stop for product direction on runtime support,
   license, registry, public compatibility, or mutually exclusive strategies.
6. **Apply natively.** Use the expected package manager/tool version and narrowest
   update command. Inspect immediate diff and resolved graph for broad churn,
   registry drift, accidental downgrade, duplicate majors, ignored peers, new
   install scripts, changed optional features, or transitive substitutions.
7. **Verify each batch.** Prove clean-enough restore/install reproducibility, then
   run the smallest owning build/tests and affected API/artifact checks. Expand to
   required OS/architecture/package cells only after focused checks pass. Compare
   bundle/startup/performance when the update can materially alter them.
8. **Keep or revert.** Mark `KEPT`, `REVERTED`, or `SKIPPED`. Revert the entire
   failed run-owned batch without touching user work; establish each kept state as
   the next baseline. Re-run audits and final relevant repository gates.

## Report

Use `UPDATED` when every requested batch is kept and verified; `PARTIAL` when an
independent subset is kept; `NO_CHANGE` when baseline is restored; `BLOCKED` when
no safe batch or required verification exists.

Report exact version changes, direct/important transitive changes, code/config/doc
migrations, batch decisions, advisory reachability, lockfile/generated churn,
commands and results, skipped constraints, cleanup, and residual compatibility or
maintenance risk.
