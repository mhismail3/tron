import { watch } from "node:fs";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { waitFor } from "./wait-for.js";

export function fsEventsProbe(directory: string): { live(): Promise<void>; close(): void } {
  let probe = 0;
  const seen = new Set<string>();
  const watcher = watch(directory, { persistent: false }, (_event, name) => { if (name !== null) seen.add(String(name)); });
  return {
    live: () => {
      seen.clear();
      return waitFor(async () => {
        await writeFile(join(directory, `fsevents-probe-${probe += 1}`), "");
        return seen.size > 0;
      }, "the process FSEvents stream rescheduled after the latest watch delivers events").then(() => undefined);
    },
    close: () => watcher.close(),
  };
}
