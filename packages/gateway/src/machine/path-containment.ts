import { isAbsolute, relative, sep } from "node:path";

/** Whether `candidate` is `root` itself or a path below it.
 *
 * The folder picker, the session workspace inspector and the managed Git
 * worktree root each refuse to operate outside their own root, so the
 * comparison has one owner instead of one copy per caller. */
export function containedWithin(root: string, candidate: string): boolean {
  const delta = relative(root, candidate);
  return delta === "" || (!delta.startsWith(`..${sep}`) && delta !== ".." && !isAbsolute(delta));
}
