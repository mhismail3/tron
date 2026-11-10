import { readFileSync } from "node:fs";
import { parseFrontmatter } from "../kernel/pi/coding-agent.js";

export function skillTitle(filePath: string): string | undefined {
  try {
    const { frontmatter } = parseFrontmatter<Record<string, unknown>>(readFileSync(filePath, "utf8"));
    const title = typeof frontmatter.title === "string" ? frontmatter.title.trim() : "";
    return title.length > 0 ? title : undefined;
  } catch {
    return undefined;
  }
}
