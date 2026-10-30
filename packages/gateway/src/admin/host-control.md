# Supervised host control

Gateway update, Mac replacement, iPhone install, device labels, drain and exit.
Owners: `gateway/admin` (`gateway-update-service.ts`, `ios-device-install-service.ts`),
`gateway/run` (`restart-drain.ts`, `gateway-work-registry.ts`), `gateway/lifecycle`
(`exit-after-shutdown.ts`). A reference,
not authorization: Stable rebuild, update, rollback, promotion, restart and
`scripts/tron dev handoff` are the maintainer's
([charter](../../../../AGENTS.md#safety-boundaries)); agents run only the Debug
Gateway (`scripts/tron dev`, port 9848). Procedures: [Mac
development](../../../mac-app/docs/development.md).

## Gateway updates

- `gateway.update` (`channel` `stable|dev`, `mode` `source|artifact|auto`, candidate
  version and fingerprint, `commandId`; artifact promotion needs both exact fields)
  and `gateway.rollback` (channel, `commandId`) acknowledge helper admission only;
  `gateway.update.status` (each state document ≤ 64 KiB, fail closed) is authoritative
  with build/staging/draining/promotion/rollback/failure progress, active command and
  rollback availability. A runtime acts only on its own `TRON_GATEWAY_CHANNEL`.
  `gateway.update.config` stores only a trusted absolute non-symlinked `sourceRoot`
  and optional `artifactRoot` in `gateway/update-config.json`; `gateway-update.v1`
  is advertised when the update helper is available (a source need not yet be configured).
- Quick Rebuild uses one repository-identity admission in `document-admission.ts` for
  Gateway and device source roots; Mac replacement reads the Gateway root through
  that same admission. Identity requires regular, non-linked `packages/gateway/package.json`,
  `packages/ios-app/project.yml` and `scripts/tron`, not implementation helpers that
  an installed Gateway may outlive. Operation-specific build prerequisites remain
  checked by each builder. The device keeps its own source/target binding; no
  persisted configuration is merged or rewritten. Rejections name the path and
  missing/linked marker, and Mac replacement preserves that diagnosis rather than
  treating invalid configuration as absent. `source-repository.integration.test.ts`
  proves admission against the real checkout and filesystem plus the Gateway/Mac
  RPC error parity over a real socket.
- Source mode imports `buildSourcePayload` from the configured checkout's
  `scripts/gateway-payload-deploy.mjs` (so builder changes apply to that rebuild;
  `deploy.source-builder` records its SHA-256); the installed helper keeps locking,
  admission, selection, readiness and rollback. The compiler writes to a private
  `outDir`, staging is a `.source-staging-*` APFS clone (`cp -c -R`) under the channel
  root, sealed and renamed into `versions/` inside the store lock.
- The checkout's install must match its lock structurally (locked names and versions
  for this platform, no extras, no package symlinks; not a rehash). On drift the
  builder runs `npm ci` with the active payload's Node and npm, only when the lock
  equals the running payload's (#1010; `deploy.source-install-repair[ed]`); failure
  stops the rebuild with the command to run. `app/build-inputs.json` binds the exact
  build inputs, so a dirty build is never reused for a clean revision.
- Source updates reuse the selected payload's fingerprinted `node_modules` (byte-equal
  lock and declarations; never npm); dependency changes need a signed app or artifact.
  The delegated provider is the exception: its `pi-subagents-pin.json`, scripts and
  digest-verified artifacts are staged. Fingerprints cover sorted `app/**` and
  `runtime/**` in batches of 16 reads, identical to the Mac hash script and launcher.
  The capture addon belongs to the Mac app, not the payload.
- A planned restart publishes `draining` without a deadline; the startup deadline (60 s
  default, 2,000–300,000 ms override) starts when the exact old PID/start identity is
  gone. Readiness needs a new stable identity and an exact fingerprint/revision/epoch
  probe. launchd alone starts candidates (launcher attempt/commit marker); after the
  deadline the prior selection is restored and verified directly, never by RPC. A
  failed candidate's error leads with its `gateway.fatal-startup` or
  `launcher.candidate-rolled-back` record from the newest 256 KB of the logs.
  Diagnostics are one line ≤ 2 KiB. Timelines: `logs/deploy.jsonl`
  ([observability](../../docs/observability.md)).
- The old Gateway keeps its listener while draining; once released it has
  `DRAIN_EXIT_STALL_LIMIT_MS` (30 s) to exit, then the deploy re-reads its identity and
  SIGKILLs it (`deploy.old-process-stalled`). Staging keeps relative symlinks and
  cleanup never follows links. Clients get `system.stopping` and reconnect.
- Debug handoff copies only an authenticated Debug artifact whose version and
  fingerprint match the clean candidate `scripts/tron dev` admitted, into Stable as an
  inactive candidate; it never selects or restarts Stable and requires byte-equal Node
  and `runtime/`. Promotion pins version and fingerprint. Every payload fingerprints
  `app/PushService.xcconfig` (one exact HTTPS origin; Dev alone may be empty). A Stable
  source update whose predecessor is no longer admissible bootstraps only from the
  configured artifact, the signed bundled payload or the admitted checkout's bundle.
  Preflight loads every native module before publication.

