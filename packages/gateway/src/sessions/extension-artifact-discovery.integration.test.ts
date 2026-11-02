import { createHook } from "node:async_hooks";
import { mkdir, mkdtemp, realpath, rename, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  ExtensionArtifactDiscovery,
  type ExtensionArtifactDiscoveryOutcome,
  type ExtensionArtifactRootWatchRequest,
} from "./extension-artifact-discovery.js";

/** Real artifact trees under a private temp root; the discovery owner is the
 * shipped class with its production watcher unless a case must make the
 * watcher drop events or fail. The slot is the structural consumer discovery
 * offers to: it records offers and attributes the runs a case names. */

const cleanups: Array<() => Promise<void> | void> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

async function artifactTree(label: string): Promise<{ delegatedRoot: string; runsRoot: string }> {
  const root = await realpath(await mkdtemp(join(tmpdir(), `tron-artifact-discovery-${label}-`)));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const delegatedRoot = join(root, "delegated");
  const runsRoot = join(delegatedRoot, "async-subagent-runs");
  await mkdir(runsRoot, { recursive: true });
  return { delegatedRoot, runsRoot };
}

function runName(index: number): string {
  return `run-${String(index).padStart(5, "0")}`;
}

function statusBytes(runId: string, state: string, lastUpdate: number): string {
  const startedAt = lastUpdate - 1_000;
  return JSON.stringify({
    lifecycleArtifactVersion: 3, runId, state, startedAt, lastUpdate,
    ...(state === "running" ? {} : { endedAt: lastUpdate }),
  });
}

/** Writes status.json the way the provider does: a sibling temp file renamed
 * over the artifact. */
async function writeStatus(runsRoot: string, runId: string, state: string, lastUpdate: number): Promise<void> {
  const directory = join(runsRoot, runId);
  await mkdir(directory, { recursive: true });
  const temporary = join(directory, `status.json.${process.pid}.tmp`);
  await writeFile(temporary, statusBytes(runId, state, lastUpdate));
  await rename(temporary, join(directory, "status.json"));
}

/** `count` terminal run directories, written in bounded batches. */
async function terminalRuns(runsRoot: string, count: number, lastUpdate: number): Promise<string[]> {
  const names = Array.from({ length: count }, (_unused, index) => runName(index));
  for (let start = 0; start < names.length; start += 256) {
    await Promise.all(names.slice(start, start + 256).map((name) => writeStatus(runsRoot, name, "complete", lastUpdate)));
  }
  return names;
}

function recordingSlot(attributed: Set<string>, outcome: ExtensionArtifactDiscoveryOutcome = "accepted") {
  const offers: string[] = [];
  const slot = {
    id: "slot-1",
    cwd: tmpdir(),
    ownedTurns: {
      ownedExtensionArtifactDirectories: () => [],
      discoverExtensionArtifact: async (asyncDir: string): Promise<ExtensionArtifactDiscoveryOutcome> => {
        offers.push(asyncDir);
        return outcome;
      },
      extensionAmbientArtifactAttribution: () => attributed,
    },
  };
  return { slot, offers, slots: new Map([[slot.id, slot]]) };
}

function discovery(
  slots: ReadonlyMap<string, ReturnType<typeof recordingSlot>["slot"]>,
  options: ConstructorParameters<typeof ExtensionArtifactDiscovery>[1],
): ExtensionArtifactDiscovery {
  const owner = new ExtensionArtifactDiscovery(slots, options);
  cleanups.push(() => owner.close());
  return owner;
}

/** libuv filesystem requests this process issued while `work` ran: every
 * fs.promises call, Dir read and FileHandle close is one threadpool request. */
async function countFilesystemRequests(work: () => Promise<unknown>): Promise<number> {
  let requests = 0;
  const hook = createHook({
    init(_id, type) {
      if (type === "FSREQPROMISE" || type === "FSREQCALLBACK" || type === "FILEHANDLECLOSEREQ") requests += 1;
    },
  });
  hook.enable();
  try {
    await work();
  } finally {
    hook.disable();
  }
  return requests;
}

async function passesUntil(owner: ExtensionArtifactDiscovery, settled: () => boolean, label: string, limit = 200): Promise<number> {
  for (let passes = 1; passes <= limit; passes += 1) {
    await owner.runPass();
    if (settled()) return passes;
    // Watcher events arrive on the event loop between passes, as between the
    // registry's 750 ms ticks.
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`${label}: not settled within ${limit} passes`);
}

