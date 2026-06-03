# Self-Extending Local Product User Guide

This guide describes the intended user-facing flow for Tron as a chat-led,
self-extending local agent environment. It is product documentation, not a
release checklist.

## Main Surface

Chat is the primary surface. Ask for the work in ordinary language, approve
workspace-local autonomy when Tron needs hands-off local changes, and watch
capability chips show creation, testing, repair, cleanup, and reuse status.
Engine Console and Inspect are drill-down layers for evidence, identifiers,
schemas, grants, traces, and raw resources.

Use product words in the main flow:

- Capabilities are local tools Tron can call through chat.
- Packs are local bundles of capabilities, configuration, generated UI, and
  evidence.
- Created by Agent shows capabilities or packs that Tron created, updated,
  repaired, tested, promoted, revoked, discarded, or reused.
- Inspect shows deeper evidence when you need to audit what happened.

## Self-Extension Flow

Start from a normal chat request such as "create a local helper that summarizes
this repo's scorecard state." Tron should:

1. Ask for workspace-local autonomy only when it needs local file changes or a
   workspace-visible helper.
2. Fetch the live worker guide, create or update the helper, and run focused
   checks.
3. Show capability chips while the helper is being created, tested, repaired,
   or cleaned up.
4. Make the helper visible in Created by Agent with lineage, version history,
   conformance, model/subagent choices, and generated UI refs.
5. Invoke the helper once through chat before calling it ready.
6. Promote only after an explicit user request. Otherwise leave local evidence
   and clean up temporary workers or helper files.

The main UI should not require engine vocabulary. Worker ids, grants, leases,
resource versions, source evidence refs, invocation ids, and traces belong in
Inspect.

## Packs

Packs are local-first capability bundles. Use Packs when a reusable workflow
needs a manifest, configuration schema, source evidence, trust state,
activation history, and generated UI controls.

Current local examples live in `packages/agent/examples/local-packs/`:

- Tron maintainer: repo health, test summary, and scorecard/evidence helpers.
- Everyday organizer: local digest, organizer artifact, and notification
  delivery.
- Creative/knowledge: prompt and notes transformation with generated UI-ready
  output.

Pack setup should remain local and evidence-backed. A normal pack flow registers
the local manifest, verifies source, records conformance, approves source when
needed, configures, activates, invokes, disables, rolls back, revokes approval,
or removes the pack. Generated UI surfaces present those controls in the app;
Inspect exposes the underlying resource refs and decisions.

## Trust And Actions

Plain trust text comes from server-owned trust labels. Expected labels include
source verified, source approved, tested, ready to reuse, revoked, cleanup
needed, and can be removed. The app renders those labels; it does not invent
trust, policy, approval, routing, or action targets.

Generated UI is the native control surface for new pack and capability actions.
The app submits stored surface/action coordinates plus user input, and the
server reconstructs the canonical capability call.

## Model And Helper Routing

Use the product presets:

- Local when possible: prefer local execution when policy and availability
  allow it, and disclose any hosted route.
- Balanced: use the default tradeoff for everyday work.
- Deep: spend more reasoning/model budget for harder work.

Subagent chips should show the helper task, selected preset/model route, result,
and lineage. The exact model and hosted-route explanation remain server-owned and
inspectable after the run.

## Boundaries

This product flow has no push, merge, release, deploy, or remote package discovery.
Local pack discovery is disk-based only. Remote marketplaces,
publishing, production rollout, notarization, and release automation are outside
this campaign.
