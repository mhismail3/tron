export type TaskAction = "start" | "steer" | "interrupt" | "stop" | "report" | "resume" | "observe" | "terminal-stop";
export interface TaskLifecycleModel {
  state: "absent" | "active" | "terminal";
  generation: number;
  outcomes: Array<"interrupted" | "final">;
}
export function initialTaskModel(): TaskLifecycleModel {
  return { state: "absent", generation: 0, outcomes: [] };
}
export function enabledTaskAction(model: Readonly<TaskLifecycleModel>, action: TaskAction): boolean {
  if (action === "observe") return true;
  if (action === "start") return model.state === "absent";
  if (action === "resume" || action === "terminal-stop") return model.state === "terminal";
  return model.state === "active";
}
export function stepTaskModel(model: TaskLifecycleModel, action: TaskAction): void {
  if (!enabledTaskAction(model, action)) throw new Error(`Invalid reference transition: ${model.state}/${action}`);
  if (action === "start" || action === "resume") {
    if (action === "resume") model.generation += 1;
    model.state = "active";
  } else if (action === "stop" || action === "report") {
    model.state = "terminal";
    model.outcomes.push(action === "stop" ? "interrupted" : "final");
  }
}
