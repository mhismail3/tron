# Security Authority Capability Boundaries Inventory

Status: SACB-0 `passed_after_fix`; seed rows only. SACB-1 must replace this
with a whole-repo security boundary inventory covering Rust, iOS, Mac, scripts,
docs, and CI security markers.

Machine-readable inventory:
[`security-authority-capability-boundaries-inventory.tsv`](security-authority-capability-boundaries-inventory.tsv)

## Boundary Classes

- `public_transport`: externally reachable protocol routes, request DTOs,
  bearer checks, and route exposure.
- `authority_grant`: grant creation, derivation, authorization, bootstrap, and
  authority-scope handling.
- `runtime_metadata`: metadata that affects file roots, trace identity,
  provider ownership, trigger cascade bounds, or queue/runtime behavior.
- `execute_primitive`: file, process, state, trace, log, replay, and model
  primitive operation boundary.
- `external_worker`: loopback worker identity, scoped token, trigger, stream,
  and result ownership.
- `secret_storage`: bearer/API/OAuth token custody, auth file mode, Keychain,
  UserDefaults, logs, diagnostics, and redaction.
- `pairing_lifecycle`: iOS/Mac pairing parse, persist, forget, re-pair, rotate,
  and unauthorized flows.
- `static_gate`: docs, test, CI, and inventory gates that preserve the campaign.

## SACB-0 Seed Rows

The TSV currently contains only the campaign-owned scaffold and the primary
baseline finding surfaces. SACB-1 must expand it so every tracked security
surface with authority, credential, public route, runtime metadata, worker,
pairing, diagnostics, or process/file execution markers is classified.

## Open Loops

- SACB-1: inventory all marked source, docs, script, CI, iOS, and Mac boundary
  surfaces.
- SACB-2: prove public route authentication and loopback worker gating.
- SACB-3: delete/deny public authority scope and runtime metadata injection.
- SACB-4: prove grant derivation and bootstrap wildcard boundaries.
- SACB-5: prove catalog visibility and `engine::invoke` delegation boundaries.
- SACB-6: prove `capability::execute` least privilege.
- SACB-7: prove external worker protocol isolation.
- SACB-8: prove secrets, redaction, auth.json permissions, and provider custody.
- SACB-9: prove pairing lifecycle and unauthorized flow.
- SACB-10: run final closeout and remove stale active-state wording.
