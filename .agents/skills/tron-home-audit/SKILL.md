---
name: tron-home-audit
description: Audit Home behavior, memory quality, orchestration, and provider cost over a bounded observation window; produce comparable evidence-linked reports and distinguish deployed behavior from repository fixes.
---

# Home audit

Use this for a recurring Home health report or a focused cache/memory investigation.
Apply [project rules](../../../AGENTS.md), [code health](../tron-code-health/SKILL.md)
and, for performance claims, [performance](../tron-performance/SKILL.md).
An audit is read-only; creating this report does not authorize a runtime fix,
paid model experiment, worker launch, restart, or a change to Home's memory.

## 1. Freeze the question and observation window

Use [report.md](report.md) as the report contract. Keep its section names and
metric definitions across runs; use `unavailable`, not zero, for missing evidence.
Choose a UTC half-open window `[start, end)` and the comparison report. Default
to the elapsed period since the previous audit's cutoff, with a separate lifetime
summary if useful. Do not compare a lifetime total with a daily total.

Record repository SHA/dirty state, selected Stable payload manifest revision,
and separately the live runtime identity when available. A selection manifest
is not proof that the running process loaded it. Record model/provider changes,
restart boundaries and configuration changes; split cohorts rather than attributing
all observations to today's build. Never restart to obtain a cleaner measurement.

Read the Home record through its owner or the configured Gateway state root to
find chapter IDs. Resolve those exact canonical sessions through the session
catalog; do not search all private sessions. Include sealed chapters overlapping
the window. Read only relevant task records and worker evidence. Discover paths
from configuration/owners, never from a previous report's machine-specific paths.
Do not open a canonical session in a second runtime.

For each append-only source, record path privately, bounded byte cutoff, hash of
the captured prefix, complete-line count and capture time. If its prefix changes
or is truncated during capture, discard that sample and report the race. Ignore
an incomplete last line explicitly; malformed complete lines are an evidence
failure, not permission to silently skip data. Read mutable owner records with
revision fences or report them as separately timed observations. Do not claim a
transactional cross-file snapshot. Hashes identify evidence; they do not anonymize
private data. Keep source text and identifiers out of public issues.

## 2. Reconstruct activations before counting

Start at `packages/gateway/src/sessions/invocation-receipts.ts`, Home's request
policy and the current canonical session format. Do not hard-code an old receipt
schema. Join start/accepted/binding/terminal receipts by exact invocation identity;
deduplicate receipt identities and follow canonical branch ancestry. A retry,
steering message or tool loop is not automatically another activation. Separate
user activations, result-triggered wakes, interrupted/failed work and incomplete
activations at either window boundary.

Join assistant usage to its activation using canonical boundaries. If receipt
intervals overlap, resolve ownership from canonical evidence or exclude the
ambiguous activations from first/later-request metrics. Count excluded records
and preserve their contribution to whole-window totals separately. Never assign
an orphan assistant to whichever user message happened to be most recent.

For every cohort, distinguish:

- Home orchestration calls;
- task worker calls;
- task-owned child calls (check whether worker totals already include them);
- episodic summarizer calls, including corrections/retries and free nodes.

Do not add inclusive task totals to the same child usage again. Persisted usage
is not necessarily a complete ledger of provider attempts: label whether a row
counts canonical assistant records, dispatched requests, or billed attempts.

## 3. Produce comparable measurements

Normalize provider usage only after reading its adapter's semantics. For the SDK
usage shape where `input` excludes cache reads and writes:

`promptTokens = input + cacheRead + cacheWrite`

`weightedCacheReadFraction = sum(cacheRead) / sum(promptTokens)`

