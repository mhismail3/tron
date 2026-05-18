# Module Package Activation And Operator Action Phase

## Summary

The generated UI authoring phase established deterministic `ui_surface`
resources, strict validation, refresh, expiry, and thin iOS rendering. The next
phase should make the modular engine genuinely plug-and-play without adding a
new state plane: modules become resource-backed packages, activation becomes a
grant-scoped capability flow, and generated surfaces expose real canonical
actions for inspecting, enabling, disabling, configuring, upgrading, and
recovering workers and capabilities.

This phase is not a marketplace, not a compatibility layer, and not a new
dashboard system. It is the minimum secure module lifecycle needed for a
collapsed architecture where workers invoke capabilities against resources under
scoped grants.

## First-Principles Objective

A modular engine needs a way to answer four questions from substrate truth:

- What modules and workers are installed, active, unhealthy, or available?
- What capabilities do they provide, and what effects, risks, resources, files,
  network access, approvals, and budgets do they need?
- What authority was granted, by whom, for which purpose, for how long, and with
  what delegation limits?
- What operator actions can be taken now without trusting the client, hidden
  runtime state, or stale handwritten screens?

The target state for this phase:

- module packages are typed resources with signed manifests, source provenance,
  declared capabilities, required grants, config schema, runtime entrypoint, and
  integrity status;
- activation is a canonical capability invocation that derives grants and starts
  workers only after package, config, policy, and resource selector validation;
- disabling, revoking, upgrading, and rollback are canonical capabilities, not
  bespoke product actions;
- generated surfaces for packages, workers, capabilities, grants, approvals, and
  integrity expose useful actions through stored `ui_surface` templates;
- iOS remains a renderer and action submitter only;
- all projections remain rebuildable from catalog/worker records, invocation
  ledger, grant ledger, and resource store.

## Non-Goals

- Do not add a storage generation bump unless active schemas are removed or the
  runtime can no longer safely open existing `modular-engine-v2` stores.
- Do not add package marketplace discovery, remote installation, billing,
  ratings, or third-party catalog distribution.
- Do not add dynamic UI component catalogs.
- Do not add `control::act`, client-side policy decisions, route aliases,
  compatibility readers, or fallback renderers.
- Do not let a package self-enable, self-expand grants, or register capabilities
  beyond its activation grant.
- Do not make iOS a module manager with local truth. It can render server
  surfaces and submit stored actions only.

## Core Resource Types

Register these first-party resource kinds in the existing resource kernel:

- `worker_package`
  - Manifest, package digest, source provenance, signature status, trust tier,
    declared worker kind, declared capabilities, runtime entrypoint, config
    schema, required grants, output contracts, sandbox profile, install scope,
    and integrity status.
  - Lifecycle: `draft`, `available`, `active`, `disabled`, `superseded`,
    `quarantined`, `discarded`, `damaged`.

- `module_config`
  - Config payload validated against the package config schema, redaction
    policy, secret refs, target package id/version, scope, and current revision.
  - Lifecycle: `draft`, `active`, `superseded`, `disabled`, `discarded`,
    `damaged`.

- `activation_record`
  - The resource-backed result of enabling or upgrading a package. It links the
    package, config, derived grant, worker id, worker registration, health
    result, and rollback target.
  - Lifecycle: `pending`, `active`, `failed`, `disabled`, `rolled_back`,
    `superseded`, `damaged`.

These are resources, not tables. Any indexes, control summaries, or iOS caches
must be rebuildable projections.

## Package Manifest Contract

Each `worker_package` manifest must declare:

- package id, version, schema id, display name, description, owner namespace,
  trust tier, and source provenance;
- signed digest over package bytes plus manifest content;
- worker kind: first-party Rust module, local process worker, MCP adapter,
  model-backed worker, script worker, or system service;
- runtime entrypoint and sandbox profile for non-in-process workers;
- declared capabilities with request schema, response schema, accepted input
  resource kinds, produced output resource kinds, effect class, risk,
  idempotency, output contract, lease requirements, approval policy, and stream
  topics;
- required grants and maximum authority ceiling;
- required resource selectors, file roots, network policy, process policy,
  secret refs, budget defaults, and delegation limits;
- config schema and redaction rules;
- health check capability and readiness criteria;
- uninstall, disable, upgrade, and rollback notes.

