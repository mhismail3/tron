# Buildkite advisory shadow

This pipeline measures whether Buildkite can reproduce Tron's authoritative
GitHub Actions validation. It has no merge, release, signing, notarization,
deployment, or promotion authority. Its status must never be required by the
GitHub `main` ruleset.

Create a secretless Buildkite cluster with the standard hosted queues:

- `linux-medium`, backed by `LINUX_AMD64_4X16` or better;
- `macos-medium`, backed by `MACOS_ARM64_M4_6X28`, macOS 26.6, Xcode 26.3,
  and the iOS 26.2 simulator runtime.

Do not attach pipeline, cluster, queue, or organization secrets to either
queue. In the GitHub provider settings, disable commit-status publication,
fork builds, tag builds, and the GitHub-specific
`build_pull_request_merge_commits` provider-generated merge checkout;
the source adapter resolves GitHub's exact webhook merge itself. Enable pull-request and ready-for-review events,
including reopened PRs; keep "skip PR builds for existing commits" disabled.
Enable branch builds only for `main`. Enable both Skip Intermediate Builds
and Cancel Intermediate Builds with branch filter `!main`; this retires queued
and running superseded PR work without canceling `main` history. The checked-in
bootstrap additionally rejects drafts, non-`main` pull-request bases, other
branches, and tags.

The settings export uses Buildkite's provider and pipeline API names directly:
`provider.id` is normalized as `provider_id`, webhook URL presence as
`provider_webhook_url_present`, and provider settings retain names such as
`trigger_mode: code`, `publish_commit_status`, `publish_blocked_as_pending`,
`build_pull_requests`, `build_pull_request_ready_for_review`,
`build_pull_request_reopened`, `build_pull_request_merge_commits`,
`build_branches`, and `pull_request_branch_filter_enabled`. Pipeline-level
controls retain `branch_configuration`, `skip_queued_branch_builds` plus its
filter, and `cancel_running_branch_builds` plus its filter. The evaluator rejects
the GitLab-only `build_pull_request_merge` spelling and translated aliases such
as `code_trigger_mode`; collectors must not invent provider settings that the
Buildkite API did not return.

The bootstrap resolves the moving GitHub merge ref exactly once, records its
commit/tree/parents, proves its pre-checkout bootstrap bytes equal the merge's
bootstrap, creates a history-bounded, prerequisite-excluding thin bundle
proportional to the merge delta, and loads the dynamic job graph from that
checked-out merge. Each isolated workload downloads the pinned
context, verifies its SHA-256 manifest, checks out the bundled commit without
re-reading the moving ref, and revalidates the context before running. This
prevents one Buildkite build from mixing source trees when a PR changes midway.
The source-context step has no automatic retry and explicitly rejects manual
job retries inside a build. Its GitHub merge-ref fetch has a short bounded
propagation retry, but every attempt targets the same ref and the accepted merge
must retain the provider-cached GitHub webhook's exact base, head, and merge
SHAs. Main similarly requires exact webhook `before`/`after` identities. That
raw payload is held only in a mode-0600 temporary file and never uploaded. If
the agent is lost, start a new Buildkite build so source context is repinned in
a new build rather than changing beneath already-uploaded jobs.
Pinned workloads retry only Buildkite's agent-lost status (`-1`), never a test
or product failure. Agent v3 uploads use `--reject-secrets`; agent v4 omits the
removed flag and relies on v4's fail-closed default. Unknown CLI semantics stop
the upload. Both versions must also expose `--reject-parse-warnings` or the
dynamic graph is rejected. The repository's checksum-pinned agent dry-runs both
graphs with secret and parse-warning rejection before either provider accepts
the definition.

Persistent cross-build Cargo, target, rustup, and Docker cache volumes are
deliberately absent. Pull-request code must not seed writable state later
restored into `main`; hosted agents are ephemeral. The derived digest-pinned
Rust image installs and smoke-tests the root toolchain's exact rustfmt and
clippy components before running the repository quality suite.

Checksum-pinned binary installers build each version in a unique sibling
staging prefix, seal the complete payload with a file manifest, validate its
tool-specific runtime and support assets, and then rename it into place. A
missing or changed payload invalidates the cache and is rebuilt; incomplete
prefixes are never accepted merely because their primary executable exists.

Every job records UTC start/end times, duration, retry metadata, command output,
normalized source context, and a SHA-256 artifact manifest. A successful ready
PR also emits advisory provider-neutral validation evidence containing all six
job manifests, iOS metrics, and the pinned provider context. iOS metrics upload
on every result; the full `xcresult` is retained only on failure. Main builds
run the same six workloads but do not create PR merge evidence. GitHub Actions
remains authoritative; shadow evidence is never reusable for
merging or releasing.

