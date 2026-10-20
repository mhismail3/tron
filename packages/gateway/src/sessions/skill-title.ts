import { readFileSync } from "node:fs";
import { parseFrontmatter } from "../kernel/pi/coding-agent.js";

/**
 * The optional display `title` a SKILL.md frontmatter declares. Pi's skill
 * loader keeps only `name`, `description` and `disable-model-invocation` and
 * ignores other keys without a diagnostic, so the title is read here from the
 * same file. It is presentation only: the skill's `name`, folder and
 * `/skill:<name>` invocation are unchanged. An unreadable file, unparsable
 * frontmatter or a missing, non-string or blank title yields `undefined`, and
 * clients fall back to the title they derive from the name.
 */
export function skillTitle(filePath: string): string | undefined {
  try {
    const { frontmatter } = parseFrontmatter<Record<string, unknown>>(readFileSync(filePath, "utf8"));
    const title = typeof frontmatter.title === "string" ? frontmatter.title.trim() : "";
    return title.length > 0 ? title : undefined;
  } catch {
    return undefined;
  }
}
