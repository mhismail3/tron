# Web research diagnosis harnesses (#1927)

These are opt-in forensic/measurement scripts, not runtime code or a production
change. They do not install packages, start a Gateway, load a canonical session
into a runtime, write credentials/settings, or make authenticated API calls.
Keep their outputs outside Git: session histories can contain private data.
The full design and incident inventory live in the issue and internal workspace
`files/web-search-redesign/PROPOSAL.md`, pending maintainer approval.

## Historical evidence

```sh
python3 scripts/web-search-audit.py --root "$HOME/.tron" --output /private/output/calls.json
```

The fixed window is October 21 19:41:52–October 24 19:41:52 UTC, 2026. The scanner
correlates native JSONL tool IDs, deduplicates exported transcripts, records model,
duration, result bytes and next actions, and separately inventories browser calls.
It filters fixture paths and files modified before the window. Keyword flags are
triage candidates, not verified incident counts; retrieved content can quote an
error without causing a new request. Embedded codemode calls require inspection
of wrapper code/results and have no independent timing guarantee. Redaction is
best-effort; never publish the output or raw session data without review.

## Free/keyless measurements

```sh
python3 scripts/web-search-measure.py --output /private/output/measurements.json
python3 scripts/web-fetch-measure.py /private/output/fetch-measurements.json
```

These explicitly send public queries/URLs to DDG, Firecrawl keyless and Jina
Reader. No auth/account required; shared-IP daily quotas still apply. Search uses
three fixed queries, two rounds reversed provider order, and a five-result compact
projection. The original Quint expected-domain oracle is outdated: returned
`quint.sh` / `informal.systems` are valid primary domains even though the stored
`quint-lang.org` test is false. Preserve this discrepancy, not a perfect-quality
claim. HTTP timing includes DNS/TLS/body, not tool/model orchestration. Samples
are descriptive smoke tests, not precision/recall or p95 estimates. Bytes/4 is
only a token proxy. Response sizes are capped; timeout failures remain samples.

## Safe-outcome reproductions

Pass an absolute path to an already built Home module. It imports tool code only,
never opens a live Gateway/session. The fixture uses an owned ephemeral local
HTTP server and the existing test transport seam; that server is closed on exit.

```sh
scripts/tron-node exec node scripts/web-search-repro.mjs \
  /absolute/path/to/dist/modules/home/home-research-tools.js \
  /private/output/home-repro.json

scripts/tron-node exec node scripts/web-search-repro.mjs \
  /absolute/path/to/dist/modules/home/home-research-tools.js \
  /private/output/failing-before.json --fixture-only --expect-safe
```

The first command includes three public live requests. The second uses only the
local socket. `--expect-safe` deliberately exits **1** if HTTP200 error-page
content becomes `status:ok`; this is a failure reproduced on unchanged code, not
a repaired regression or a passing-after claim.

The installed Firecrawl adapter has an independent source-status defect. Use an
already installed Jiti loader (Node cannot strip TypeScript under node_modules):

```sh
scripts/tron-node exec node scripts/web-firecrawl-adapter-repro.mjs \
  /absolute/path/to/pi-web-access/firecrawl.ts \
  /private/output/firecrawl-adapter-repro.json \
  /absolute/path/to/jiti/lib/jiti.mjs
```

It sets only its fixture process's API base URL to an owned local HTTP server;
no Gateway configuration is changed. The server returns API `success:true` with
source `metadata.statusCode:404`. Exit **1** means the actual adapter accepted
this as `error:null`. Jiti filesystem caching is disabled. No provider account,
remote scrape or credential is needed for this control. A loader failure is not
evidence of the semantic defect; check the saved result and explicit FAIL line.

## Validation and scope

Use Python AST parsing and Node `--check` for syntax. The scanner was also run as
a spawned CLI against real temporary JSONL files, proving correlation and
exported-copy deduplication; its temp directory was removed. The real Home tool
and Firecrawl adapter controls above are the surviving behavior oracles.
E2E Gateway/RuntimeRegistry, real child-role parity, cancellation, budget and
error-page regression coverage must accompany an approved implementation. No
production bug is fixed by committing these harnesses. Do not wire live provider
calls into CI or auto-promote this investigation branch.
