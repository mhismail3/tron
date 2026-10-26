import { GatewayError } from "../../errors.js";
import type { ProjectRuntimePort } from "./project-lifecycle.js";

interface RuntimeEntry { isDisposed: boolean; isBusy: boolean; projectDir: string; cwd: string }
interface TaskPage { items: Array<{ target: string; lifecycle: string }>; nextCursor?: string }
/** Read canonical runtime/task owners, not a copied worker index. The native
 * trust-reload fence remains the actual exclusion mechanism at effects. */
export function projectRuntimePort(owners: () => {
  runtimeEntries(): ReadonlyArray<readonly [string, RuntimeEntry]>;
  reloadProject(path: string, trusted: boolean, publish: boolean): Promise<void>;
  commitProjectReload(path: string): Promise<void>;
  abortProjectReload(path: string): Promise<void>;
}, tasks: (cursor?: string) => Promise<TaskPage>): ProjectRuntimePort {
  return {
    assertIdle: async (path, moving) => {
      const within = (value: string) => value === path || value.startsWith(`${path}/`);
      if (owners().runtimeEntries().some(([, slot]) => !slot.isDisposed && (within(slot.projectDir) || within(slot.cwd)) && (moving || slot.isBusy))) {
        throw new GatewayError("busy", moving ? "Close project sessions before moving the folder" : "Stop active project sessions before changing trust");
      }
      let cursor: string | undefined;
      do {
        const page = await tasks(cursor);
        if (page.items.some(task => within(task.target) && task.lifecycle !== "terminal")) throw new GatewayError("busy", "Project has an active or pending Home worker");
        cursor = page.nextCursor;
      } while (cursor);
    },
    reload: (path, trusted) => owners().reloadProject(path, trusted, false),
    release: path => owners().commitProjectReload(path),
    abort: path => owners().abortProjectReload(path),
  };
}
