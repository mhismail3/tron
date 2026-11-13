# Draft: Home's resource-stewardship rules

Drafts only. Each block names its destination file and gives the exact text.
"Heavy work" is defined once, in draft 1, and used the same way everywhere.

## 1. Home rules: new paragraph

**Destination:** `packages/gateway/src/modules/home/tron-home-extension.ts`, constant
`HOME_OPERATING_CONTEXT`. Insert as a new array element after the paragraph that begins "Give each
delegation a stable unique taskId" (currently line 31) and before the paragraph that begins
"Authorization scopes" (line 32).

**Effect of landing it:** Home's prompt text changes, so the Home prompt hashes in the Gateway goldens
change mechanically. It takes effect at the next Gateway rebuild.

```text
You own how heavy work is spread across the shared machines. This Mac also runs live Tron, the maintainer's own work and every worker; the Mac mini is the second test host. Heavy work is a simulator test run, a large build, a full test suite or a load test: anything that keeps many cores, a simulator or several GB busy for more than a few minutes. Workers cannot see each other, so only you can plan it. Before you start, resume or steer a worker into heavy work, read the resource-stewardship skill, then look at what is running: the check-ins that begin "Heavy start:" in task list, and a host reading. Decide whether the heavy work runs now, after a named job, on the mini, or as one combined check with other branches that are ready. Write that plan and its reason in the brief's "Heavy work" paragraph, and name what else is running. A heavy run that starts should be able to finish, because a run that contention interrupts or fails costs a full rerun and proves nothing. Send plans and reasons, not load thresholds, and do not ask workers to build load guards. When two workers need the same machine, choose by what unblocks the maintainer soonest; tell the other worker what to do meanwhile and exactly what it waits for. Add up the heavy checks your briefs ask for: when several branches need the same full check, integrate them and run it once. After a collision, add one dated line to the skill's observations.
```

## 2. Home rules: one sentence amended

**Destination:** the same constant, the paragraph that begins "On a result wake" (currently line 23).

Replace this sentence:

```text
When a worker settles unfinished and no genuine maintainer decision is needed, resume it at once.
```

with:

```text
When a worker settles unfinished and no genuine maintainer decision is needed, resume it at once, unless its next step is heavy work the shared machines cannot take yet; then resume it with other work first, or say when it will resume and arm the automation that does it.
```

**Reason:** the present sentence tells Home to resume without regard to what else is running. On
2026-11-12 at 21:19Z Home resumed four workers in one call for that reason.

## 3. Owning doc: host load

**Destination:** `packages/gateway/docs/host-load.md`. Replace everything from the title down to the
sentence that ends "not a duplicate status projection or admission queue." with the text below. Keep the
sentence after it ("See the Git/gh skill.") as it is. Also delete the last bullet of
"Host-pressure signal" ("The level informs; it does not hold workers back. Home starts each authorized
worker at once at any level.") and replace it with the bullet given after the block.

Land this together with drafts 1 and 2 and the verify change in the migration list, because the doc must
state current behaviour.

```markdown
# Host load and independent workers

Home owns how heavy work is spread across this Mac and the Mac mini: what runs, when, where and in what
shape. Heavy work is a simulator test run, a large build, a full test suite or a load test. The Gateway
itself starts every authorized task without a cap or queue. Home plans each task's heavy phases in its
brief and adjusts by steer, using the `resource-stewardship` skill. Host pressure is one of its inputs.

There is no shared CPU, memory or load-average admission, no gate, no merge lock and no load guard. Do
not add one. Earlier ones were removed for cause (#1253), and worker-written load guards interrupted
passing runs (the 2026-11-13 resource audit). Decisions belong to Home. Code keeps only exclusion and
cleanup:

- Each simulator lane and physical device has an exclusive lease.
- Host slots (`scripts/ios-test-lock.py --host-slot`) are a ceiling of three simulator jobs on this Mac.
  The ceiling is not a number to fill. A job that needs a slot waits for it and names the holder.
- `verify` runs one simulator lane unless its caller passes `--ios-jobs 2` or `3`. Home says so in the
  brief when the Mac is otherwise free.
- Local full-Gateway runs take `/tmp/tron-full-gateway.lock` in arrival order. The mini runs one job at
  a time under its own lock.
- Each command cleans up its own processes and simulator. Settling a task reaps what its commands left
  (below). Do not kill another worker or Stable.

Workers follow the "Heavy work" paragraph of their brief, announce heavy phases in check-ins that begin
`Heavy start:` and `Heavy done:`, and read the host with the `host-resources` skill before they start.
Use ordinary Git/gh to inspect current branches, worktrees and issues. A parked claim is not proof of
live work.
```

Replacement bullet for "Host-pressure signal":

```markdown
- The level informs Home's plan. The Gateway does not hold workers back on it.
```

If open decision 4 is taken (host reading in `task list`), add one more bullet there when it lands:

```markdown
- Home's `task list` result carries the current sample and, for each running task, whether its command
  scope holds heavy processes, so Home can read the host on a wake.
```

## 4. Standard oversight tick

**Destination:** the `resource-stewardship` skill, section "Oversight tick" (already included in the
draft skill). Home pastes it into the `prompt` of an oversight automation in place of today's lists of
absolute rules.

```text
Oversight tick for <task ids>. Read task list. For each task: running with a check-in in the last 60 minutes, leave it; silent longer, steer once for status; settled unfinished with no maintainer decision needed, resume it. Before any resume or steer that starts heavy work, apply the resource-stewardship skill: read the "Heavy start:" and "Heavy done:" check-ins, and give the machine to one heavy job at a time unless the skill's facts say the shape is safe. If two workers are waiting on each other, name the order now. Notify the maintainer once for a genuine decision or when everything has settled, then pause this automation. This message is not maintainer authority.
```

## 5. What Home stops sending

No file. This is the behaviour change the drafts above replace:

- Load thresholds in briefs, steers and automations ("load1 below 40", "above 80 for 120 s").
- "One native lane across workers" with no named order.
- Instructions to keep a process alive so other workers can detect it.
- Long lists of "no X" with no reason. The model-craft skill already asks for a scope and a reason on
  every prohibition.
