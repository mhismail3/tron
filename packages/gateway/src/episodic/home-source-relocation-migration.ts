import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, lstat, mkdir, open, readFile, readdir, realpath, rename, rm, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { durableAtomicWriteJson, syncDurably } from "../foundation/durable-json.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EpisodicStore } from "./episodic-store.js";
import { fileURLToPath } from "node:url";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import { EPISODIC_DEFAULTS, type EpisodicStoreState } from "./episodic-contract.js";
import { readCanonicalHomeDeltas } from "./home-source.js";
import { relocateHomeSourceCursor, relocatedHomeCursor } from "./home-source-relocation.js";

type Ledger = { homeId: string; chapters: Array<{ sessionId: string; state: string; sizeAtSeal?: number }> };
type Receipt = { kind: string; before: string; after: string; source_sha256: string };
type LayoutJournal = { layouts: Record<string, { id: string; direction: string; rewrites: Record<string, Receipt> }> };
const digest = (data: Buffer) => createHash("sha256").update(data).digest("hex");

async function bounded(path: string, maxBytes: number): Promise<Buffer> {
  if (await realpath(path) !== resolve(path)) throw new Error("Relocation path contains a symlink");
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.uid !== process.getuid?.() || info.size > maxBytes) throw new Error("Unsafe relocation record");
    const data = await handle.readFile();
    if (data.length > maxBytes) throw new Error("Relocation record exceeds its bound");
    return data;
  } finally { await handle.close(); }
}

async function header(path: string): Promise<Buffer> {
  if (await realpath(path) !== resolve(path)) throw new Error("Relocation path contains a symlink");
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const buffer = Buffer.alloc(65_537);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    const end = buffer.subarray(0, bytesRead).indexOf(10);
    if (end < 0) throw new Error("Unbounded session header");
    return buffer.subarray(0, end + 1);
  } finally { await handle.close(); }
}

export async function planHomeSourceRelocation(home: string, journalPath: string, receiptRoot: string) {
  home = resolve(home);
  const ledgerPath = tronHomePath(home, "state/home/home.json");
  const ledgerBytes = await bounded(ledgerPath, 2_097_152);
  const ledger = JSON.parse(ledgerBytes.toString("utf8")) as Ledger;
  const journal = JSON.parse((await bounded(journalPath, 16_777_216)).toString("utf8")) as LayoutJournal;
  const layout = journal.layouts[home];
  if (!layout || layout.direction !== "applied" || !/^[a-f0-9]{32}$/u.test(layout.id)) throw new Error("No completed relocation receipt for this home");
  if (!/^[A-Za-z0-9._-]{1,160}$/u.test(ledger.homeId) || !Array.isArray(ledger.chapters)) throw new Error("Invalid Home ledger");
  const statePath = join(home, "workspace/state/episodic", ledger.homeId, "state.json");
  const stateBytes = await bounded(statePath, 16_777_216);
  const state = JSON.parse(stateBytes.toString("utf8")) as EpisodicStoreState;
  if (!state.cursor || state.cursor.home.version !== 2) throw new Error("No admitted Home cursor");
  const roots = Object.entries(layout.rewrites).filter(([, record]) => record.kind === "session");
  const backupRoot = resolve(receiptRoot);
  const chapters = [];
  const sources = [];
  const proofs = [];
  const changes: Array<{ sessionId: string; delta: number }> = [];
  for (const cursor of state.cursor.home.chapters) {
    const chapter = ledger.chapters[chapters.length];
    if (!chapter || chapter.sessionId !== cursor.sessionId || (chapter.state === "sealed") !== cursor.sealed) throw new Error("Home chapter ledger disagrees with its memory cursor");
    const matches = roots.filter(([path]) => path.endsWith(`_${cursor.sessionId}.jsonl`));
    if (matches.length !== 1) throw new Error(`No unique relocation receipt for chapter ${cursor.sessionId}`);
    const [path, receipt] = matches[0]!;
    if (!path.startsWith("agent/sessions/") || isAbsolute(path) || path.split("/").some(part => part === ".." || !part)) throw new Error("Invalid relocation receipt path");
    const source = join(home, path);
    const beforeStat = await lstat(source, { bigint: true });
    const originalHeader = await header(join(backupRoot, path));
    const currentHeader = await header(source);
    if (digest(originalHeader) !== receipt.before || digest(currentHeader) !== receipt.after) throw new Error("Session header disagrees with its relocation receipt");
    let next;
    try { next = await relocateHomeSourceCursor(source, currentHeader, cursor); }
    catch { next = await relocateHomeSourceCursor(source, originalHeader, cursor); }
    const delta = next.completeBytes - cursor.completeBytes;
    if (chapter.state === "sealed") chapter.sizeAtSeal = next.size;
    if (delta || next.completePrefixDigest !== cursor.completePrefixDigest) changes.push({ sessionId: cursor.sessionId, delta });
    const afterStat = await lstat(source, { bigint: true });
    const identity = (info: typeof afterStat) => [info.dev, info.ino, info.size, info.mtimeNs, info.ctimeNs].map(value => value.toString());
    if (JSON.stringify(identity(beforeStat)) !== JSON.stringify(identity(afterStat))) throw new Error("Source changed during relocation proof");
    proofs.push({ path: source, identity: identity(afterStat) });
    chapters.push(next);
    sources.push({ sessionId: cursor.sessionId, path: source, sealed: cursor.sealed });
  }
  const nextState = { ...state, cursor: relocatedHomeCursor(state.cursor, chapters) };
  if (nextState.blocked?.reason === "source-unavailable" && nextState.blocked.detail === "Sealed Home source changed since ingestion") nextState.blocked = null;
  for await (const _delta of readCanonicalHomeDeltas({ homeId: ledger.homeId, ledgerRevision: state.cursor.home.ledgerRevision, chapters: sources }, nextState.cursor, EPISODIC_DEFAULTS)) { void _delta; }
  return { home, journalPath: resolve(journalPath), ledgerPath, statePath, ledgerBytes, stateBytes, ledger, state: nextState, changes, proofs };
}

