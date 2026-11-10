import { GatewayError } from "../../errors.js";
import type { ProjectRuntimePort } from "./project-lifecycle.js";

interface RuntimeEntry { isDisposed: boolean; isBusy: boolean; projectDir: string; cwd: string }
export function projectRuntimePort(owners: () => {
  runtimeEntries(): ReadonlyArray<readonly [string, RuntimeEntry]>;
  reloadProject(path: string, trusted: boolean, publish: boolean): Promise<void>;
  commitProjectReload(path: string): Promise<void>;
  abortProjectReload(path: string): Promise<void>;
}, activeTaskTargets: (signal?: AbortSignal) => Promise<readonly string[]>): ProjectRuntimePort {
  return {
    occupancy: async signal => {
      const targets = await activeTaskTargets(signal);
      return { assertIdle: path => {
        const within = (value: string) => value === path || value.startsWith(`${path}/`);
        if (owners().runtimeEntries().some(([, slot]) => !slot.isDisposed && (within(slot.projectDir) || within(slot.cwd)) && slot.isBusy)) {
          throw new GatewayError("busy", "Stop active project sessions before changing trust");
        }
        if (targets.some(within)) throw new GatewayError("busy", "Project has an active or pending Home worker");
      } };
    },
    reload: (path, trusted) => owners().reloadProject(path, trusted, false),
    release: path => owners().commitProjectReload(path),
    abort: path => owners().abortProjectReload(path),
  };
}
