# Worker-First Local Product User Guide

This guide describes Tron as worker-led autonomous work. The user model is one
orchestrator plus workers: ask for work, let Tron break it into worker tasks,
watch progress in the Work dashboard, and open Audit Details only when evidence
or exact identifiers matter.

## Main Surface

The Work dashboard is the primary surface for local automation. It shows
Autonomy, active work, Workers, recent results, Guardrails, and one Audit
Details entry point. Chat stays the place to ask for work and receive concise
status updates; repeated low-level execution events stay out of the default
path.

Use product words in the main flow:

- Work is the user goal Tron is currently moving forward.
- Workers are local actors Tron delegates to for files, tests, browser tasks,
  notes, generated controls, and helper processes.
- Worker Packs are reusable local bundles of workers, configuration,
  generated controls, source evidence, and audit history.
- Autonomy is run-unless-blocked on this Mac. Guardrails stop unsafe work.
- Audit Details contains raw ids, grants, leases, resource versions,
  invocation records, schemas, traces, source evidence, and exact decisions.

## Autonomous Work Loop

Start from an ordinary request such as "create a local worker that summarizes
this repo's scorecard state." Tron should:

1. Confirm the goal and run independently unless a Guardrail blocks it or the
   explicit QA testing mode asks for a prompt.
2. Fetch the current Worker Guide, create or update the worker, and run focused
   checks.
3. Show high-signal Work events while the worker is created, tested, repaired,
   cleaned up, or reused.
4. Make the worker visible in the Work dashboard with health, trust, Generated
   Controls, recent work, and audit history.
5. Invoke the worker once through the work loop before calling it ready.
6. Promote only after an explicit user request. Otherwise leave local evidence
   and clean up temporary workers or helper files.

The main UI should not require engine vocabulary. Worker ids, grants, leases,
resource versions, source evidence refs, invocation ids, raw schemas, and traces
belong in Audit Details.

## Worker Packs

Worker Packs are local-first bundles for reusable workflows that need a
manifest, configuration schema, source evidence, trust state, activation
history, and generated controls.

Current local examples live in `packages/agent/examples/local-packs/`:

- Tron Maintainer Worker Pack: repo health, focused test summary, and
  scorecard/evidence helpers.
- Everyday Organizer Worker Pack: local digest, organizer artifact, and local
  notification record.
- Creative Knowledge Worker Pack: prompt and notes transformation with
  generated-control-ready output.

Pack setup remains local and evidence-backed. A normal Worker Pack flow
registers the local manifest, verifies source, records conformance, approves
source when needed, configures, activates, invokes, disables, rolls back,
revokes approval, or removes the pack. Generated Controls present those actions
in the app; Audit Details exposes the backing resource refs and decisions.

## Trust And Actions

Plain trust text comes from server-owned worker trust labels. Expected labels
include source verified, source approved, tested, ready to reuse, revoked,
cleanup needed, and can be removed. The app renders those labels; it does not
invent trust, policy, approval, routing, or action targets.

Generated Controls are the native action surface for Worker Packs and created
workers. The app submits stored surface/action coordinates plus user input, and
the server reconstructs the canonical work call.

## Worker Routing

Use the product presets:

- Local when possible: prefer local execution when policy and availability
  allow it, and disclose any hosted route.
- Balanced: use the default tradeoff for everyday work.
- Deep: spend more reasoning/model budget for harder work.

Worker detail sheets should show the task, selected preset/model route, result,
and lineage. The exact model and hosted-route explanation remain server-owned
and inspectable in Audit Details after the run.

## Boundaries

No remote package discovery, publishing, production rollout, notarization, or
release automation is part of this product flow. Source-control publishing and
production deployment stay outside Worker Pack setup unless the user explicitly
starts a separate source-control or release task.
