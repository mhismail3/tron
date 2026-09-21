import { mkdtemp, rm } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SessionSearchAllowanceLedger } from "./session-search-allowance.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const day = "2026-09-20";
const requestID = "request_1234567890123456";

describe("SessionSearchAllowanceLedger", () => {
  it("is durable, quota bounded, and idempotent", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-jev-")); roots.push(root);
    const path = join(root, "allowance.sqlite");
    const ledger = await SessionSearchAllowanceLedger.open(path);
    expect(ledger.readPolicy().enabled).toBe(false);
    ledger.writePolicy({ enabled: true, perQueryMicroCents: 200, dailyMicroCents: 200, policyRevision: 2 });
    expect(ledger.readPolicy().policyRevision).toBe(2);
    ledger.writePolicy({ enabled: false, perQueryMicroCents: 200, dailyMicroCents: 200, policyRevision: 2 });
    const reenabled = ledger.writePolicy({ enabled: true, perQueryMicroCents: 200, dailyMicroCents: 200, policyRevision: 2 });
    expect(reenabled.policyRevision).toBe(4);
    expect(ledger.reserve("request_0234567890123456", day, 100, 200, 1)).toBeUndefined();
    expect(ledger.reserve(requestID, day, 100, 200, 4)?.reservedMicroCents).toBe(100);
    expect(ledger.reserve("request_2234567890123456", day, 101, 200, 4)).toBeUndefined();
    ledger.close();
    const reopened = await SessionSearchAllowanceLedger.open(path);
    expect(reopened.readPolicy().enabled).toBe(true);
    expect(reopened.reserve(requestID, day, 100, 200, 4)?.requestID).toBe(requestID);
    reopened.settle(requestID, 40);
    reopened.settle(requestID, 100); // duplicate settlement cannot double count.
    expect(reopened.reserve("request_3234567890123456", day, 161, 200, 4)).toBeUndefined();
    reopened.close();
  });

  it("preserves an existing ledger and rejects missing authority tables", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-jev-")); roots.push(root);
    const path = join(root, "allowance.sqlite");
    const ledger = await SessionSearchAllowanceLedger.open(path); ledger.close();
    const database = new DatabaseSync(path);
    database.exec("DROP TABLE jev_usage"); database.close();
    await expect(SessionSearchAllowanceLedger.open(path)).rejects.toThrow(/missing jev_usage/iu);
    const preserved = new DatabaseSync(path);
    expect((preserved.prepare("SELECT count(*) AS n FROM jev_policy").get() as { n: number }).n).toBe(1);
    preserved.close();
  });

  it("rejects malformed dates and fails closed for corrupted state", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-jev-")); roots.push(root);
    const path = join(root, "allowance.sqlite");
    const ledger = await SessionSearchAllowanceLedger.open(path);
    expect(ledger.reserve(requestID, "20260920", 1, 10, 2)).toBeUndefined();
    ledger.close();
    await import("node:fs/promises").then(fs => fs.writeFile(path, Buffer.from("not sqlite")));
    await expect(SessionSearchAllowanceLedger.open(path)).rejects.toThrow();
  });
});
