export const SUPERVISOR_RELAUNCH_EXIT_CODE = 75;

export function handledSignalExitCode(supervised: boolean, restartPending: boolean): number {
  return supervised || restartPending ? SUPERVISOR_RELAUNCH_EXIT_CODE : 0;
}
