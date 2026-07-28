import { sendToApns } from "./apns";
import type {
  Env,
  LedgerRow,
  NotificationRequest,
  RelayResult,
  RelayStatus,
} from "./contracts";
import { json } from "./response";
import { validateNotificationRequest } from "./validation";

export class RelayLedger {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {
    this.state.blockConcurrencyWhile(async () => {
      this.state.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS relay_requests (
          request_id TEXT PRIMARY KEY,
          state TEXT NOT NULL,
          response_json TEXT,
          updated_at INTEGER NOT NULL
        )
      `);
    });
  }

  async fetch(request: Request): Promise<Response> {
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }
    let delivery: NotificationRequest;
    try {
      const parsed = validateNotificationRequest(await request.json());
      if (!parsed.ok) {
        return json({ error: parsed.error }, 400);
      }
      delivery = parsed.value;
    } catch {
      return json({ error: "invalid_json" }, 400);
    }

    const replay = await this.beginAttempt(delivery.requestId);
    if (replay) {
      return json(replay);
    }

    let result: RelayResult;
    try {
      result = await sendToApns(this.env, delivery);
    } catch {
      result = {
        status: "retryable",
        reason: "relay_transport_error",
        retryAfterSeconds: 30,
      };
    }
    await this.finishAttempt(delivery.requestId, result);
    return json(result);
  }

  private async beginAttempt(requestId: string): Promise<RelayResult | undefined> {
    return this.state.storage.transaction(async () => {
      const existing = this.state.storage.sql
        .exec<LedgerRow>(
          "SELECT state, response_json FROM relay_requests WHERE request_id = ?",
          requestId,
        )
        .toArray()[0];
      const replay = replayResult(existing);
      if (replay) {
        return replay;
      }
      const now = Math.floor(Date.now() / 1000);
      this.state.storage.sql.exec(
        `INSERT INTO relay_requests (request_id, state, response_json, updated_at)
         VALUES (?, 'in_progress', NULL, ?)
         ON CONFLICT(request_id) DO UPDATE SET
           state = 'in_progress',
           response_json = NULL,
           updated_at = excluded.updated_at`,
        requestId,
        now,
      );
      return undefined;
    });
  }

  private async finishAttempt(requestId: string, result: RelayResult): Promise<void> {
    const terminal = isTerminal(result.status);
    await this.state.storage.transaction(async () => {
      this.state.storage.sql.exec(
        `UPDATE relay_requests
         SET state = ?, response_json = ?, updated_at = ?
         WHERE request_id = ?`,
        terminal ? "terminal" : "retryable",
        JSON.stringify(result),
        Math.floor(Date.now() / 1000),
        requestId,
      );
    });
  }
}

export function replayResult(row: LedgerRow | undefined): RelayResult | undefined {
  if (!row) {
    return undefined;
  }
  if (row.state === "in_progress") {
    return { status: "ambiguous", reason: "provider_outcome_unknown" };
  }
  if (row.state === "terminal" && row.response_json) {
    try {
      return JSON.parse(row.response_json) as RelayResult;
    } catch {
      return { status: "ambiguous", reason: "ledger_result_invalid" };
    }
  }
  return undefined;
}

function isTerminal(status: RelayStatus): boolean {
  return (
    status === "accepted_by_apns" ||
    status === "permanent_failure" ||
    status === "invalid_token"
  );
}
