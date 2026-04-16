---
name: deep-plan
description: Elicit comprehensive requirements through layered batches of low-burden questions (yes/no, multiple choice, short text), triangulate intent via convergent-validity probing, then produce a detailed written plan. Use when the user gives a short seed idea and wants a rigorous plan before implementation.
disable-model-invocation: true
allowed-tools: AskUserQuestion, Read, Write, Bash, Grep, Glob
argument-hint: <short seed idea>
tags:
  - planning
  - elicitation
  - requirements
---

# /deep-plan — Layered Requirements Elicitation

You take a 1–2 sentence seed idea from the user and, through systematic layered questioning, triangulate a complete and accurate understanding of what they want before writing a plan.

The method borrows from psychometric convergent-validity testing: ask redundant questions phrased differently, detect contradictions, reconcile them, and ratify each layer before advancing. The goal is **both precision** (you know exactly what the user wants) **and coverage** (you know the full set of what they want, including edges they didn't think to mention).

This skill is distinct from the `plan` skill, which is open-ended dialogue. `deep-plan` is structured: adaptive layers, constrained question formats, reconciliation at every layer boundary, explicit termination on convergence.

## Operating principles

These apply in every layer, every round, without exception.

- **Questions, not assumptions.** Never infer a constraint — probe for it. If you would say "I'll assume X", ask instead.
- **Low burden per turn.** Every question is yes/no, 2–4 option multiple choice, or short text. Never open-ended unless triangulation strictly requires it.
- **Layer by layer.** Probe one dimension to convergence, ratify it, then advance. Do not bounce between layers.
- **Ratify before advancing.** Each layer ends with a summary the user confirms, refines, or escapes.
- **Detect, then reconcile.** When answers conflict — literally or in spirit — surface the conflict as its own targeted question. Never silently pick one.
- **Respect the user's time.** Every ratification gate includes a "ship it" escape hatch.

## Session start

The user invokes with a short seed (e.g. `/deep-plan add a dark mode toggle to the iOS settings`).

Before asking anything, do two things:

1. **Select layers.** Choose which layers from the taxonomy below apply to this seed. Intent, Scope, and Success always apply. Others are topic-dependent.
2. **Announce the plan.** Tell the user which layers you'll probe and roughly how many rounds to expect:

   > I'll probe these layers: Intent, Scope, Users & Context, Edges, Success. Expect roughly 5 rounds of 3–5 questions each. At any ratification gate you can select "Ship it" to cut the session short and generate a plan from what we have.

Then begin with the first layer.

## Layer taxonomy (adaptive selection)

| Layer | What it probes | Apply when |
|---|---|---|
| Intent & motivation | The "why" behind the ask; problem being solved; what success changes | Always |
| Scope & boundaries | What's in, what's explicitly out, what's deferred | Always |
| Users & context | Who is affected; invocation context; frequency of use | UX / feature tasks |
| Technical constraints | Stack, compatibility, performance, existing patterns to follow | Implementation tasks |
| Interfaces & data | Inputs, outputs, APIs, schemas, external systems | Integration tasks |
| Edges & failure | What can go wrong; acceptable vs. blocking failures | Non-trivial logic |
| Success & verification | What "done" means; how to prove it works | Always |

Layer order matters. Intent first, Success last. Others in the order that most naturally builds understanding for the specific topic.

## Round mechanics (per layer)

Each layer follows this five-step pattern.

### 1. Primary batch

A single `AskUserQuestion` call with 3–4 questions, each probing a distinct facet of the current layer. Mix formats deliberately:

- **Yes/no** for crisp boundary decisions
- **2–4 option multiple choice** for axes with known trade-offs
- **Short text** (sparingly) only when the answer space is genuinely open

Every question label should be scannable in under 5 seconds.

### 2. Probe batch (conditional)

If the primary batch left ambiguity OR the layer is high-stakes, issue a follow-up batch of 2–3 questions. **At least one must be a rephrased version of a primary question** — same underlying concern, different angle. This is the convergent-validity mechanism.

Examples of good rephrasing:

- Primary: "Should errors be logged to stderr?"
  Probe: "When this fails in production, who should notice first?"
- Primary: "Is backward compatibility required?"
  Probe: "Is it acceptable if existing callers have to update their code?"
- Primary: "Is performance a hard constraint?"
  Probe: "If this made requests 20% slower but simpler, would that be OK?"

The rephrasing should feel like a natural new question, not an obvious re-ask. If the user answers the rephrased question inconsistently with the primary, proceed to reconciliation.

### 3. Reconciliation pass (only if contradictions surfaced)

One targeted `AskUserQuestion` that names the conflict directly:

> Earlier you indicated [primary answer], but your latest answer suggests [probe answer]. Which is closer to what you actually want?
>
> - [primary interpretation]
> - [probe interpretation]
> - [synthesis that honors both, if one exists]

Record the chosen interpretation in your mental ledger and in the elicitation trail.

### 4. Ratification

Summarize the layer's conclusions in 2–4 sentences. Then `AskUserQuestion`:

> For [layer name], I understand: [summary]. Is this right?
>
> - Accurate — move on
> - Accurate, but add: (short text)
> - Refine: (short text)
> - Ship it — generate the plan now with what we have

### 5. Advance

Move to the next layer only when the user chose "Accurate — move on" (or equivalent). If they chose "Ship it", skip to plan generation and mark remaining layers as unratified in the output.

## Termination

Stop probing and write the plan when any of:

- Every selected layer has been ratified
- The last probe batch yielded ≤1 piece of genuinely new information (convergence signal)
- User selected "Ship it" at any ratification gate

When terminating early, the plan's **Open questions** section lists which layers were not fully ratified and what the skill was about to probe.

## Inconsistency tracking

As you collect answers, keep a running ledger in your working memory:

```
Layer → facet → answer → source question
```

When a new answer conflicts with a recorded one (directly or by implication):

1. Do not silently overwrite.
2. Treat it as a reconciliation trigger (see Round step 3).
3. Record the resolution in the elicitation trail with both original answers and the chosen interpretation.

## Plan file output

Write the final plan to `~/.tron/workspace/plans/YYYY-MM-DD-<slug>.md`. Use absolute paths in the `Write` tool call — `~` does not expand. Ensure the directory exists via `Bash` (`mkdir -p`) before writing.

Slug = short kebab-case summary of the seed idea (e.g. `dark-mode-settings-toggle`).

Structure:

| Section | Content |
|---|---|
| Context | Original seed + the elicited "why" from the Intent layer |
| Goals & Non-goals | Explicit in/out lists, derived from the Scope layer |
| Constraints | From Technical / Interfaces layers, each with rationale traced to user answer |
| Approach | Chosen strategy; alternatives dismissed and why |
| Key decisions | Table: decision → user's elicited preference → rationale |
| Edge cases | From the Edges layer; flagged as acceptable vs. blocking |
| Verification | How to prove "done", from the Success layer |
| Open questions | Any layers not ratified, if session ended early. Omit section if all ratified. |
| Elicitation trail | Collapsible (`<details>`) appendix: layers probed, rounds per layer, every contradiction surfaced and how it was reconciled |

**Every key decision in the plan must trace back to a specific user answer.** The elicitation trail makes the reasoning auditable. If you find yourself writing a decision without a clear source answer, that's a signal you skipped a probe — go back and ask.

After writing, present the path and a 3-sentence summary to the user. Do not start implementing.

## Worked example

Seed: `add rate limiting to the API`

**Layer selection.** Intent, Scope, Users & Context, Technical Constraints, Edges & Failure, Success. Skip Interfaces & Data — rate limiting is additive middleware, not a new interface.

**Layer 1 — Intent & motivation. Primary batch:**

```
AskUserQuestion:
  Q1: "What problem is rate limiting solving?"
      [multiSelect: true]
      - Abuse / malicious traffic
      - Fair usage across tenants
      - Protecting downstream systems from overload
  Q2: "Is there an active incident driving this?"
      - Active incident — fix fast
      - Known recurring issue — solve properly
      - Preventive — no current problem
  Q3: "Who decides what 'too many requests' means?"
      - Hardcoded global limits
      - Per-API-key limits in config
      - Dynamic — adjustable at runtime
```

User answers: "Fair usage across tenants", "Preventive", "Per-API-key in config".

**Probe batch (high-stakes layer, worth it):**

```
Q4: "If one tenant exceeds their limit, what should happen to other tenants?"
    - Unaffected — isolated per-tenant counters
    - Slight degradation is acceptable
Q5: "Re-asking indirectly: would a global limit that happened to be fair be acceptable?"
    - Yes — fairness is the outcome, mechanism doesn't matter
    - No — per-tenant isolation is the point
```

If Q5 answer contradicts Q1+Q3 (e.g. "yes, global is fine"), reconcile.

**Ratification:**

> For Intent: rate limiting is a preventive measure to enforce fair usage across tenants, with per-tenant isolation and per-API-key configured limits.
>
> - Accurate — move on
> - Accurate but add: ___
> - Refine: ___
> - Ship it

Advance to Layer 2 — Scope — once ratified. Continue until all selected layers are done or the user ships it.

## Gotchas

- **Do not ask free-form questions out of laziness.** Convert every elicitation to a constrained format where possible. Open-ended questions shift the cognitive load to the user.
- **Do not advance a layer without ratification**, even if the user's answers "seem clear". The ratification summary frequently surfaces misunderstandings you didn't notice.
- **Do not conflate layers.** Resist the urge to ask a "quick scope question" in the middle of a Technical Constraints round — queue it for the Scope layer.
- **Do not skip reconciliation to save time.** A silent pick produces a plan the user will reject.
- **When in doubt about running a probe batch, run it.** The cost is one extra `AskUserQuestion` call; the benefit is catching a contradiction before it poisons the plan.
- **Do not start implementing.** This skill produces a plan artifact only. The user (or a separate session) executes it.
