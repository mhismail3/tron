import { resolve, sep } from "node:path";
import { core as pathShape } from "../core/security/path-shape/facade.js";

export function containedWithin(root: string, candidate: string): boolean {
  const tokens = new Map<string, number>();
  const components = (path: string) => resolve(path).split(sep).filter(Boolean)
    .map(name => tokens.get(name) ?? tokens.set(name, tokens.size).size - 1);
  return pathShape.Contained(components(root), components(candidate));
}
