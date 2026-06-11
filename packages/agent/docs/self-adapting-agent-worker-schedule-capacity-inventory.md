# Self-Adapting Agent Worker Schedule Capacity Inventory

Status: SAAWSC campaign `complete`; inventory aligned to bounded, resumable worker schedule scanning.

This inventory covers the internal resource pagination substrate, deterministic cursor ordering, host forwarding, scheduler scan-state resource, bounded page/poll constants, cancellation propagation, inherited schedule-to-trigger dispatch path, and explicit forbidden boundaries.

## Surface Taxonomy

- `resource_pagination`: internal page request/result/cursor types and validation.
- `resource_store_memory`: in-memory store deterministic ordering, cursor resume, limit cap, and first-page compatibility.
- `resource_store_sqlite`: SQLite store deterministic ordering, cursor resume, limit cap, and first-page compatibility.
- `host_substrate`: engine host and primitive store forwarding for internal paged resource scans.
- `scan_state`: `worker_schedule_scan_state` schema, namespace claim, payload builder, cursor parser, and singleton persistence.
- `schedule_runtime`: bounded scheduler loop, page size, per-poll budget, resume, wrap, and due dispatch composition.
- `schedule_service`: cancellation token propagation from background service into the scheduler loop.
- `schedule_tests`: focused capacity, cancellation, and resource pagination tests.
- `predecessor_dispatch`: inherited SAAWSD/SAAWTL/SAAWBH/SAAWO/SAAWA schedule-to-trigger-to-launch contracts.
- `forbidden_surface`: provider/public/deploy/iOS/launchd/restart/retry/repo-skill/payload-replay denial surfaces.
- `closeout_gate`: docs, README, CI, static invariant, and final verification.

## Boundary Summary

The scheduler queries reviewed schedule plans through an internal paged resource-list operation. Pages are sorted by descending `updated_at` and descending `resource_id`, and the cursor resumes strictly after the last returned resource. The scheduler scans at most 500 reviewed plans per poll in pages of 100, records the last cursor and aggregate summary in `worker_schedule_scan_state:default`, and clears the cursor when it reaches the filtered tail so a later poll can wrap to new or updated plans at the head.

Scan state is system-scoped scheduler metadata. It records no activation bundle, stdin payload, provider prompt, process environment, launch argv secret, or worker-ready payload. The scheduler still dispatches due ticks only through the SAAWSD trigger dispatch path.

## Residual Risks

- Multi-shard scans, per-session cursors, priority indexes, and large-population performance tuning are out of scope for SAAWSC.
- Cursor ordering depends on resource update timestamps and resource ids. Future store changes must keep memory and SQLite semantics aligned.
- The TSV is static. New files touching pagination, scan state, scheduler loops, or public/provider boundaries must update this inventory and invariant gate.
