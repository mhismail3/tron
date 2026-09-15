export const SUPERVISOR_RELAUNCH_EXIT_CODE = 75;

export function handledSignalExitCode(supervised: boolean): number {
  return supervised ? SUPERVISOR_RELAUNCH_EXIT_CODE : 0;
}

export function administrativeExitCode(kind: "restart" | "shutdown"): number {
  return kind === "restart" ? SUPERVISOR_RELAUNCH_EXIT_CODE : 0;
}
