import { randomUUID } from "node:crypto";
import { injectedText } from "../host/injected-text.js";
import type { ImageContent } from "../pi/ai.js";
import { GatewayError } from "../../errors.js";
import type { TaskWorkerControl } from "./worker-contract.js";
import type { HomeTaskReportOwner } from "./task-report.js";

export function taskWorkerSteeringInput(control: TaskWorkerControl, text: string, from: "tron-home" | "maintainer" = "tron-home") {
  const images: ImageContent[] = [];
  return [injectedText(text, from, "steer", "task"), images, "steer", undefined, undefined, {
    operationId: randomUUID(), taskFence: structuredClone(control),
    origin: { kind: "gateway", ownerId: control.taskId, title: "Home steering", confidence: "boundary" }, onTerminal: () => {},
  }] as const;
}

export async function stopTaskWorker(worker: HomeTaskReportOwner | undefined, control: TaskWorkerControl): Promise<void> {
  if (!worker || worker.identity.taskId !== control.taskId
    || worker.identity.operationId !== control.operationId) {
    throw new GatewayError("conflict", "Task operation changed before Stop");
  }
  await worker.stop();
}

export async function interruptTaskWorker(worker: HomeTaskReportOwner | undefined, control: TaskWorkerControl,
  interrupt: () => Promise<string[]>): Promise<string[]> {
  if (!worker || worker.identity.taskId !== control.taskId
    || worker.identity.operationId !== control.operationId) {
    throw new GatewayError("conflict", "Task operation changed before Interrupt");
  }
  return await interrupt();
}
