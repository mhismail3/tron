// In-process probe for the multi-session scenario of scripts/tron-profile-gateway.
//
//   node --import scripts/tron-profile-gateway-probe.mjs packages/gateway/dist/index.js
//
// Loaded only into a fixture Gateway: it refuses to load unless its output
// file sits in a directory carrying the profiler's fixture marker. It measures
// what cannot be observed from outside the process until the Gateway's own
// request spans (plan task O-3) and resource sampler (O-5) exist; delete or
// reduce it once they report the same numbers.
//
// - Catalog walks: RuntimeRegistry's catalog structure walk
//   (CatalogDiscovery.catalogStructureEvidence) starts with `opendir` from
//   `node:fs/promises` on the catalog root; every such call is one walk.
// - Event-loop delay: `monitorEventLoopDelay` at 10 ms resolution.
// - Heap and RSS: sampled once per second (and at every snapshot); peaks.
//
// On SIGUSR2 the probe atomically writes one snapshot (cumulative walks, peaks
// and event-loop percentiles since the previous snapshot) and starts a new
// interval. It writes nothing else and logs nothing, so its cost is a 10 ms
// timer, a 1 s timer and one small file per window edge.

import { existsSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { dirname, join, resolve } from "node:path";
import { monitorEventLoopDelay } from "node:perf_hooks";
import { getHeapStatistics } from "node:v8";

const FIXTURE_MARKER = ".tron-profile-gateway-fixture";
const RESOLUTION_MS = 10;
const SAMPLE_INTERVAL_MS = 1_000;

const output = process.env.TRON_PROFILE_PROBE_OUTPUT;
const catalog = process.env.TRON_PROFILE_PROBE_CATALOG;
if (!output || !catalog || !existsSync(join(dirname(resolve(output)), FIXTURE_MARKER))) {
  throw new Error("tron-profile-gateway-probe loads only into a tron-profile fixture Gateway");
}
const catalogRoots = new Set([resolve(catalog), realpathSync(catalog)]);

const promises = createRequire(import.meta.url)("node:fs/promises");
const opendir = promises.opendir;
let catalogWalks = 0;
promises.opendir = function countedOpendir(path, ...rest) {
  if (catalogRoots.has(resolve(String(path)))) catalogWalks += 1;
  return opendir.call(this, path, ...rest);
};
// ES module importers (the Gateway's catalog discovery) see the wrapper too.
syncBuiltinESMExports();

const delay = monitorEventLoopDelay({ resolution: RESOLUTION_MS });
delay.enable();
let sequence = 0;
let heapPeak = 0;
let rssPeak = 0;

function sample() {
  const heap = getHeapStatistics();
  const rss = process.memoryUsage.rss();
  heapPeak = Math.max(heapPeak, heap.used_heap_size);
  rssPeak = Math.max(rssPeak, rss);
  return { heap, rss };
}
setInterval(sample, SAMPLE_INTERVAL_MS).unref();

/** Histogram values include the timer resolution; report only the lateness. */
const lateness = (nanoseconds) => Math.max(0, nanoseconds / 1e6 - RESOLUTION_MS);

process.on("SIGUSR2", () => {
  const { heap, rss } = sample();
  sequence += 1;
  const snapshot = {
    schema: "tron.profile-gateway-probe.v1",
    sequence,
    catalogWalks,
    eventLoopDelay: {
      samples: delay.count,
      p50Ms: delay.count ? lateness(delay.percentile(50)) : 0,
      p99Ms: delay.count ? lateness(delay.percentile(99)) : 0,
      maxMs: delay.count ? lateness(delay.max) : 0,
    },
    heapUsedPeakBytes: heapPeak,
    heapLimitBytes: heap.heap_size_limit,
    rssPeakBytes: rssPeak,
  };
  delay.reset();
  heapPeak = heap.used_heap_size;
  rssPeak = rss;
  writeFileSync(`${output}.tmp`, `${JSON.stringify(snapshot)}\n`);
  renameSync(`${output}.tmp`, output);
});
