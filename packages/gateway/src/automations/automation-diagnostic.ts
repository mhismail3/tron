import { createHash } from "node:crypto";
import type { ModuleLog } from "../kernel/host/module-host.js";

export function logAutomationDiagnostic(
  logger: ModuleLog,
  message: string,
  automationId: string,
  runId?: string,
): void {
  logger.log("warning", message, {
    event: "automation.dispatch-failed", source: "automations",
    referenceHash: createHash("sha256").update(automationId).digest("hex").slice(0, 16),
    ...(runId === undefined ? {} : { operationHash: createHash("sha256").update(runId).digest("hex").slice(0, 16) }),
  });
}
