// In-process probe for the multi-session scenario of scripts/tron-profile-gateway.
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
