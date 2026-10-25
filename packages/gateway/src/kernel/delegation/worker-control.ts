import { randomUUID } from "node:crypto";
import type { ImageContent } from "../pi/ai.js";
import { GatewayError } from "../../errors.js";
import type { TaskWorkerControl } from "./worker-contract.js";
import type { HomeTaskReportOwner } from "./task-report.js";

/** The actual worker steer uses ordinary native admission, including its in-lane
 * operation fence. Build the identity only when that steer is submitted. */
export function taskWorkerSteeringInput(control: TaskWorkerControl, text: string) {
  const images: ImageContent[] = [];
  return [text, images, "steer", undefined, undefined, {
    operationId: randomUUID(), taskFence: structuredClone(control),
    origin: { kind: "gateway", ownerId: control.taskId, title: "Home steering", confidence: "boundary" }, onTerminal: () => {},
  }] as const;
}

/** Retain the control operation's async adoption of native admission, so its
 * caller observes the same boundary as the former native control operation. */
export async function steerTaskWorker<Result>(control: TaskWorkerControl, text: string,
  submit: (input: ReturnType<typeof taskWorkerSteeringInput>) => Promise<Result>): Promise<Result> {
  return submit(taskWorkerSteeringInput(control, text));
}

export async function stopTaskWorker(worker: HomeTaskReportOwner | undefined, control: TaskWorkerControl): Promise<void> {
  if (!worker || worker.identity.taskId !== control.taskId
    || worker.identity.operationId !== control.operationId) {
    throw new GatewayError("conflict", "Task operation changed before Stop");
  }
  await worker.stop();
}

/** Native per-call cancellation remains Run-owned. Its exact I/O starts only
 * after this role fence; it fixes targets before queuing steering and aborting. */
export async function interruptTaskWorker(worker: HomeTaskReportOwner | undefined, control: TaskWorkerControl,
  interrupt: () => Promise<string[]>): Promise<string[]> {
  if (!worker || worker.identity.taskId !== control.taskId
    || worker.identity.operationId !== control.operationId) {
    throw new GatewayError("conflict", "Task operation changed before Interrupt");
  }
  return await interrupt();
}