Registration rejects packages that omit idempotency for mutating capabilities,
omit resource output contracts for durable outputs, request unsupported risk, or
declare capability ids outside their namespace.

## Capability Additions

Add package lifecycle capabilities under a first-party `module` worker:

- `module::register_package`
  - Resource-backed.
  - Validates manifest, digest, signature/provenance status, config schema,
    capability namespace ownership, output contracts, risk, and grant ceiling.
  - Creates or updates a `worker_package` resource version.

- `module::inspect_package`
  - Pure read.
  - Returns package resource, current version, declared capabilities, config
    schema summary, integrity state, activation status, linked worker, linked
    config, and available canonical actions.

- `module::configure`
  - Resource-backed CAS update.
  - Validates config payload against the package config schema, stores secrets
    only as `secret_ref`, and creates or updates a `module_config` resource.

- `module::activate`
  - Resource-backed and idempotent.
  - Requires `workerPackageResourceId`, `packageVersionId`,
    `moduleConfigResourceId`, `configVersionId`, child grant request, lifecycle
    policy, health policy, and rollback policy.
  - Derives a grant, starts/registers the worker through canonical worker spawn
    or in-process registration, verifies declared capabilities against the grant,
    runs health checks, and creates an `activation_record` resource.

- `module::disable`
  - Resource-backed and idempotent.
  - Disconnects volatile workers or disables in-process registrations through
    canonical worker lifecycle paths, revokes or pauses derived grants according
    to policy, and updates the activation record.

- `module::upgrade`
  - Resource-backed and idempotent.
  - Validates the new package version, performs grant narrowing/derivation,
    activates a replacement worker, preserves or migrates config only through a
    declared config transform, and links old/new activation records.

- `module::rollback`
  - Resource-backed and idempotent.
  - Reverts to a prior activation record only when the prior package/config/grant
    remain valid and narrower than current policy.

- `module::quarantine`
  - Resource-backed and idempotent.
  - Disables worker execution, revokes activation grants, marks package or
    activation state as quarantined, and preserves inspection evidence.

Do not add a separate public package action multiplexer. Each operation is its
own capability with explicit schemas, idempotency, output contract, risk, and
grant requirements.

## Activation Flow

1. A package file, in-repo module declaration, or local worker script is
   registered through `module::register_package`.
2. The engine validates the package manifest, digest, namespace, declared
   capabilities, output contracts, and authority ceiling before persistence.
3. An operator or coordinator creates a `module_config` through
   `module::configure`.
4. `module::activate` prepares an invocation with package refs, config refs,
   constraints, grant request, idempotency key, and output contract.
5. The engine derives a child grant from the caller grant.
6. The worker registers capabilities. Registration fails if runtime declarations
   exceed the package manifest, config, grant, resource selectors, file roots,
   network policy, risk ceiling, visibility ceiling, or trust tier.
7. A health check runs under the derived grant.
8. The activation record links package, config, worker, grant, health result,
   invocation, and rollback target.
9. Control projections and generated surfaces reflect the new active module
   from existing substrate truth.

## Generated UI Actions

Extend `ui::surface_for_target` authoring so package and worker surfaces expose
real canonical actions when allowed by the active grant:

- package surface actions: inspect, configure, activate, disable, upgrade,
  rollback, quarantine, refresh;
- worker surface actions: health, disconnect, inspect grant, inspect package,
  refresh;
- capability surface actions: inspect schema, validate output contract, run
  health probe, inspect owning package, refresh;
- grant surface actions: inspect, revoke, derive narrower grant where policy
  permits, refresh;
- approval surface actions: approve/reject through `approval::resolve`;
- integrity surface actions: inspect damaged resource, quarantine package,
  refresh, export evidence.

Rules:

- generated actions target canonical capability ids only;
- action payload templates must validate against target request schemas;
- mutating targets require idempotency and output contracts;
- action risk cannot exceed the authoring grant;
- action target revisions are stored and revalidated on submit;
- surfaces must not inline secret values, package bytes, logs, or large resource
  bodies;
- control may advertise surface authoring and refresh actions, but it must not
  inline layout or action templates.

## Security Rules

- Package manifests are untrusted input until validated and persisted as
  `worker_package` resources.
- A package cannot grant itself authority. Only `module::activate` can derive an
  activation grant, and only narrower than the caller grant.
