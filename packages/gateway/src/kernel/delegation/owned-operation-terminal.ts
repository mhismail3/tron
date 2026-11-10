export interface OwnedOperationTerminal {
  lifecycle: "completed" | "failed" | "interrupted" | "outcomeUnknown";
  operationId: string;
  invocationId: string;
  errorCode?: string;
  assistantCompletionId?: string;
}
export const TASK_STOP_WAITING = "task-stop-waiting";
