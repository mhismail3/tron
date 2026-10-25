import type { GatewayErrorCode } from "../../errors.js";
import type { HomeTaskProducerRefusal } from "./task-worker-extension.js";

/** Why a Home control was refused: the owner's known refusal, or else the typed error's code. */
export type TaskControlRefusalReason = "stale-operation" | "no-live-worker" | "invalid-steering-text"
  | "steer-not-admitted" | "operation-changed" | "operation-guard-mismatch" | "action-unavailable" | "home-generation-changed" | GatewayErrorCode;
export interface TaskWorkerControl { taskId: string; operationId: string }

/** Worker and control diagnostics shared by native execution and its policy owner. */
export type TaskWorkerDiagnostic =
  | { event: "home.task.report-reminder"; taskHash: string; operationHash: string }
  | { event: "home.task.producer-refused"; taskHash: string; reason: HomeTaskProducerRefusal }
  | { event: "home.task.control"; taskHash: string; operationHash: string; action: "steer" | "stop"; disposition: "accepted" | "persisted" }
  /** The worker session's canonical name changed (#1336); the title itself is never logged. */
  | { event: "home.task.control"; taskHash: string; operationHash: string | null; action: "rename"; disposition: "accepted" }
  | { event: "home.task.control"; taskHash: string; operationHash: string; action: "interrupt"; disposition: "accepted"; calls: number }
  /** A rejected control, not proof cancellation had no effect. An early refusal may have no operation yet. */
  | { event: "home.task.control"; taskHash: string; operationHash?: string; action: "steer" | "interrupt" | "stop" | "rename"; disposition: "refused"; reason: TaskControlRefusalReason };