- Runtime worker registration is checked against both package manifest and
  derived grant.
- Worker capability ids must stay inside the package namespace unless the
  package is first-party and explicitly authorized.
- Config payloads cannot contain raw secrets. Secrets must be `secret_ref`
  resources or vault handles with redacted previews.
- Package bytes and manifests are content-addressed. Hash mismatch creates a
  damaged/quarantined version and leaves prior active versions current.
- Upgrade and rollback are new activations, not in-place mutation of truth.
- Disable and quarantine preserve evidence and lineage.
- iOS cannot construct package activation payloads from local policy; it submits
  only stored generated UI actions or typed capability requests that the server
  authorizes.

## Failure Modes

- Package registration fails: no worker is started and no active package version
  is created.
- Config validation fails: package remains available, previous config remains
  current.
- Grant derivation fails: activation fails before worker spawn.
- Worker spawn fails: activation record is `failed`; package/config refs remain
  inspectable; derived grants are revoked or expired by compensation.
- Worker registers extra capability: activation fails and worker is disconnected.
- Health check fails: activation record is `failed`; rollback remains available
  only if prior activation is valid.
- Upgrade partially succeeds: old activation remains current until new health
  and registration pass.
- Disable crashes midway: invocation compensation resumes from resource/worker
  and grant ledger state.
- Package bytes disappear: package version becomes damaged; active worker is
  quarantined if integrity policy requires it.
- Surface action goes stale: `ui::submit_action` rejects before target execution.

## iOS Engine Console Scope

iOS should render package/module surfaces through the existing strict generated
UI renderer and typed capability client:

- load package and activation refs from `control::snapshot` and
  `control::inspect`;
- inspect package/worker/config surfaces through `ui::inspect_surface`;
- request `ui::surface_for_target` only when the server advertises it;
- submit stored actions only through `ui::submit_action`;
- show approval-required, stale, rejected, failed health, quarantine, and
  rollback states from server responses;
- keep offline cache read-only and redacted.

Do not add fixed package dashboards or local package policy.

## TDD Sequence

1. Add static gates that no module activation path bypasses `module::*`,
   `grant::*`, `worker::*`, resource output contracts, or `ui::submit_action`.
2. Add failing tests for `worker_package`, `module_config`, and
   `activation_record` resource type registration and schema validation.
3. Add `module::register_package` tests for manifest digest, namespace, risk,
   output contract, idempotency, signature/provenance, and malformed config
   schema rejection.
4. Add `module::configure` tests for CAS, config schema validation, secret
   redaction, and damaged-version handling.
5. Add `module::activate` tests for grant derivation, worker registration
   ceiling checks, resource selector checks, health checks, idempotent replay,
   and failed activation compensation.
6. Add disable, upgrade, rollback, and quarantine tests with resource lineage and
   grant revocation assertions.
7. Extend generated UI tests so package, worker, capability, grant, approval,
   and integrity surfaces expose only target-schema-valid canonical actions.
8. Extend iOS DTO/state tests for package refs, generated package surfaces,
   server-advertised action gating, action result rendering, stale/approval
   states, and offline read-only cache behavior.
9. Run absence scans for compatibility routes, local iOS policy, dynamic
   catalogs, fallback renderers, and package action multiplexers.

## Verification

- Targeted Rust tests for resource types, module capabilities, grant narrowing,
  worker registration, health, generated UI action authoring, and compensation.
- Static gates in `packages/agent/tests/threat_model_invariants.rs`.
- `scripts/tron ci fmt check clippy test`.
- `cd packages/ios-app && xcodegen generate`.
- Targeted `xcodebuild test` for Engine Console state, generated UI DTOs,
  renderer, source guards, cache redaction, and action submission.
- `git diff --check`.
- README, architecture docs, module docs, and `~/LEDGER.jsonl` updated in the
  same checkpoint.

## Exit Criteria

- A local first-party package can be registered, configured, activated,
  inspected, disabled, upgraded, rolled back, and quarantined through canonical
  capabilities.
- Active workers cannot register capabilities beyond their package manifest or
  derived grant.
- Package/config/activation state is represented only as resources and links.
- Generated surfaces expose meaningful package and worker actions without
  adding a control mutation plane or fixed iOS dashboards.
- The system can explain exactly what is installed, what is active, what each
  module can do, what authority it has, and what action is safe next.
