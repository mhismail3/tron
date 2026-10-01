import { GatewayError } from "../errors.js";

export interface PaidBudgetAttempt {
  month: string;
  reservedCents: number;
  status: "reserved" | "settled" | "uncertain";
  actualCostCents?: number;
  inputTokens?: number;
  outputTokens?: number;
}

export interface PaidBudgetLedger {
  month: string;
  spentCents: number;
  reservedCents: number;
  attempts: Record<string, PaidBudgetAttempt>;
}

export function paidBudgetMonth(instant = new Date()): string {
  return `${instant.getUTCFullYear()}-${String(instant.getUTCMonth() + 1).padStart(2, "0")}`;
}

/** Carry unresolved attempts across a UTC month boundary; settled spend resets. */
export function rollPaidBudget(ledger: PaidBudgetLedger | undefined, month: string): PaidBudgetLedger {
  // KnowledgeStore gives mutations and reads their own state snapshot; preserve
  // Jev's existing in-snapshot mutation path instead of cloning every attempt.
  if (ledger?.month === month) return ledger;
  const attempts = Object.fromEntries(Object.entries(ledger?.attempts ?? {}).filter(([, attempt]) => attempt.status === "uncertain" || attempt.status === "reserved"));
  return { month, spentCents: 0, reservedCents: 0, attempts };
}

export function hasOpenPaidBudgetAttempt(ledger: PaidBudgetLedger): boolean {
  return Object.values(ledger.attempts).some(attempt => attempt.status === "uncertain" || attempt.status === "reserved");
}

export function availablePaidBudgetCents(capCents: number, ledger: PaidBudgetLedger): number {
  return Math.max(0, capCents - ledger.spentCents - ledger.reservedCents);
}

export function reservePaidBudgetAttempt(ledger: PaidBudgetLedger | undefined, attemptId: string, month: string, reserveCents: number, capCents: number): PaidBudgetLedger {
  const next = rollPaidBudget(ledger, month);
  if (hasOpenPaidBudgetAttempt(next)) throw new GatewayError("conflict", "An uncertain paid dispatch must be reconciled before more paid work");
  const prior = next.attempts[attemptId];
  if (prior) throw new GatewayError("conflict", "This paid attempt already has a budget receipt");
  if (!Number.isFinite(reserveCents) || reserveCents < 0 || next.spentCents + next.reservedCents + reserveCents > capCents + 1e-9) throw new GatewayError("conflict", "Paid budget cannot cover this request");
  next.reservedCents += reserveCents;
  next.attempts[attemptId] = { month, reservedCents: reserveCents, status: "reserved" };
  return next;
}

export function markPaidBudgetDispatch(ledger: PaidBudgetLedger, attemptId: string, month: string): PaidBudgetLedger {
  const next = rollPaidBudget(ledger, month);
  const attempt = next.attempts[attemptId];
  if (!attempt || attempt.status !== "reserved" || attempt.month !== month) throw new GatewayError("conflict", "Paid budget reservation is no longer dispatchable");
  attempt.status = "uncertain";
  return next;
}

export function settlePaidBudgetAttempt(ledger: PaidBudgetLedger, attemptId: string, month: string, actualCostCents: number): PaidBudgetLedger {
  const next = rollPaidBudget(ledger, month);
  const attempt = next.attempts[attemptId];
  if (!attempt || attempt.status !== "uncertain" || !Number.isSafeInteger(actualCostCents) || actualCostCents < 0 || actualCostCents > attempt.reservedCents) throw new GatewayError("conflict", "Paid response cannot safely reconcile its reservation");
  attempt.status = "settled";
  attempt.actualCostCents = actualCostCents;
  if (ledger.month === attempt.month && ledger.month === month) {
    next.reservedCents = Math.max(0, next.reservedCents - attempt.reservedCents);
    next.spentCents += actualCostCents;
  }
  return next;
}

export function reconcilePaidBudgetAttempt(ledger: PaidBudgetLedger | undefined, attemptId: string, month: string): { ledger: PaidBudgetLedger; reconciledCostCents: number } {
  if (!ledger?.attempts[attemptId] || !["reserved", "uncertain"].includes(ledger.attempts[attemptId]!.status)) throw new GatewayError("conflict", "Paid attempt is unknown or already settled");
  const stored = ledger.attempts[attemptId]!;
  const reconciledCostCents = stored.reservedCents;
  const next = rollPaidBudget(ledger, month);
  const attempt = next.attempts[attemptId] ?? stored;
  attempt.status = "settled";
  attempt.actualCostCents = reconciledCostCents;
  if (stored.month === month) {
    next.reservedCents = Math.max(0, next.reservedCents - stored.reservedCents);
    next.spentCents += reconciledCostCents;
  }
  next.attempts[attemptId] = attempt;
  return { ledger: next, reconciledCostCents };
}

export function releaseUndispatchedPaidBudgetAttempt(ledger: PaidBudgetLedger, attemptId: string, month: string): PaidBudgetLedger {
  const next = rollPaidBudget(ledger, month);
  const attempt = next.attempts[attemptId];
  if (attempt?.status === "reserved") {
    attempt.status = "settled";
    attempt.actualCostCents = 0;
    next.reservedCents = Math.max(0, next.reservedCents - attempt.reservedCents);
  }
  return next;
}
