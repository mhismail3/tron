---
name: tron-documentation-auditor
description: Audit Tron documentation, examples, comments, and runbooks for discoverability, factual accuracy, canonical ownership, and safe operator guidance. Use for documentation trust reviews, not code or architecture audits.
---

# Tron Documentation Auditor

Perform a read-only documentation audit. A useful finding must identify a real
reader task that is blocked, unsafe, contradictory, or costly to maintain.
Do not edit files while using this skill.

## Tron authority map

- `README.md`: product front door; keep it under 250 lines.
- `CONTRIBUTING.md` and `scripts/tron --help`: contributor workflow.
- `packages/gateway/README.md`: Gateway contracts and invariants.
- `packages/ios-app/docs/`: iOS architecture, development, and events.
- `packages/mac-app/docs/`: Mac architecture and development.
- `.agents/README.md` and `.agents/skills/`: agent workflow guidance.
- Source, schemas, manifests, lockfiles, generated metadata, and signed artifacts
  outrank prose when they own the fact. Runtime JSONL and owned stores remain
  canonical; mobile caches and Gateway snapshots are projections.

## Safety boundary

- Read `AGENTS.md` and the nearest package guidance before checking claims.
- Never run a Gateway rebuild, update, rollback, promotion, restart, mutating
  `scripts/tron dev` command, deployment, release, archive, device install, or
  data migration to verify documentation.
- Use read-only help/status/preflight commands or inspect command registration
  and tests when execution would cross that boundary.
- For iOS commands, signing, schemes, or artifacts, load `tron-ios` and treat
  `packages/ios-app/project.yml` plus signed artifact metadata as authoritative.
- Never print secrets or personal data. Redact evidence and run
  `scripts/personal-info-guard.sh` only as a read-only repository check.

## Workflow

1. **Set scope and audiences.** Inventory entrypoints, runbooks, references,
   generated docs, examples, and contract-bearing comments. Name the user,
   contributor, operator, or agent task each surface must support. Exclude
   vendored, generated, archived, and temporary content explicitly.
2. **Check navigation and ownership.** Verify links, anchors, file paths, heading
   hierarchy, discoverability, and one canonical owner per mutable rule. Flag a
   duplicate only when it can drift or send a reader to the wrong owner.
3. **Build a claim ledger.** Extract material paths, commands, flags, versions,
   schemes, ports, protocol ranges, defaults, state owners, lifecycle actions,
   and recovery steps. Group repeated claims by subject.
4. **Verify claims.** Prefer direct source/configuration, safe command output,
   tests, and current official platform documentation. Record exact paths and
   commands. Mark examples statically verified when execution is unsafe.
5. **Review durability.** Find copied implementation inventories, stale legacy
   architecture, hidden prerequisites, future-tense plans already completed,
   unsafe lifecycle wording, misleading comments, and missing update triggers.
6. **Apply materiality.** Reject prose taste, cosmetic consistency, generic best
   practice, and optional coverage with no reader need. Deduplicate findings by
   canonical correction.

## Evidence and severity

- Every finding needs location, contradicted authority, affected audience,
  concrete outcome, and the smallest sufficient correction.
- `P0`: guidance can cause credential/data loss or an unauthorized production
  action. `P1`: a required setup, build, recovery, or safety journey is wrong.
  `P2`: material contradiction or recurring drift. `P3`: bounded friction.
- Use `BLOCKED` when a safety-critical claim or required authority cannot be
  checked safely; `FAIL` for unresolved P0/P1; `CONCERNS` for material P2/P3;
  `PASS` only when required journeys and material claims are trustworthy.

## Report

Return:

1. verdict and audited/excluded scope;
2. audience journeys and claim sources checked;
3. findings ordered by risk, each with path/line evidence and canonical owner;
4. recommended `KEEP`, `ADD`, `UPDATE`, `MERGE`, or `DELETE` action;
5. unverified claims, commands not run for safety, and residual trust risk.
