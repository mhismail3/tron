import { DatabaseSync } from "node:sqlite";
import { chmod, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname } from "node:path";
import type { SessionSearchPolicy } from "./session-search-contract.js";

interface JevReservation { requestID: string; day: string; reservedMicroCents: number; }

/** Durable spending authority. This file is intentionally separate from the
 * disposable lexical index: corruption fails closed rather than rebuilding a
 * ledger and potentially authorizing duplicate provider spend. */
export class SessionSearchAllowanceLedger {
  private readonly database: DatabaseSync;
  private closed = false;

  private constructor(private readonly path: string, create: boolean) {
    this.database = new DatabaseSync(path, { allowExtension: false, enableForeignKeyConstraints: true });
    this.database.exec("PRAGMA trusted_schema = OFF; PRAGMA busy_timeout = 1000; PRAGMA journal_mode = DELETE; PRAGMA synchronous = EXTRA; PRAGMA secure_delete = ON;");
    if (!create) return;
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS schema_meta (id INTEGER PRIMARY KEY CHECK(id = 1), version INTEGER NOT NULL CHECK(version = 1));
      CREATE TABLE IF NOT EXISTS jev_reservations (
        request_id TEXT PRIMARY KEY,
        usage_day TEXT NOT NULL,
        reserved_micro_cents INTEGER NOT NULL CHECK(reserved_micro_cents > 0),
        actual_micro_cents INTEGER,
        state TEXT NOT NULL CHECK(state IN ('pending','settled')),
        created_at INTEGER NOT NULL
      ) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS jev_policy (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
        per_query_micro_cents INTEGER NOT NULL CHECK(per_query_micro_cents >= 0),
        daily_micro_cents INTEGER NOT NULL CHECK(daily_micro_cents >= 0),
        policy_revision INTEGER NOT NULL CHECK(policy_revision >= 1)
      );
      CREATE TABLE IF NOT EXISTS jev_usage (
        usage_day TEXT PRIMARY KEY,
        committed_micro_cents INTEGER NOT NULL CHECK(committed_micro_cents >= 0)
      ) WITHOUT ROWID;
      INSERT INTO schema_meta(id, version) VALUES(1, 1) ON CONFLICT(id) DO NOTHING;
      INSERT INTO jev_policy(id, enabled, per_query_micro_cents, daily_micro_cents, policy_revision) VALUES(1, 0, 0, 0, 1) ON CONFLICT(id) DO NOTHING;
    `);
  }

  static async open(path: string): Promise<SessionSearchAllowanceLedger> {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    const create = !existsSync(path);
    let ledger: SessionSearchAllowanceLedger | undefined;
    try {
      ledger = new SessionSearchAllowanceLedger(path, create);
      const integrity = ledger.database.prepare("PRAGMA integrity_check").get() as { integrity_check?: string } | undefined;
      if (integrity?.integrity_check !== "ok") throw new Error("Session search Jev allowance ledger integrity check failed");
      const tables = new Set((ledger.database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as Array<{ name: string }>).map(row => row.name));
      for (const required of ["schema_meta", "jev_policy", "jev_usage", "jev_reservations"]) if (!tables.has(required)) throw new Error(`Session search Jev allowance ledger is missing ${required}`);
      const version = ledger.database.prepare("SELECT version FROM schema_meta WHERE id = 1").get() as { version?: number } | undefined;
      if (version?.version !== 1) throw new Error("Session search Jev allowance schema is unsupported");
      ledger.readPolicy();
      await chmod(path, 0o600);
      return ledger;
    } catch (error) {
      ledger?.close();
      throw error;
    }
  }

  readPolicy(): SessionSearchPolicy {
    this.assertOpen();
    const row = this.database.prepare("SELECT enabled, per_query_micro_cents, daily_micro_cents, policy_revision FROM jev_policy WHERE id = 1").get() as { enabled: number; per_query_micro_cents: number; daily_micro_cents: number; policy_revision: number };
    const perQueryMicroCents = Number(row.per_query_micro_cents);
    const dailyMicroCents = Number(row.daily_micro_cents);
    const policyRevision = Number(row.policy_revision);
    if (![perQueryMicroCents, dailyMicroCents, policyRevision].every(Number.isSafeInteger)) throw new Error("Session search Jev policy ledger values are invalid");
    return { enabled: row.enabled === 1, perQueryMicroCents, dailyMicroCents, policyRevision };
  }

  writePolicy(policy: SessionSearchPolicy): SessionSearchPolicy {
    this.assertOpen();
    const current = this.readPolicy();
    const revision = current.policyRevision + 1;
    const next = { ...policy, policyRevision: revision };
    this.database.prepare("UPDATE jev_policy SET enabled = ?, per_query_micro_cents = ?, daily_micro_cents = ?, policy_revision = ? WHERE id = 1").run(next.enabled ? 1 : 0, next.perQueryMicroCents, next.dailyMicroCents, next.policyRevision);
    return next;
  }

  reserve(requestID: string, day: string, amountMicroCents: number, dailyLimitMicroCents: number, expectedPolicyRevision: number): JevReservation | undefined {
    this.assertOpen();
    if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/u.test(day) || !/^[A-Za-z0-9_-]{16,128}$/u.test(requestID)
      || !Number.isSafeInteger(expectedPolicyRevision)
      || !Number.isSafeInteger(amountMicroCents) || amountMicroCents <= 0
      || !Number.isSafeInteger(dailyLimitMicroCents) || dailyLimitMicroCents < amountMicroCents) return undefined;
    this.database.exec("BEGIN IMMEDIATE");
    try {
      const existing = this.database.prepare("SELECT usage_day, reserved_micro_cents, state FROM jev_reservations WHERE request_id = ?").get(requestID) as { usage_day: string; reserved_micro_cents: number; state: string } | undefined;
      const currentPolicy = this.database.prepare("SELECT enabled, per_query_micro_cents, daily_micro_cents, policy_revision FROM jev_policy WHERE id = 1").get() as { enabled: number; per_query_micro_cents: number; daily_micro_cents: number; policy_revision: number } | undefined;
      if (!currentPolicy || currentPolicy.enabled !== 1 || currentPolicy.policy_revision !== expectedPolicyRevision || currentPolicy.per_query_micro_cents < amountMicroCents || currentPolicy.daily_micro_cents !== dailyLimitMicroCents) { this.database.exec("ROLLBACK"); return undefined; }
      if (existing) {
        const matches = existing.state === "pending" && existing.usage_day === day && Number(existing.reserved_micro_cents) === amountMicroCents;
        this.database.exec("COMMIT");
        return matches ? { requestID, day: existing.usage_day, reservedMicroCents: Number(existing.reserved_micro_cents) } : undefined;
      }
      // Retain only a bounded audit window while preserving every pending hold.
      this.database.prepare("DELETE FROM jev_reservations WHERE state = 'settled' AND created_at < ?").run(Date.now() - 35 * 24 * 60 * 60 * 1000);
      const pendingCount = Number((this.database.prepare("SELECT count(*) AS n FROM jev_reservations WHERE state = 'pending'").get() as { n: number }).n);
      if (pendingCount >= 1_024) { this.database.exec("ROLLBACK"); return undefined; }
      this.database.prepare("DELETE FROM jev_usage WHERE usage_day < ? AND NOT EXISTS (SELECT 1 FROM jev_reservations WHERE jev_reservations.usage_day = jev_usage.usage_day AND state = 'pending')").run(day);
      const committed = Number((this.database.prepare("SELECT committed_micro_cents AS n FROM jev_usage WHERE usage_day = ?").get(day) as { n?: number } | undefined)?.n ?? 0);
      const pending = Number((this.database.prepare("SELECT coalesce(sum(reserved_micro_cents),0) AS n FROM jev_reservations WHERE usage_day = ? AND state = 'pending'").get(day) as { n?: number }).n ?? 0);
      if (committed + pending + amountMicroCents > dailyLimitMicroCents) { this.database.exec("ROLLBACK"); return undefined; }
      this.database.prepare("INSERT INTO jev_reservations(request_id,usage_day,reserved_micro_cents,actual_micro_cents,state,created_at) VALUES(?,?,?,?,?,?)").run(requestID, day, amountMicroCents, null, "pending", Date.now());
      this.database.exec("COMMIT");
      return { requestID, day, reservedMicroCents: amountMicroCents };
    } catch (error) { try { this.database.exec("ROLLBACK"); } catch {} throw error; }
  }

  settle(requestID: string, actualMicroCents: number): void {
    this.assertOpen();
    if (!/^[A-Za-z0-9_-]{16,128}$/u.test(requestID) || !Number.isSafeInteger(actualMicroCents) || actualMicroCents < 0) return;
    this.database.exec("BEGIN IMMEDIATE");
    try {
      const row = this.database.prepare("SELECT usage_day, state FROM jev_reservations WHERE request_id = ?").get(requestID) as { usage_day: string; state: string } | undefined;
      if (!row || row.state === "settled") { this.database.exec("COMMIT"); return; }
      this.database.prepare("INSERT INTO jev_usage(usage_day,committed_micro_cents) VALUES(?,?) ON CONFLICT(usage_day) DO UPDATE SET committed_micro_cents = committed_micro_cents + excluded.committed_micro_cents").run(row.usage_day, actualMicroCents);
      this.database.prepare("UPDATE jev_reservations SET actual_micro_cents = ?, state = 'settled' WHERE request_id = ? AND state = 'pending'").run(actualMicroCents, requestID);
      this.database.exec("COMMIT");
    } catch (error) { try { this.database.exec("ROLLBACK"); } catch {} throw error; }
  }

  close(): void { if (!this.closed) { this.closed = true; this.database.close(); } }
  private assertOpen(): void { if (this.closed) throw new Error("Session search Jev allowance ledger is closed"); }
}
