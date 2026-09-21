# Tron agent guidance

[AGENTS.md](../AGENTS.md) owns shared engineering rules, architecture invariants,
and safety boundaries. Skills add task-specific procedures; they do not grant
permission to mutate code, data, devices, or a running service. Keep implementation
facts in the owning source and package docs, not copied into skills.

## Skill catalog

| Skill | Use |
|---|---|
| [tron-code-health](skills/tron-code-health/SKILL.md) | Ownership and architecture review, honest exhaustive coverage, deletion-first simplification, and root-cause hardening |
| [tron-test-confidence](skills/tron-test-confidence/SKILL.md) | Behavioral oracles, test cleanup, timing/isolation failures, and controlled mutation or ablation |
| [tron-performance](skills/tron-performance/SKILL.md) | Profiling a demonstrated bottleneck or comparing alternatives under a frozen experiment |
| [tron-ios](skills/tron-ios/SKILL.md) | Required routing for iOS build, test, simulator, device, signing, archive, and artifact work |
| [tron-workspace-housekeeping](skills/tron-workspace-housekeeping/SKILL.md) | Evidence-based post-merge cleanup of branches, inactive worktrees, and stale Git metadata; protect active agents and unmerged work |
| [tron-raindrop](skills/tron-raindrop/SKILL.md) | Bounded, read-only Raindrop bookmark and collection API access through the Mac credential owner |
| [tron-jev](skills/tron-jev/SKILL.md) | Explicit bounded typed Jev decisions; not source retrieval or chat completion |
| [tron-x](skills/tron-x/SKILL.md) | Free public X post lookup, explicit raw-evidence capture, and supervised authenticated bookmark discovery |

For a broad investigation, start with code health and its coverage ledger. Use
test confidence to evaluate the evidence, then performance only where a cost or
comparison warrants measurement. For a bounded task, load only the relevant
procedure; this is not a mandatory multi-skill pipeline. Use workspace housekeeping
for post-merge Git resource cleanup, not code-health or filesystem sweeps. It audits
first and requires approved targets before deletion. Dependency and
configuration changes follow their owning contributor/package runbooks.

## Maintaining guidance

Keep skills under `.agents/skills/`, with a matching directory/frontmatter name,
a concise description, and a link in the catalog above. Do not create parallel
harness copies, compatibility aliases, or a separate skill for every subsystem.
Add a procedure only when it answers a distinct recurring question. Upstream
attribution for adapted guidance remains in [NOTICE.md](skills/NOTICE.md).

Run `scripts/check-agent-policy.sh`, `python3 scripts/test-agent-policy.py`,
`python3 scripts/check-documentation-policy.py`, and
`scripts/personal-info-guard.sh` after changing guidance. The agent-policy checker
compares skill directories with this catalog and validates metadata and platform guards;
it deliberately does not enforce repeated prose or a second hard-coded inventory.
