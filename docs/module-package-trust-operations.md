# Module Package Trust Operations

This is the operator checklist for local module packages. It describes the
current canonical capability flow only; it is not a marketplace, remote fetch,
or client-side policy guide.

## Local Package Lifecycle

1. Register package bytes with `module::register_package`.
   - Built-in packages use deterministic built-in provenance.
   - Local packages must be digest-pinned through materialized file refs.
   - Registration validates schema, digest, namespace, output contracts, config
     schema, redaction, and runtime policy. It does not grant activation trust.

2. Establish source trust.
   - Unsigned local packages require `module::verify_source` evidence plus a
     scoped `module::approve_source` decision.
   - Signed local packages require `module::register_source` for a local
     Ed25519 trust root and `module::verify_signature` evidence for the package
     digest/version.
   - `module::policy_decide` and `module::audit_policy` explain allow, deny,
     stale, revoked, and quarantine-required states without mutating authority.

3. Configure and activate.
   - `module::configure` stores a validated `module_config` resource. Raw
     secrets are rejected; configs use `secret_ref` or vault handles.
   - `module::activate` derives a narrower activation grant, binds an existing
     worker or invokes canonical `worker::spawn`, validates registered
     capabilities, runs health checks, and writes an `activation_record`.

4. Review and audit trust.
   - `module::simulate_trust_change` previews renewal, rotation, expiry,
     revocation, approval, reconciliation, and enforcement impacts.
   - `module::record_trust_review` stores bounded review evidence after
     recomputing the simulation server-side.
   - `module::schedule_trust_audit` stores a daily or weekly audit schedule as a
     `decision` resource with optional `retentionPolicy.reviewAfterDays`.
   - `module::trust_audit_status` explains current due bucket, queued/completed
     bucket, missed buckets, evidence refs, affected refs, and retention
     warnings from substrate truth.
   - `module::run_scheduled_trust_audit` writes bounded audit evidence for one
     requested bucket. Missed buckets are not backfilled automatically.
   - `module::record_trust_audit_retention` records advisory evidence for old
     audit evidence. It does not delete bytes or archive resources.

5. Revoke, expire, and enforce.
   - `module::expire_trust_decision` archives source, trust-root, approval, or
     trust-audit schedule decisions through CAS and writes evidence.
   - Revocation or expiry makes package/activation projections stale or denied;
     it does not silently stop workers.
   - `module::enforce_revocation` is the explicit high-risk path that composes
     canonical `module::disable` or `module::quarantine` child invocations for
     proven affected activations.

6. Verify cleanup.
   - Use `module::check_health`, `module::verify_integrity`,
     `module::recover_activation`, `module::inspect_package`,
     `module::inspect_trust`, `control::inspect`, and generated `ui_surface`
     actions to confirm no unsafe grant, volatile worker, stale package trust,
     or missing evidence remains.

## Invariants

- Trust state is represented by `decision` and `evidence` resources plus links.
- Package/config/activation state is represented by typed resources and
  versions.
- No package, source, trust, policy, conformance, audit, schedule, or health
  table exists.
- Control and iOS are projections only. They never construct package policies,
  grants, command templates, target function ids, or action payloads.
- Raw secrets must be `secret_ref` or vault handles and must not appear in
  manifests, configs, evidence, generated UI, logs, or caches.