/** A watcher backend that stays attached but delivers nothing, as when the
 * platform drops events; `reset` fails it as an error would. */
function silentWatcher() {
  const requests: ExtensionArtifactRootWatchRequest[] = [];
  let closed = 0;
  return {
    requests,
    closed: () => closed,
    watchArtifactRoot: (request: ExtensionArtifactRootWatchRequest) => {
      requests.push(request);
      return { close: () => { closed += 1; } };
    },
  };
}

describe("ambient extension artifact discovery change detection", () => {
  it("spends no per-directory filesystem work on a pass over an unchanged tree", async () => {
    const { delegatedRoot, runsRoot } = await artifactTree("unchanged");
    const count = 1_500;
    await terminalRuns(runsRoot, count, Date.now() - 60_000);
    const { slots } = recordingSlot(new Set());
    const owner = discovery(slots, { delegatedArtifactRoot: delegatedRoot });
    // The startup sweep stats every directory once and reads every artifact;
    // the per-pass read budget (1,024) spreads the reads over two passes.
    const startup = await countFilesystemRequests(async () => {
      expect(await owner.runPass()).toMatchObject({ entries: 1_025, statusReads: 1_024 });
      expect(await owner.runPass()).toBeUndefined();
    });
    expect(startup).toBeGreaterThanOrEqual(count);
    // Later passes over the same tree: only the root itself is checked. The
    // previous design re-statted every status.json on each pass (≥ 1,500 here).
    const steady: number[] = [];
    for (let pass = 0; pass < 5; pass += 1) steady.push(await countFilesystemRequests(() => owner.runPass()));
    expect(Math.max(...steady), `requests per unchanged pass: ${steady.join(", ")}`).toBeLessThanOrEqual(4);
  });

  it("picks up a changed and a new status.json with the production watcher", async () => {
    const { delegatedRoot, runsRoot } = await artifactTree("changed");
    const names = await terminalRuns(runsRoot, 50, Date.now() - 60_000);
    const changed = names[17]!;
    const attributed = new Set([changed, "run-new"]);
    const { slots, offers } = recordingSlot(attributed);
    const owner = discovery(slots, { delegatedArtifactRoot: delegatedRoot });
    await passesUntil(owner, () => offers.includes(join(runsRoot, changed)), "first offer of the terminal run");
    offers.length = 0;

    // A terminal artifact rewritten in place of its old bytes is only visible
    // through the watcher (its directory is not re-statted on every pass).
    await writeStatus(runsRoot, changed, "failed", Date.now());
    await passesUntil(owner, () => offers.includes(join(runsRoot, changed)), "rewritten terminal run");
    // A new run directory changes the root's own listing, so it is seen on the
    // very next pass without any event.
    await writeStatus(runsRoot, "run-new", "running", Date.now());
    const passes = await passesUntil(owner, () => offers.includes(join(runsRoot, "run-new")), "new run");
    expect(passes).toBe(1);
  });

  it("finds a same-size in-place rewrite that kept mtime, with or without its watcher event", async () => {
    const pinned = new Date(1_700_000_000_000);
    const completedAt = 1_700_000_000_000 - 5_000;
    /** Rewrites the target in its own inode with the same length and a pinned
     * whole-second mtime, so dev, ino, size and mtimeMs are all unchanged. */
    const rewriteInPlace = async (file: string, runId: string) => {
      const before = await stat(file);
      const rewritten = statusBytes(runId, "complete", completedAt + 1_000);
      expect(rewritten.length).toBe(statusBytes(runId, "complete", completedAt).length);
      await writeFile(file, rewritten);
      await utimes(file, pinned, pinned);
      const after = await stat(file);
      expect([after.dev, after.ino, after.size, after.mtimeMs]).toEqual([before.dev, before.ino, before.size, before.mtimeMs]);
    };
    const seed = async (runsRoot: string, runId: string) => {
      const file = join(runsRoot, runId, "status.json");
      await writeFile(file, statusBytes(runId, "complete", completedAt));
      await utimes(file, pinned, pinned);
      return file;
    };

    // Production watcher: the event names the file.
    const watched = await artifactTree("in-place");
    const target = (await terminalRuns(watched.runsRoot, 10, Date.now() - 60_000))[4]!;
    const file = await seed(watched.runsRoot, target);
    const live = recordingSlot(new Set([target]));
    const owner = discovery(live.slots, { delegatedArtifactRoot: watched.delegatedRoot });
    await passesUntil(owner, () => live.offers.includes(join(watched.runsRoot, target)), "first offer");
    live.offers.length = 0;
    await rewriteInPlace(file, target);
    await passesUntil(owner, () => live.offers.includes(join(watched.runsRoot, target)), "watched in-place rewrite");

    // The event is dropped: the backstop sweep's stat still sees the write.
    const dropped = await artifactTree("in-place-dropped");
    await terminalRuns(dropped.runsRoot, 10, Date.now() - 60_000);
    const droppedFile = await seed(dropped.runsRoot, target);
    const backend = silentWatcher();
    const silent = recordingSlot(new Set([target]));
    const swept = discovery(silent.slots, {
      delegatedArtifactRoot: dropped.delegatedRoot, watchArtifactRoot: backend.watchArtifactRoot, fullSweepMs: 200,
    });
    await swept.runPass();
    expect(silent.offers).toHaveLength(1);
    await rewriteInPlace(droppedFile, target);
    await swept.runPass();
    expect(silent.offers).toHaveLength(1);
    await new Promise((resolve) => setTimeout(resolve, 250));
    await swept.runPass();
    expect(silent.offers).toEqual([join(dropped.runsRoot, target), join(dropped.runsRoot, target)]);
  });

  it("re-reads an active artifact on every pass without a watcher event", async () => {
    const { delegatedRoot, runsRoot } = await artifactTree("active");
    await terminalRuns(runsRoot, 20, Date.now() - 60_000);
    await writeStatus(runsRoot, "run-live", "running", Date.now() - 5_000);
    const backend = silentWatcher();
    const { slots, offers } = recordingSlot(new Set(["run-live"]));
    const owner = discovery(slots, { delegatedArtifactRoot: delegatedRoot, watchArtifactRoot: backend.watchArtifactRoot });
    await owner.runPass();
    expect(offers).toEqual([join(runsRoot, "run-live")]);
    await writeStatus(runsRoot, "run-live", "complete", Date.now());
    await owner.runPass();
    expect(offers).toEqual([join(runsRoot, "run-live"), join(runsRoot, "run-live")]);
  });

  it("re-reads an attributed artifact its slot rejected on every pass without a watcher event", async () => {
    // A recovered slot rejects a foreign producer's terminal header; the owning
    // producer then rewrites the file. The slot must see the rewrite on the next
    // pass, as when every directory was stat'd every pass.
    const { delegatedRoot, runsRoot } = await artifactTree("rejected");
    await terminalRuns(runsRoot, 20, Date.now() - 60_000);
    await writeStatus(runsRoot, "run-foreign", "complete", Date.now() - 5_000);
    const backend = silentWatcher();
    const { slots, offers } = recordingSlot(new Set(["run-foreign"]), "rejected");
    const owner = discovery(slots, { delegatedArtifactRoot: delegatedRoot, watchArtifactRoot: backend.watchArtifactRoot });
    await owner.runPass();
    expect(offers).toEqual([join(runsRoot, "run-foreign")]);
    // The same bytes are not offered again...
    await owner.runPass();
    expect(offers).toHaveLength(1);
    // ...but a rewrite is, on the very next pass.
    await writeStatus(runsRoot, "run-foreign", "running", Date.now());
    await owner.runPass();
    expect(offers).toEqual([join(runsRoot, "run-foreign"), join(runsRoot, "run-foreign")]);
  });

  it("bounds the every-pass retry of rejected attributed runs to each slot's newest 64", async () => {
    // A long session attributes every run in its history; permanently rejected
    // ones must not bring back a per-pass stat of the whole history.
    const { delegatedRoot, runsRoot } = await artifactTree("rejected-history");
    const base = Date.now() - 600_000;
    const names = Array.from({ length: 300 }, (_unused, index) => runName(index));
    for (let start = 0; start < names.length; start += 100) {
      await Promise.all(names.slice(start, start + 100).map((name, offset) => writeStatus(runsRoot, name, "complete", base + (start + offset) * 1_000)));
    }
    const backend = silentWatcher();
    const { slots, offers } = recordingSlot(new Set(names), "rejected");
    const owner = discovery(slots, { delegatedArtifactRoot: delegatedRoot, watchArtifactRoot: backend.watchArtifactRoot });
    await passesUntil(owner, () => new Set(offers).size === names.length, "every run offered once", 4);
    // Root stat plus one status.json stat per retried run, and nothing more.
    const steady = await countFilesystemRequests(() => owner.runPass());
    expect(steady).toBeGreaterThanOrEqual(64);
    expect(steady).toBeLessThanOrEqual(64 + 4);
    // The newest rejected run is still retried on the next pass.
    offers.length = 0;
    await writeStatus(runsRoot, names.at(-1)!, "running", Date.now());
    await owner.runPass();
    expect(offers).toEqual([join(runsRoot, names.at(-1)!)]);
  });

  it("falls back to a full sweep when the watcher fails or cannot start", async () => {
    const { delegatedRoot, runsRoot } = await artifactTree("fallback");
    const names = await terminalRuns(runsRoot, 40, Date.now() - 60_000);
    const target = names[31]!;
    const backend = silentWatcher();
    const { slots, offers } = recordingSlot(new Set([target]));
    const owner = discovery(slots, { delegatedArtifactRoot: delegatedRoot, watchArtifactRoot: backend.watchArtifactRoot });
    await owner.runPass();
    expect(offers).toEqual([join(runsRoot, target)]);

    // The watcher drops this change, so the cold artifact is not re-read...
    await writeStatus(runsRoot, target, "failed", Date.now());
    await owner.runPass();
    await owner.runPass();
    expect(offers).toHaveLength(1);
    // ...until the watcher reports an error: the next pass sweeps the root.
    backend.requests[0]!.onReset();
    expect(backend.closed()).toBe(1);
    await owner.runPass();
    expect(offers).toEqual([join(runsRoot, target), join(runsRoot, target)]);

    // A root whose watcher cannot start at all is polled by sweeps.
    const failing = await artifactTree("fallback-unwatchable");
    await terminalRuns(failing.runsRoot, 40, Date.now() - 60_000);
    const unwatched = recordingSlot(new Set([target]));
    let attempts = 0;
    const polled = discovery(unwatched.slots, {
      delegatedArtifactRoot: failing.delegatedRoot,
      watchArtifactRoot: () => { attempts += 1; throw new Error("EMFILE: too many open files, watch"); },
    });
    await polled.runPass();
    expect(attempts).toBe(1);
    expect(unwatched.offers).toEqual([join(failing.runsRoot, target)]);
    await writeStatus(failing.runsRoot, target, "failed", Date.now());
    await polled.runPass();
    expect(unwatched.offers).toEqual([join(failing.runsRoot, target), join(failing.runsRoot, target)]);
  });

  it("repairs a dropped event with the periodic full sweep", async () => {
    const { delegatedRoot, runsRoot } = await artifactTree("backstop");
    const names = await terminalRuns(runsRoot, 30, Date.now() - 60_000);
    const target = names[9]!;
    const backend = silentWatcher();
    const { slots, offers } = recordingSlot(new Set([target]));
    const owner = discovery(slots, {
      delegatedArtifactRoot: delegatedRoot, watchArtifactRoot: backend.watchArtifactRoot, fullSweepMs: 200,
    });
    await owner.runPass();
    await writeStatus(runsRoot, target, "failed", Date.now());
    await owner.runPass();
    expect(offers).toHaveLength(1);
    await new Promise((resolve) => setTimeout(resolve, 250));
    await owner.runPass();
    expect(offers).toHaveLength(2);
  });

  it("discovers every artifact in a root with more than 4,096 entries", async () => {
    const { delegatedRoot, runsRoot } = await artifactTree("over-cap");
    const count = 4_400;
    const names = await terminalRuns(runsRoot, count, Date.now() - 60_000);
    // Every run is attributed, so each must be offered once: the routing budget
    // spreads them over passes, and none may sit past an enumeration cap.
    const { slots, offers } = recordingSlot(new Set(names));
    const owner = discovery(slots, { delegatedArtifactRoot: delegatedRoot });
    await passesUntil(owner, () => new Set(offers).size === count, "every run offered", 12);
    expect(new Set(offers)).toEqual(new Set(names.map((name) => join(runsRoot, name))));
  }, 60_000);
});