export async function applyHomeSourceRelocation(plan: Awaited<ReturnType<typeof planHomeSourceRelocation>>, backup: string, leaseOwnerPid: number): Promise<void> {
  const assertLeaseOwner = () => {
    if (!Number.isSafeInteger(leaseOwnerPid) || leaseOwnerPid <= 1 || process.ppid !== leaseOwnerPid) throw new Error("Offline repair lease owner was lost");
  };
  assertLeaseOwner();
  const fileSystem = { mkdir, open, rm, lstat, readdir, writeFile, syncDurably,
    rename: (async (from, to) => { assertLeaseOwner(); await rename(from, to); }) as typeof rename };
  backup = resolve(backup);
  const workspace = new TronWorkspace(plan.home);
  await workspace.initialize();
  try {
    if (!(await workspace.describe()).available) throw new Error("Workspace is unavailable or still owned by the Gateway; stop Tron before applying");
    const store = new EpisodicStore(workspace, plan.ledger.homeId, EPISODIC_DEFAULTS.maxStoreLineBytes, fileSystem);
    const current = await store.readState();
    if (JSON.stringify(current) !== JSON.stringify(JSON.parse(plan.stateBytes.toString("utf8")))) throw new Error("Memory changed during relocation proof");
    if (!(await bounded(plan.ledgerPath, 2_097_152)).equals(plan.ledgerBytes)) throw new Error("Home ledger changed during relocation proof");
    assertLeaseOwner();
    await mkdir(backup, { mode: 0o700 });
    for (const [path, bytes] of [[plan.statePath, plan.stateBytes], [plan.ledgerPath, plan.ledgerBytes]] as const) {
      const destination = join(backup, relative(plan.home, path));
      await mkdir(dirname(destination), { recursive: true, mode: 0o700 });
      await copyFile(path, destination, constants.COPYFILE_EXCL);
      const handle = await open(destination, "r");
      try { await syncDurably(handle); } finally { await handle.close(); }
      if (!(await readFile(destination)).equals(bytes)) throw new Error("Relocation backup changed");
      for (let parent = dirname(destination); parent !== dirname(backup); parent = dirname(parent)) {
        const directory = await open(parent, "r");
        try { await syncDurably(directory); } finally { await directory.close(); }
      }
    }
    const manifest = { version: 1, home: plan.home, files: [plan.statePath, plan.ledgerPath].map((path, index) => ({ path: relative(plan.home, path), before: digest(index === 0 ? plan.stateBytes : plan.ledgerBytes) })), changes: plan.changes };
    await writeFile(join(backup, "manifest.json"), `${JSON.stringify(manifest)}\n`, { mode: 0o600, flag: "wx" });
    const directory = await open(backup, "r");
    try { await syncDurably(directory); } finally { await directory.close(); }
    const manifestHandle = await open(join(backup, "manifest.json"), "r");
    try { await syncDurably(manifestHandle); } finally { await manifestHandle.close(); }
    const parent = await open(dirname(backup), "r");
    try { await syncDurably(parent); } finally { await parent.close(); }
    for (const proof of plan.proofs) {
      const info = await lstat(proof.path, { bigint: true });
      const identity = [info.dev, info.ino, info.size, info.mtimeNs, info.ctimeNs].map(value => value.toString());
      if (JSON.stringify(identity) !== JSON.stringify(proof.identity)) throw new Error("Source changed since relocation proof");
    }
    await store.saveState(plan.state);
    await durableAtomicWriteJson(plan.ledgerPath, plan.ledger, 0o600, fileSystem);
  } finally { await workspace.dispose(); }
}

async function main() {
  const args = process.argv.slice(2);
  const value = (flag: string) => { const index = args.indexOf(flag); if (index < 0 || !args[index + 1]) throw new Error(`Missing ${flag}`); return resolve(args[index + 1]!); };
  if (args.includes("--apply")) throw new Error("Apply only through scripts/tron home-layout repair-memory so the offline leases are held");
  const plan = await planHomeSourceRelocation(value("--home"), value("--journal"), value("--receipt-root"));
  process.stdout.write(`${JSON.stringify({ chapters: plan.changes.length, deltas: plan.changes.map(item => item.delta), blocked: plan.state.blocked, applied: false })}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { process.stderr.write(`${(error as Error).message}\n`); process.exitCode = 1; });
}
