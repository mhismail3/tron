import type { HomeTaskRecord } from "./home-task-store.js";

/** Resume links, not titles (nor reused fixture session IDs), define a delegation.
 * This is a disposable read projection; original operation records stay immutable. */
export function homeTaskLineages(records: HomeTaskRecord[]): HomeTaskRecord[][] {
  const byId = new Map(records.map(task => [task.taskId, task]));
  const groups = new Map<string, HomeTaskRecord[]>();
  for (const task of records) {
    let root = task;
    const visited = new Set<string>();
    while (root.resumes) {
      if (visited.has(root.taskId)) throw new Error("Cyclic task resume lineage");
      visited.add(root.taskId);
      const parent = byId.get(root.resumes.taskId);
      if (!parent || parent.operationId !== root.resumes.operationId || parent.homeId !== root.homeId
        || (root.sessionId !== null && root.sessionId !== parent.sessionId))
        throw new Error("Task resume lineage is missing or contradictory");
      root = parent;
    }
    const lineage = groups.get(root.taskId) ?? [];
    lineage.push(task); groups.set(root.taskId, lineage);
  }
  return [...groups.values()].map(lineage => lineage.sort((a, b) => a.createdAt - b.createdAt || a.taskId.localeCompare(b.taskId)));
}

/** A successor refused before admission never took over its worker. */
export function currentHomeTask(lineage: HomeTaskRecord[]): HomeTaskRecord {
  return lineage.findLast(task => task.operationId !== null || task.lifecycle !== "terminal") ?? lineage[0]!;
}

export function homeTaskNeedsAttention(task: HomeTaskRecord): boolean {
  return task.terminalEvidence?.outcome === "needs-input" || task.terminalEvidence?.outcome === "unknown"
    || (task.lifecycle === "active" && task.checkins?.at(-1)?.operationId === task.operationId && task.checkins.at(-1)?.needsAttention === true);
}
