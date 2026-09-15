# Tron delegation runtime

Tron owns the default `subagent` capability through the separately compiled
`src/delegation/pi-subagents` package. It is derived from the pinned
`pi-subagents` 0.59.0 source and retains the bounded direct, async, workflow,
resume, and nested-child contracts, capability ceilings, and canonical result
settlement. Provenance and license information are in that package's
`PROVENANCE.md`.

The package's `build.mjs` copies its agents, skills, prompts, documentation,
and worker entrypoints into the Gateway release payload. Its built package keeps
`pi-subagents`' public root and subpath export identities for local consumers;
those exports resolve to the emitted JavaScript under the payload and are not a
second runtime implementation. Child launch planning
always includes the owned package entrypoint, while `PI_SUBAGENT_CHILD=1`
prevents a child process from registering the parent-facing tool.

The owning runtime passes its Tron bootstrap explicitly with each launch.
Background runners serialize that context in their run configuration and pass
it to every native child, including parallel steps and resumed launches; they
do not rely on mutation of the Gateway process environment. The prompt-only
child extension exports the default factory required by the SDK CLI. It adds
context without granting tools or overriding child capability ceilings.

After `npm run build`, the focused
`tron-background-bootstrap.integration.test.ts` exercises the compiled runner
and SDK CLI with isolated homes, temp roots, and a fake provider. It checks the
model's actual prompt and tool inventory for single and parallel children. The
child-runner fixture uses a clean allowlisted environment, waits for `close`,
and kills a bounded test process on timeout. These fixtures do not by themselves
qualify parent executor dispatch, recovery, or process-control behavior.

The upstream durable scheduler is intentionally not part of the Tron runtime.
Gateway automation is the sole scheduler. Existing schedule files are not
read, migrated, or deleted. A destination still configured with the superseded
`npm:pi-subagents` extension fails closed and must have only that extension
disabled before retrying; canonical sessions and settings are otherwise left
untouched.
