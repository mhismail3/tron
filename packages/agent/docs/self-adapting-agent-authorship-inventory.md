# Self-Adapting Agent Authorship Inventory

Status: SAA campaign `complete`; source inventory and fixtures are closed for
the first authorship slice.

This inventory records the source surfaces that govern self-adapting authorship
on the primitive branch. The paired TSV is the machine-readable gate used by
`self_adapting_agent_authorship_invariants`.

## Surface Classes

- `model_surface`: provider-visible schema, prompt clarification, and primitive
  surface resolution. These must keep `execute` as the only model-visible tool.
- `execute_operation`: direct operations inside `execute`, including state,
  resource, file, process, trace, log, and replay paths.
- `typed_resource`: built-in resource kinds, validation, lifecycle, relation,
  and persistence surfaces.
- `authorship_fixture`: tests that create durable goals, evidence, decisions,
  memory/rules, patches, files, and UI surfaces through `execute`.
- `runtime_ui`: generic generated UI rendering and validation on Rust/iOS.
- `promotion_boundary`: explicit `engine::promote`, external worker grants,
  worker protocol, and no-live-launch checks.
- `observability`: trace, replay, logs, and evidence surfaces that make SAA
  artifacts inspectable.
- `closeout_gate`: scripts, workflows, README links, and static gates that keep
  this campaign wired into local and GitHub closeout.

## Coverage Policy

SAA covers the first durable authorship slice only. A source path is in scope
when it defines provider-visible primitive context, executes the new resource
operations, defines or validates SAA resource kinds, renders generated UI,
promotes or launches capabilities, records replay/trace evidence, or gates
closeout. The inventory intentionally excludes future product panels, managed
skills, worker-pack lifecycles, and background mutation loops because those are
not allowed outcomes for this slice.

## Closeout Notes

No open SAA rows remain. Residual live-scale risks are recorded in the evidence
manifest: future promotion endpoints must validate decision/evidence refs before
turning generated artifacts into workspace/system capabilities or live workers,
and future long-running improvement loops must remain user/session initiated,
bounded, cancellable, observable, and non-deploying.