A Home task's spend record already keeps these apart: its `inputTokens` is fresh
input only, beside `cacheReadTokens` and `cacheWriteTokens` (#1250).

Do not average per-request percentages, divide by output-inclusive totalTokens,
or add cached tokens twice for a provider whose input already includes them.
An unsupported cache-write counter is not proof that no cache was created.
Separate first request of an activation from subsequent requests; split by
provider/model, user/wake and deployment cohort. Report sample counts, missing
usage, exclusions, totals, and p50/p95 where samples support them. Provider cost
fields are recorded estimates unless reconciled to billing; subscription pricing
must not be presented as cash spent. Report bytes and tokens separately.

Timing must name its measurement points: admission, dispatch, first streamed
content, settlement, result delivery. A canonical assistant timestamp is **not**
TTFT. When streaming telemetry is absent, report TTFT unavailable. For TTL analysis,
use actual request-start gaps when available; assistant timestamps are only a
proxy and cannot prove expiration.

Behavior review uses bounded examples with canonical entry references: unnecessary
questions, correct preference use, delegation/model choice, useful reports,
search/zoom success, task result settlement, wake chains, Stop/deadline behavior,
and recovery. Count opportunities as well as failures. A successful launch does
not prove completion, and a completed task does not prove a useful result.

Memory review records source count/bytes, node counts by level, free versus paid
builds, correction/retry counts, backlog, view bytes/parts/levels, merge events,
and zoom use where available. Check sampled summaries against exact sources for
speaker attribution, invented completion, injection contamination, omitted durable
decisions and lost discoverability. Unused higher-level nodes in a young view
are not by themselves dead work: parents prepare future merges.

## 4. Diagnose cache misses at the real boundary

Trace current owners, rather than assuming the recipe was implemented:

- `home/home-memory.ts`: view construction and content-block boundaries;
- `home/home-request-policy.ts`: activation framing, nonce placement, marks, TTL;
- `home/tron-home-extension.ts` and `home/home-profile.ts`: system/profile changes;
- `episodic/episodic-tree.ts` and `episodic/episodic-memory.ts`: merge order,
  batching, readiness, scheduling and restart reconstruction;
- `episodic/episodic-compactor.ts` and `episodic/cache-layout.ts`: summarizer
  context, correction loop and provider markings;
- pinned provider adapter and owning wire-level integration/E2E journeys.

For two consecutive activations, compare actual final provider payloads when
available: tools, system, ordered messages/content blocks, cache markers/TTL,
model/account affinity and everything preceding the view. Record the first
changed block and byte, stable-prefix length, and the previous marked prefix
reachable within the provider's documented lookback. Also inspect the third
activation: a layout may reuse the second yet repack its blocks on the third.
Compare structure as well as concatenated text. Hashes alone locate changes but
do not explain them. Never capture credentials or authorization headers.

Separate possible causes: TTL, profile/instruction changes, account/model switch,
rebalance, restart, block repacking, changing state ahead of memory, and concurrent
writes before the first response begins. Do not infer the cached section solely
from a token count. Read provider documentation; do not invent hashing semantics.
A fake server's fixed cache usage or a text-only simulator is not a real cache hit.
A paid live A/B probe requires user authority and a bounded cost; otherwise report
the hypothesis and the exact missing experiment. Prefer existing wire journeys,
with a known-bad control, before adding new instrumentation.

When comparing [UniiChat](https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449),
read the **whole current revision**, record its revision or content hash, and
inspect relevant revision diffs. Distinguish upstream simulation from live
measurements. Map each recommendation to a Tron owner, evidence and deliberate
deviation. In particular compare age ranking, low-water target, persisted view,
stable block shape, compactor context size and concurrency. Do not blindly adopt
shared prompts/tools across different models, a new thinking level, retention
pricing, unrestricted retry, or append-only rules that defeat Tron's redaction
and trust requirements. Preserve canonical ownership and safety boundaries.

## 5. Report and follow through

Write the report privately to a user-selected artifact path or the internal
workspace's `files/`, not into source. Keep raw evidence private and bounded;
retain only what is needed to reproduce the numbers. Produce the report sections
in the template plus machine-readable metric rows when useful. Present a useful
report with `display`; do not emit a dashboard image merely for decoration.

Recheck earlier issues and commits. Use distinct statuses: open; implemented on
main; selected for deployment; observed running; behaviorally verified; inconclusive.
An issue closure is not behavioral proof. Rank recommendations by impact and
evidence strength; distinguish inspected, observed, reproduced and inferred.
Answer-only findings stay in the report; track later implementation only when
requested, through the work tooling. Never place private transcript excerpts in
GitHub. Remove only audit-owned temporary artifacts/processes; retain the promised
report and its necessary evidence, and never clean up Home's workers.
