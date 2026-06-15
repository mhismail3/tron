# iOS Affordance Restoration Map Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**
Total weight: **100**

Current implementation branch: `codex/ios-affordance-restoration-map-current`

Old reference: `ad5e484722c6f7abbe764126409494026216ad92`
(`next/modular-capability-engine` comparison point from the primitive feature
index).

Baseline: `a0b80c7d204cf9349a5f647ecbc58a8a37735e15`
(`Restore emerald iOS primary accent`). This is the clean IOSAC-era baseline
used for the map. `git merge-base --is-ancestor
a0b80c7d204cf9349a5f647ecbc58a8a37735e15 HEAD` is the lineage gate for this
goal.

Scope quarantine: IARM is an audit, classification, static-gate, and handoff
goal only. It does not restore Swift UI features, add server capabilities,
expand provider-visible tools, add public `/engine` methods, add product DTOs,
add database tables, run XcodeGen, or launch simulator tests. Future iOS
affordance slices must be proposed and validated one at a time from the review
queue in the inventory.

| Row | Name | Points | Status | Closure |
| --- | --- | ---: | --- | --- |
| IARM-0 | Baseline and scope | 5 | passed | Branch, old reference, clean IOSAC baseline, no-feature-implementation scope, and lineage gate are recorded. |
| IARM-1 | Exhaustive old-tree census | 15 | passed | The inventory covers every deleted or renamed old iOS path from the old reference: 848 old paths total, including 567 source paths, 266 tests, 2 docs, and 13 old rule files. |
| IARM-2 | Current surface match | 10 | passed | Current retained equivalents are mapped for chat, attachments, onboarding, settings, diagnostics, runtime surfaces, Agent cockpit, capability result rendering, theme, pairing, logs, event persistence, and engine transport. |
| IARM-3 | Affordance taxonomy | 10 | passed | Every inventory row uses the controlled classifications for local iOS, server-fact rendering, review-only concepts, Phase 2 agent execution, superseded shell behavior, or reject candidates. |
| IARM-4 | Phase 1 review queue | 15 | passed | The queue starts with local-native functional UX: composer/menu sheets, dictation/audio capture, prompt/input affordances, chat visual cues, settings/onboarding/diagnostics polish, notification concept review, and remaining local-native affordances. |
| IARM-5 | Phase 2 deferral map | 10 | passed | Agent-execution-dependent surfaces are deferred with BPRC bucket links for capability discovery, filesystem, jobs/processes, git/worktrees, subagents, approvals, skills/rules/memory, MCP, scheduling, web, program execution, storage, events, settings, and dependencies. |
| IARM-6 | First-principles UX rubric | 10 | passed | Future slices must answer whether the affordance is a useful long-term signal for an autonomous self-updating agent, improves user work, and can be expressed in the simplest minimal utilitarian form without legacy-default copying. |
| IARM-7 | Static gate | 10 | passed | `ios_affordance_restoration_map_invariants` verifies artifacts, score total, TSV coverage, classification vocabulary, old-tree path coverage, Phase 2 reminder coverage, README/docs wiring, and local/GitHub target parity. |
| IARM-8 | Docs and README integration | 7 | passed | README and iOS architecture docs point to the map as the active restoration planning artifact without claiming that mapped affordances are already restored. |
| IARM-9 | Validation and handoff | 8 | passed | Evidence records the command set, failed-attempt policy, clean no-Swift-change rationale, and next recommended Phase 1 slice. |

## Closure Verdict

The iOS affordance restoration backlog is now source-backed and exhaustive for
the old reference tree. Phase 1 is constrained to functional, non-agent iOS
affordances and server-fact rendering that can be truthful today. Phase 2
remains a required future full plan for agent-execution capability restoration;
the map records every deferred bucket so it cannot be lost while Phase 1 slices
iterate.
