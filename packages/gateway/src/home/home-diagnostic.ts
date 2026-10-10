import type { GatewayErrorCode } from "../errors.js";
import type { GatewayLogger } from "../transport/logger.js";
import type { CommandReceiptRouteCategory } from "../transport/command-receipts.js";
import type { ReservedHomeSessionScan } from "./home-session-recovery.js";

export type HomeHardBoundary = "hard-bytes" | "hard-entries";
export type HomeDiagnosticRecord =
  | { outcome: "client-control"; operation: "configureMemory" | "pauseMemory" | "resumeMemory"; reason: "completed" | "failed" | GatewayErrorCode }
  | { outcome: "designated" | "enabled" | "disabled" }
  | { outcome: "refused"; reason: "session-busy" | "model-change-requires-session-set-model" }
  | { outcome: "unavailable"; reason: "unreadable" | "unsupported-record" | "owner-fenced" | "publication-retirement-failed" }
  | { outcome: "chapter-rollover"; chapterOrdinal: number; reason: "soft-byte-limit" | "soft-entry-limit" | "hard-byte-limit" | "hard-entry-limit" }
  | { outcome: "chapter-recovery"; reason: Exclude<ReservedHomeSessionScan["action"], "blocked"> | "conversation-published" }
  | { outcome: "chapter-refused"; chapterOrdinal?: number; reason: HomeHardBoundary | "sealed-write" | "uncertain-session-evidence" | "materialization-failed" | "ownership-changed" | "missing-conversation-evidence" | "published-evidence-missing" | "publication-failed" | "conversation-not-durable" }
  | { outcome: "chapter-limit-stop"; chapterOrdinal: number; boundary: HomeHardBoundary; crossingBytes: number; crossingEntries: number; settledBytes: number; settledEntries: number }
  | { outcome: "wake"; decision: "admitted" | "deferred" | "refused"; reason: "delivered" | "busy" | "disabled" | "paused" | "blocked" | "unavailable" | "ceiling" | "nothing-deliverable" | "failed" }
  | { outcome: "route-bound"; category: "open" | CommandReceiptRouteCategory };

export type HomeDiagnostic = (diagnostic: HomeDiagnosticRecord) => void;

/** One privacy boundary for Home signals. Never spread caller metadata into the
 * shared logger: canonical identities and evidence belong to their owners. */
export function logHomeDiagnostic(logger: Pick<GatewayLogger, "log">, diagnostic: HomeDiagnosticRecord): void {
  const level = (diagnostic.outcome === "client-control" && diagnostic.reason !== "completed") || diagnostic.outcome === "unavailable" || diagnostic.outcome === "refused"
    || diagnostic.outcome === "chapter-refused" || diagnostic.outcome === "chapter-limit-stop"
    || (diagnostic.outcome === "wake" && diagnostic.decision === "refused") ? "warning" : "info";
  logger.log(level, `Tron Home ${diagnostic.outcome}`, {
    event: `home.${diagnostic.outcome}`, source: "home",
    ...("reason" in diagnostic ? { reason: diagnostic.reason } : {}),
    ...("chapterOrdinal" in diagnostic ? { chapterOrdinal: diagnostic.chapterOrdinal } : {}),
    ...(diagnostic.outcome === "client-control" ? { operation: diagnostic.operation } : {}),
    ...(diagnostic.outcome === "route-bound" ? { category: diagnostic.category } : {}),
    ...(diagnostic.outcome === "wake" ? { decision: diagnostic.decision } : {}),
    ...(diagnostic.outcome === "chapter-limit-stop" ? {
      boundary: diagnostic.boundary, crossingBytes: diagnostic.crossingBytes,
      crossingEntries: diagnostic.crossingEntries, settledBytes: diagnostic.settledBytes,
      settledEntries: diagnostic.settledEntries,
    } : {}),
  });
}