## Mac replacement

`mac-replace.v1` (Stable). `scripts/tron_mac_replace.py`, its own launchd job, is the
only writer of `<tronHome>/../.tron-maintenance/replace/<operation>/`.
`mac.replace.status` projects the journal (≤ 512 KiB) and each stopped worker
(`resumable`, `resumed`, `stopping`, `unavailable`); `mac.replace.plan` returns
`quick`, `full` or `none` with the reason; `mac.replace.start` (receipt-backed) runs
only on the supervised Stable Gateway of this `~/.tron`; `mac.replace.complete`
pushes one notification per attempt; `mac.replace.resumeWorker` resumes a stopped
worker as a `.resume-N` successor once. If its one-use grant was consumed and no
standing scope covers the continuation, it waits for a fresh exact grant card in
Home through `HomeTaskDispatcher.authorizeTask` and the shared native broker.
No worker starts before that tap. Decline or the unanswered card's 24-hour expiry
runs nothing; an accepted new grant is consumed once for the same project/full-work
scope and the continuation's exact brief. The response receipt belongs to Home,
not the worker session being resumed.

## iPhone install and device labels

- `ios-device-install.v3`. Bind once from the Mac:
  `scripts/tron-ios-device-bind.mjs --list`, then `--device-id <paired-id>
  --target-identifier <CoreDevice id from xcrun devicectl list devices>` (`--channel
  dev` for 9848; `--host` only `tailscale` or `127.0.0.1`). `device.install.config`
  binds a device to a validated checkout; the local-only `device.install.target.bind`
  verifies the target is connected with Developer Mode (requesting device details
  first opens the CoreDevice tunnel). Bindings: `gateway/ios-device-installs/` (0600);
  physical identifiers never leave the Mac.
- `device.install` (`fast-debug` or `optimized`) runs one Mac-wide install through a
  detached bundled helper that revalidates and runs only `scripts/tron-ios-device
  install --device-id <bound target>` with the payload's XcodeGen; it holds the
  device's host-wide lease (exit 73 names another holder), never uninstalls, rejects
  Release, and relaunches the app. `device.install.status` is the reconnect-safe
  authority; a two-hour deadline; update, rollback and restart exclude an active
  install; revocation removes the mapping.
- `device-label.v1`: `device.label` sets a bounded label or `null`; names resolve
  custom label, then last observed name of the bound target, then pairing name, all on
  the pairing's identity lane; `devices.changed` invalidates reads.

## Drain and exit

- Remote restart needs `TRON_GATEWAY_SUPERVISED=1`. Restart exits 75 after the drain;
  supervised signals exit 75; an intentional stop exits 0 (the LaunchAgent's
  `KeepAlive.SuccessfulExit=false` relaunches everything else). The final exit
  `execve`s `/bin/sh -c 'exit <code>'` after Node's `exit` listeners, avoiding the
  libuv threadpool join that Darwin can wedge (libuv#5280, #1120); a non-zero exit is
  backed by a watcher that SIGKILLs the exact PID after `EXIT_STALL_GRACE_MS` (5 s,
  `gateway.exit-stalled`). A settled stop writes `gateway/stop-completed.json`
  (`{version:1,pid,drainId}`); Mac Quit waits five seconds after it and may boot out
  the exact job only after a proven post-completion stall.
- Shutdown closes runtime admission, drains entered creations, cancels unstarted
  queued work and drains every runtime before blob disposal; failed retirement stays
  retryable.
- `gateway.drain.status` returns `AdministrativeDrainSnapshot` (counts, ≤ 64 blocker
  summaries with category, state, age, progress and an `rpc-mutation`'s method;
  never IDs, prompts or paths). `gateway.restart` accepts `restartNow: true` to
  escalate; `gateway.stop` uses the same drain, exits only after a zero-blocker proof
  and records `failed` otherwise. The drain stalls after the oldest blocker makes no
  progress for 180 s (then exact cancellation and grace); only-suspect
  `terminal-receipt-persistence` blockers proceed at once. Records every 15 s:
  `gateway.restart-drain.waiting`.
- `GatewayWorkRegistry` is the bounded process-local drain authority (normal and
  derived-settlement capacity, never expiry by age). Preflight transfers one token into
  foreground, queue or command ownership; an orphaned foreground token is cleaned only
  when no exact owner represents it. Package and provider-login work stays until it
  settles. A paused extension artifact stops blocking only after an observed versioned
  `processTerminal` proof.

Verify: `exit-after-shutdown.e2e.test.ts`,
`administrative-drain-snapshot.integration.test.ts`,
`node --test scripts/gateway-payload-deploy.test.mjs`, signed `MacQuitGatewayTests`.
