import { watch } from "node:fs";

export interface FolderWatchRequest {
  root: string;
  onEvent(filename: string | null): void;
  onReset(reason: "error" | "unavailable"): void;
}
export interface FolderWatchHandle { close(): void }

/** Shared filesystem observation only; membership, reconciliation and lifecycle
 * remain with each owning index. Never interpret an event as a file fact. */
export function watchFolder(request: FolderWatchRequest): FolderWatchHandle {
  const watcher = watch(request.root, { recursive: true, persistent: false }, (_event, filename) => {
    request.onEvent(typeof filename === "string" ? filename : null);
  });
  watcher.on("error", () => request.onReset("error"));
  return { close: () => watcher.close() };
}
