---
name: self-extend
description: "Create, repair, test, and clean up local Tron capabilities through live protocol guidance and evidence-backed execute flows."
version: "1.0.0"
tags: [self-extension, capabilities, workers, packs, maintenance]
allowedContracts:
  - capability::execute
subagent: ask
---

# Self-Extend

Use this skill when the user wants Tron to create, update, repair, test, or
clean up local Tron capabilities, helper workers, managed skills, or local
capability packs.

## Operating Rules

- Keep the user in chat. Use plain words such as capabilities, packs, tested,
  ready to reuse, source approved, and can be removed. Put schemas, grants,
  traces, and raw evidence behind Inspect.
- Stay local. Do not add remote package discovery, remote marketplace install,
  release, deploy, push, or merge behavior.
- Keep server truth authoritative. Clients render generated surfaces and submit
  stored action coordinates; they do not construct target payloads, approvals,
  source trust, or model routing.
- Promotion is explicit. Only promote through `engine::promote` when the user
  asks and the current evidence passes. Otherwise clean up or leave a local
  review-ready result.

## Procedure

1. Establish the requested local capability or pack, the workspace, expected
   function ids, allowed file/network scope, and the evidence needed before it
   can be reused.
2. Call `worker::protocol_guide` at the start of every run through
   `capability::execute`. Treat that response as the only source for worker
   protocol fields, message shapes, templates, enum values, and environment
   details.
3. Author or update the worker, skill, package manifest, docs, and tests in the
   repo or local workspace. Keep the implementation scoped to the requested
   capability and remove stale dead paths while you work.
4. Spawn local workers through `capability::execute` targeting `worker::spawn`
   with expected function ids, session visibility unless promotion is requested,
   a stable idempotency key, and bounded authority.
5. Watch registration with `catalog::watch_snapshot` and inspect the new
   capability with `capability::inspect`. Capture catalog revision, invocation
   ids, worker id, and any diagnostics.
6. Run conformance, targeted tests, and one real invocation through
   `capability::execute`. If the capability needs a human control surface,
   author or inspect it with `ui::surface_for_target` and submit only stored
   generated-UI action coordinates.
7. If evidence fails, repair the owning file or package, record what changed,
   rerun the failed path, and keep version history clear enough for a user to
   see created, updated, failed, repaired, tested, and discarded states.
8. Finish by explaining evidence in product terms. Promote only through
   `engine::promote` when explicitly requested; otherwise clean up volatile
   workers with `worker::disconnect` or `sandbox::stop_spawned_worker`.

## Evidence Checklist

- User request, workspace, grant boundary, and out-of-scope exclusions.
- Live `worker::protocol_guide` invocation id or result reference.
- Changed files, package ids, expected function ids, and idempotency keys.
- Spawn invocation id, worker id, catalog revision, inspect result, and health
  or conformance evidence refs.
- Test commands, return codes, generated UI surface ids, screenshots, or logs
  required by the current scorecard row.
- Cleanup, discard, or explicit promotion result.

## Gotchas

- Do not copy worker protocol payload fields into this skill. Fetch them live
  with `worker::protocol_guide` every time so the skill does not drift.
- A successful spawn is not enough. Require catalog, inspect, conformance or
  targeted test evidence, and one real invocation before calling the capability
  ready.
- Promotion is never implied by creation or repair. Without explicit user
  approval, leave session/workspace-local evidence and clean up volatile
  workers when finished.
- Remote package discovery and marketplace install are outside this campaign.
