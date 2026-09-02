---
name: tron-test-suite-auditor
description: Audit whether Tron's Gateway, iOS, Mac, relay, and policy tests provide trustworthy risk coverage, isolation, and sustainable lifecycle control. Use for test-confidence reviews, not test implementation.
---

# Tron Test Suite Auditor

Audit the existing test portfolio as read-only evidence. Do not update snapshots,
goldens, fixtures, generated projects, or product code. Coverage and pass counts
show execution, not meaningful proof.

## Tron test routing

- Start with the smallest owning unit, contract, fixture, state, or policy test.
- Gateway: build and run one owning Vitest file under `packages/gateway`.
- iOS: load `tron-ios`; use `scripts/tron-ios-test build` then
  `scripts/tron-ios-test run --only-testing TronMobileTests/<Suite>`.
- Mac: generate only when required, build for testing once, then run one owning
  `TronMacTests/<Suite>` with `test-without-building`.
- Reserve full suites and `scripts/tron-ios-test checkpoint` for a final
  cross-module checkpoint, not diagnosis.
- Never invent scheme/configuration pairs, erase simulator/device/Keychain data,
  or install on a device owned by another workflow.

## Safety boundary

- Read `AGENTS.md`, `CONTRIBUTING.md`, CI configuration, and owning test docs.
- Never initiate Gateway lifecycle transitions, deployment, release, archive,
  signing, physical-device install, production access, or mutation of canonical
  sessions/data to exercise a test.
- Keep first-failure logs, seeds, order, worker identity, and environment. Do not
  turn retries, quarantine, or skipped cases into a pass.

## Workflow

1. **Map the portfolio.** Inventory runners, configurations, required CI gates,
   unit/integration/contract/end-to-end/manual suites, fixtures, clocks, fakes,
   snapshots, coverage, retries, quarantine, and generated areas.
2. **Map product risk to evidence.** Trace critical authentication, authorization,
   canonical ownership, command idempotency, reconnect, serialization, bounded
   resources, data integrity, packaging/signing metadata, and recovery behavior
   to tests whose oracle would fail for the defect.
3. **Run a representative baseline.** Execute the narrowest safe owner for each
   question. Record duration, status, skips, retries, artifacts, and environment.
   Expand only after focused evidence passes or the wider boundary is the risk.
4. **Inspect isolation.** Check database/filesystem/environment/process/network/
   clock/random/global state, cleanup on every exit, unique ownership markers,
   parallel execution, cancellation, and bounded waits. Diagnose suspected flakes
   alone, in-suite, repeated with fixed seed, shuffled, and parallel when supported.
5. **Inspect oracle strength.** Reject assertion-free or framework-reproof tests,
   implementation-derived expected values, snapshot-only critical proof, mocks
   that bypass ownership, and UI locators tied to copy/layout/timing. Prefer stable
   repository-owned IDs and observable durable or user-visible outcomes.
6. **Control lifecycle.** Identify obsolete migration/compatibility/regression
   tests, duplicate fixtures, orphan tests, broad slow gates, and missing retirement
   triggers. Preserve a test when it is the only trusted proof of a rare critical risk.

## Portfolio decisions

For every material risk or affected test choose one action:
`KEEP`, `ADD`, `UPDATE`, `MERGE`, `DELETE`, or justified `NO_TEST`. Keep that
action separate from execution status: `PASS`, `FAIL`, `BLOCKED`, `UNPROVEN`, or
`QUARANTINED`. A deletion or merge must preserve all still-required behaviors and
failure modes with equal or better evidence.

Use `FAIL` when a required gate fails, a critical behavior is unproven, or a
critical surface provides false confidence; `CONCERNS` for non-blocking portfolio
risk; `BLOCKED` when a required environment/oracle has no safe fallback; otherwise
`PASS`.

## Report

Return portfolio map, commands and artifacts, critical-risk confidence matrix,
portfolio actions, isolation/oracle findings with exact paths, gate cost and
quarantine evidence, unexecuted environments, and residual test risk. Do not
implement the recommendations while using this skill.
