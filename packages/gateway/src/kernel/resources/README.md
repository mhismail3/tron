# gateway/resources

## Purpose

K4 owns executable resource admission and canonical Project-root identity.

## Owns

`project-root.ts` resolves the real Git worktree root through the platform bounded
Git process owner. The actual spawned process, environment sanitization, output
bounds, exit rules and retirement live in `util/git-inspection.ts`.

`trust-service.ts` owns the one Pi ProjectTrustStore and serialized trust changes,
including inherited decisions, standalone directories, worktree propagation and
compensating runtime application/commit rollback and mandatory native retirement
of any acquired transition still pending at exit. `reserveUntrustedDirectory` pins
an exact new directory before it has a Git root, never an enclosing repository.
An exact false decision on a requested directory narrows inherited/root authority;
a subdirectory's positive decision still never grants authority to its Git root.
`setAndApply` restores the previous decision and runtime state when application
fails. Failed compensation retires uncertain frames and releases project admission
instead of publishing success or stranding a reservation.
Admin supplies binding I/O;
the canonical resource owner supplies the trust decision used by sessions.

`prompt-bounds.ts` owns the prompt text/attachment limits and canonical line-bound
calculation. Native evidence reads and Episodic defaults consume its one derived
default budget; the upload producer consumes the same attachment limits.

`context-index.ts` is the one index renderer for advertised resources:
`<index name open kind>` with one `- id: description | locator` row per item, id-sorted,
whitespace collapsed and escaped. A source description over 160 characters is rendered in full and
returned as a diagnostic; nothing is truncated or paraphrased. An index without a listing locator is
rendered in full and an over-budget one is diagnosed; one with a locator keeps whole rows and points to
the rest. The skills and profile callers surface diagnostics; the docs, MCP servers and subagent types
callers keep only the text. `skillsIndex` renders each skill section through the SDK's `renderSkills` host option
(`<index name="skills" open="read" kind="procedure">`, 10,000 bytes), and the session resources
view lists its diagnostics as skill warnings. `docsIndex` renders Pi's docs section through the SDK's
`renderDocs` host option (`<index name="docs" open="read" kind="data">`, 4,096 bytes) between Pi's own
guidance sentences, and `mcpServersIndex` renders the MCP extension's `mcp_servers` section through its
`renderServers` option (`<index name="mcp_servers" open="codemode" kind="data">`, 4,096 bytes) after Pi's
intro sentence. An index given a listing locator keeps whole sorted rows within its budget and ends with
`- more: List the remaining items. | <locator>` (`searchTools()` for MCP servers). `subagentTypesIndex` renders
the agents pi-subagents advertises as `<subagent_types>` (`<index name="subagent_types" open="subagent"
kind="tool">`, 4,096 bytes, `subagent action=list` overflow) after the provider's own first paragraph;
managed pi-subagents registers it once per process through the provider's `subagent-types` API.

`context-rules.ts` admits context files for every non-Home runtime: the global `AGENTS.md` unless
`context.rules.global` is off, project and ancestor `AGENTS.md` files only for a trusted project and
unless `context.rules.project` is off. `SYSTEM.md` and `APPEND_SYSTEM.md` are never read. Home keeps its
own override, which reads only the global rules file. `settings-three-layer.e2e.test.ts` proves the
switches, the trust gate and the ignored files on real requests.

## Contract

`projectRoot(cwd)` returns the real worktree root, or the caller’s cwd when Git
has no usable worktree. Timeout and overflow remain retryable failures; the 5 s
timeout does not count time the event loop was stalled, so a finished Git is never
reported as timed out.

## Invariants

Project trust and Project settings address the same canonical worktree root.
A linked worktree has its own root; inherited Git selectors never redirect it.

## Entry points

`TrustService`, `TrustInspection`, `PropagatedTrustDecision`, `projectRoot`.

## Signals

Git launch, timeout and output failures propagate as existing Gateway errors.
Unresolved decisions refuse resource loading with `trust_required`; incomplete
compensation refuses with the existing trust rollback error.

## Verify

```bash
scripts/tron test gateway src/e2e/kernel/resources/project-root.integration.test.ts \
  src/machine/workspace-inspection-service.integration.test.ts
```

## Not here

User workspace browsing, Git status/history projection and worktree creation:
[machine](../../machine/README.md).
