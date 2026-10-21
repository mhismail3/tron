import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { createTronScheduleExtension, type ScheduleToolOperations } from "./tron-schedule-extension.js";

export function createScheduleModule(operations: () => ScheduleToolOperations | undefined): ModuleDescriptor {
  return {
    name: "tron-schedule", purpose: "Creates and manages durable reminders and automations.",
    tools: ["schedule"], commands: [],
    start: () => ({ extension: session => {
      const owner = operations();
      return owner ? createTronScheduleExtension({ sessionId: session.sessionId, operations: owner }) : undefined;
    } }),
  };
}
