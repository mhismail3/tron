# Home audit — <UTC window>

Report contract: `home-audit-v1`. Units, cohorts and evidence quality are part of
every metric. Preserve these sections across reports; missing values are
`unavailable`, not zero. Do not copy private example data into this template.

## Summary

Verdict, material regressions/improvements, and the next highest-value action.
State whether this is a full audit or a focused slice.

## Scope and provenance

- UTC window `[start, end)`; previous report/window; capture time.
- Repository SHA and dirty state; selected payload SHA; separately observed live
  runtime identity; cohort boundaries and unknown deployment intervals.
- Home/chapter scope; provider/model/config changes; source cutoffs/hashes.
- Coverage ledger: fully reviewed / sampled / excluded, with reasons.
- Missing telemetry, capture races, malformed records, boundary exclusions and
  ambiguous attribution. State whether the comparison windows are matched.

## Behavior and orchestration

| Measure | Current | Prior comparable cohort | Evidence / limits |
|---|---:|---:|---|
| User activations / wakes | | | |
| Completed / failed / interrupted / still open | | | |
| Tasks admitted / settled / useful accepted results | | | |
| Questions / opportunities requiring clarification | | | |
| Profile changes / preference opportunities followed | | | |
| Search and zoom attempts / successes | | | |
| Stop, deadline, wake and result-delivery failures | | | |

Include a few source-linked examples, not a full transcript. Define a useful
result or unnecessary question before assigning a count; label judgment samples.

## Usage and timing

One row per owner cohort (Home, worker, child, summarizer), provider/model,
deployment interval and request position (first/later/all). Do not add overlapping
rows. Report:

`sampleCount, excludedCount, input, cacheRead, cacheWrite, output,
weightedCacheReadFraction, recordedCost, costBasis`

Record counter semantics and provider support. Include user/wake subcohorts when
available. Give request-start gap distributions separately from proxy timestamp
gaps. Report TTFT, activation duration and result-delivery latency only where the
named endpoints are captured; identify cold, warm and unknown cache cases.

## Memory quality and cost

Catalog size, paid/free nodes by level, view bytes/parts/levels, backlog,
corrections/retries, merge frequency, context sizes and observed zoom use.
Sample provenance/faithfulness against source; count reviewed samples and failures.
State unavailable measurements and do not infer node usefulness from level alone.

## Cache diagnosis and design comparison

| Finding | Owner / revision | Evidence class | Alternative explanation | Next proof |
|---|---|---|---|---|

Include payload block structure and prefix comparison when available. Distinguish
observed misses from inferred causes. Pin upstream revision/hash and provider
documentation access date. Compare the full relevant design, noting intentional
Tron deviations. Never present upstream modeled cache rates as Tron measurements.

## Earlier findings

| Issue | Current tracker state | Commit / selection / running evidence | Behavior verified? |
|---|---|---|---|

## Recommendations and verification

Ranked recommendations with expected benefit, evidence strength, protected
behavior, exact reproduction/validation required, and owner. List commands
actually run, their outcomes and artifact paths; do not report a planned test as
passed. Note any paid experiment requiring permission and any maintainer-only
transition. List retained evidence and confirm cleanup of audit-owned resources.
