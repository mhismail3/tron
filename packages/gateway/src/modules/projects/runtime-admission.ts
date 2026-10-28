import { GatewayError } from "../../errors.js";
import type { ProjectRuntimePort } from "./project-lifecycle.js";

interface RuntimeEntry { isDisposed: boolean; isBusy: boolean; projectDir: string; cwd: string }
/** Read canonical runtime/task owners, not a copied worker index. The native
 * trust-reload fence remains the actual exclusion mechanism at effects. One
 * occupancy reads the Home task store once, so a listing of many folders asks
 * once instead of once per folder (and per page of task history). */
export function projectRuntimePort(owners: () => {
  runtimeEntries(): ReadonlyArray<readonly [string, RuntimeEntry]>;
  reloadProject(path: string, trusted: boolean, publish: boolean): Promise<void>;
  commitProjectReload(path: string): Promise<void>;
  abortProjectReload(path: string): Promise<void>;
}, activeTaskTargets: (signal?: AbortSignal) => Promise<readonly string[]>): ProjectRuntimePort {
  return {
    occupancy: async signal => {
      const targets = await activeTaskTargets(signal);
      return { assertIdle: (path, moving) => {
        const within = (value: string) => value === path || value.startsWith(`${path}/`);
        if (owners().runtimeEntries().some(([, slot]) => !slot.isDisposed && (within(slot.projectDir) || within(slot.cwd)) && (moving || slot.isBusy))) {
          throw new GatewayError("busy", moving ? "Close project sessions before moving the folder" : "Stop active project sessions before changing trust");
        }
        if (targets.some(within)) throw new GatewayError("busy", "Project has an active or pending Home worker");
      } };
    },
    reload: (path, trusted) => owners().reloadProject(path, trusted, false),
    release: path => owners().commitProjectReload(path),
    abort: path => owners().abortProjectReload(path),
  };
}
