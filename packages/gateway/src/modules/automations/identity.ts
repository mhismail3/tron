const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const automationOperation = /^automation:([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/iu;

export function isAutomationId(value: unknown): value is string {
  return typeof value === "string" && uuid.test(value);
}

export function automationOperationId(runId: string): string {
  if (!isAutomationId(runId)) throw new Error("Automation run identity is invalid");
  return `automation:${runId}`;
}

export function runIdFromAutomationOperationId(value: string): string | undefined {
  return automationOperation.exec(value)?.[1];
}
