import type { GatewayErrorCode } from "../../errors.js";
import type { HomeTaskProducerRefusal } from "./task-worker-extension.js";

export type TaskControlRefusalReason = "stale-operation" | "no-live-worker" | "invalid-steering-text"
  | "steer-not-admitted" | "operation-changed" | "operation-guard-mismatch" | "action-unavailable" | "home-generation-changed" | GatewayErrorCode;
export interface TaskWorkerControl { taskId: string; operationId: string }

export type TaskWorkerDiagnostic =
  | { event: "home.task.report-reminder"; taskHash: string; operationHash: string }
  | { event: "home.task.producer-refused"; taskHash: string; reason: HomeTaskProducerRefusal }
  | { event: "home.task.control"; taskHash: string; operationHash: string; action: "steer" | "stop"; disposition: "accepted" | "persisted" }
  | { event: "home.task.control"; taskHash: string; operationHash: string | null; action: "rename"; disposition: "accepted" }
  | { event: "home.task.control"; taskHash: string; operationHash: string; action: "interrupt"; disposition: "accepted"; calls: number }
  | { event: "home.task.control"; taskHash: string; operationHash?: string; action: "steer" | "interrupt" | "stop" | "rename"; disposition: "refused"; reason: TaskControlRefusalReason };
