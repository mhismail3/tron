export interface OwnedOperationTerminal {
  lifecycle: "completed" | "failed" | "interrupted" | "outcomeUnknown";
  operationId: string;
  invocationId: string;
  errorCode?: string;
  assistantCompletionId?: string;
}
/** The terminal a task's Stop or deadline reports while the task waits between turns: no turn
 * was running to interrupt, so the dispatcher reads it as a stop of the waiting task. */
export const TASK_STOP_WAITING = "task-stop-waiting";
