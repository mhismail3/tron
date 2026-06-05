---
name: self-extend
description: "Create, repair, test, and clean up local Tron workers and Worker Packs through live Worker Guide evidence."
version: "1.0.0"
tags: [self-extension, workers, worker-packs, autonomy, maintenance]
allowedContracts:
  - capability::execute
subagent: ask
---

# Self-Extend

Use this skill when the user wants Tron to create, update, repair, test, or
clean up local Tron workers, worker abilities, managed skills, or Worker Packs.

## Operating Rules

- Keep the user in the Work model: Work, Workers, Worker Packs, Autonomy,
  Guardrails, Generated Controls, and Audit Details.
- Stay local. No remote package discovery, remote marketplaces, production
  rollout, source-control publishing, or release automation belongs in this
  flow.
- Keep server truth authoritative. Clients render Generated Controls and submit
  stored action coordinates; they do not construct target payloads, approvals,
  source trust, or model routing.
- Promotion is explicit. Only promote through the server-owned promotion path
  when the user asks and the current evidence passes. Otherwise clean up or
  leave a local review-ready result.

## Procedure

1. Establish the requested local worker or Worker Pack, the workspace, expected
   function ids, allowed file/network scope, and the evidence needed before it
   can be reused.
2. For workspace-local hands-off work, call `capability::execute` targeting
   `self_extension::grant_workspace_autonomy` with `workspaceId`,
   `workspacePath`, and a plain reason. Default autonomy is
   run-unless-blocked; use the returned grant id as `workspaceAutonomyGrantId`
   when spawning workspace-visible workers.
3. Call `worker::protocol_guide` at the start of every run through
   `capability::execute`. Treat that response as the only source for worker
   protocol fields, message shapes, templates, enum values, and environment
   details.
4. Author or update the worker, skill, package manifest, docs, and tests in the
   repo or local workspace. Keep the implementation scoped to the requested
   worker ability and remove stale dead paths while you work.
5. Spawn local workers through `capability::execute` targeting `worker::spawn`
   with expected function ids, workspace visibility and
   `workspaceAutonomyGrantId` after a workspace grant, session visibility for
   chat-only experiments, a stable idempotency key, and bounded authority.
6. Watch registration with `catalog::watch_snapshot` and inspect the new worker
   ability with `capability::inspect`. Capture catalog revision, invocation ids,
   worker id, and any diagnostics.
7. Run conformance, targeted tests, and one real invocation through
   `capability::execute`. If the worker needs a human control surface, author
   or inspect it with `ui::surface_for_target` and submit only stored Generated
   Controls action coordinates.
8. For local Worker Packs, keep the sequence local and evidence-backed:
   `module::register_package`, `module::inspect_package`,
   `module::configure`, `module::activate`, `module::disable`,
   `module::rollback`, `module::revoke_source_approval`, and
   `module::remove_package`. Remove a pack only after live activations are
   disabled or quarantined, and keep remote discovery out of the flow.
9. If evidence fails, repair the owning file or package, record what changed,
   rerun the failed path, and keep version history clear enough for a user to
   see created, updated, failed, repaired, tested, and discarded states.
10. Finish by explaining evidence in product terms. Promote only when explicitly
   requested; otherwise clean up volatile workers with `worker::disconnect` or
   `sandbox::stop_spawned_worker`.

## Evidence Checklist

- User request, workspace, grant boundary, and out-of-scope exclusions.
- Workspace autonomy grant id when hands-off workspace work is used.
- Live `worker::protocol_guide` invocation id or result reference.
- Changed files, package ids, expected function ids, and idempotency keys.
- Spawn invocation id, worker id, catalog revision, inspect result, and health
  or conformance evidence refs.
- Test commands, return codes, Generated Controls surface ids, screenshots, or
  logs required by the current scorecard row.
- Cleanup, discard, or explicit promotion result.

## Gotchas

- Do not copy worker protocol payload fields into this skill. Fetch them live
  with `worker::protocol_guide` every time so the skill does not drift.
- A successful spawn is not enough. Require catalog, inspect, conformance or
  targeted test evidence, and one real invocation before calling the worker
  ready to reuse.
- Promotion is never implied by creation or repair. Without explicit user
  approval, leave session/workspace-local evidence and clean up volatile
  workers when finished.
- Remote package discovery and remote marketplaces are outside this campaign.