An always-run, soft-failing operational-observation step records Buildkite's
state/outcome for all six jobs and marks each manifest identity-bound, invalid,
or missing. It does not make the shadow authoritative. Canceled dependencies
and builds that fail before the dynamic graph exists cannot run that observer,
so the 30-day ledger must be built from complete provider API exports. It must
also retain missing/outage runs, retries, rebuild ancestry, and superseded
heads; retries and rebuilds remain one trigger sample. The event universe is
every non-draft PR-to-`main` `opened`, `synchronize`, `reopened`, and
`ready_for_review` source event, including PR titles with CI-skip tokens. Any
provider-level suppression is a recorded candidate `missing`, never an
exporter exclusion.
Reconcile GitHub's bracketed and `skip-checks` trailer forms together with
Buildkite's additional `[ci-skip]` and `[skip-ci]` spellings. Repository
commit-message protection cannot prevent Buildkite's PR-title suppression, so
the independent event ledger and `skip-token-trigger-continuity` blocker are
not optional.
Repeated actions for the same PR+source remain distinct trigger records but
form one representative reliability/latency cohort, preventing webhook retries
or manual rebuilds from inflating the sample count.

Validate the adapter locally with:

```bash
scripts/ci-shadow-run.sh --self-test
scripts/validate-ci-definitions.sh
```

Configure Buildkite artifact retention for at least 90 days and export provider
API observations to an independently retained ledger. No Buildkite pipeline,
queues, retention policy, collector, or credential integration is created by
these repository files; the shadow remains inert until a maintainer completes
that external setup and the GitHub ruleset hardening below.
The initial bootstrap is still arbitrary PR code with an agent session token.
Before activation, provider-side cluster rules must ensure this dedicated
secretless hosted cluster exposes only `linux-medium` and `macos-medium`; it
must not be able to target any self-hosted or release queue. Pipeline parsing
and secret rejection do not replace that external confinement.

After downloading and extracting the GitHub and Buildkite validation artifacts,
compare the complete payloads with:

```bash
python3 scripts/ci-parity-report.py \
  --reference github-validation-evidence.json \
  --reference-artifacts github-validation-artifacts/ \
  --candidate buildkite-validation-evidence.json \
  --candidate-artifacts buildkite-validation-artifacts/ \
  --output ci-parity-report.json
```

The comparator hashes every evidence-manifested file and binds the context, iOS
metrics, job manifests, and bootstrap records. Every successful job manifest
must structurally name its exact job-local command log and provider context;
iOS must name its exact metrics path, and PR Mac must name
`packages/mac-app/dist/Tron-dryrun.dmg`. Context and metrics are content-bound,
but nested command-log and DMG payload custody remains external because those
files are not copied into shadow evidence. Its result is offline payload
integrity and semantic parity, not proof of provider custody, nested payload
identity, artifact identity, or run status; provider API exports are still
required for cutover evaluation.

The offline cutover evaluator joins strict normalized provider and proof inputs
and checks the policy's latency, correctness, delivery, absolute reliability,
paired improvement, and exact statistical gates. Run it with `--help` for the
required files. Even when thresholds pass, its decision is only
`observation-thresholds-satisfied-provenance-unverified` and
`eligible_for_external_review` remains false: normalized files cannot
authenticate live API responses. Live provider-API, product-evidence, and
controlled-proof re-verification is mandatory before any separate authority
review. GitHub's manual `workflow_dispatch` also has no candidate parity lane,
so `workflow-dispatch-parity` remains an explicit full-replacement blocker.
Before connecting the app, the GitHub ruleset must also bind required context
`CI summary` to the GitHub Actions app integration ID `15368`; context text
alone is insufficient because another app could publish the same name. The
normalized authority-ruleset export records that binding, while the candidate
settings export proves Buildkite status publication remains disabled.
Measured TestFlight rows join both providers' exact main-run source, outcome,
attempts, operational evidence, and latency, then bind delivery to the
authoritative GitHub completion. They establish candidate main validation
parity but not a Buildkite-main-to-GitHub-release handoff, so the report keeps
`candidate-main-release-handoff-parity` blocking as well.

The replacement gate is intentionally broader than this merge-validation
experiment. `config/ci-policy.json` inventories GitHub's fast-feedback, server
performance, iOS performance, iOS/TestFlight release, and Mac release workflows
as well. Their candidate coverage is currently `unimplemented`, and every
corresponding policy-owned requirement remains blocking even if the six-job
shadow produces perfect measurements.
