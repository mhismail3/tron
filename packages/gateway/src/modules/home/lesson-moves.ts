import { createHash } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../../errors.js";
import { durableAtomicWriteJson, durableAtomicWriteText } from "../../foundation/durable-json.js";
import { tronHomePath } from "../../foundation/tron-home-layout.js";
import type { LessonMoveValue } from "../../kernel/settings/lesson-move-value.js";
import type { HomeProfileItems } from "./home-profile.js";

type NoteValue = Awaited<ReturnType<HomeProfileItems["values"]>> extends Map<string, infer V> ? V : never;

interface MovedLesson {
  value: LessonMoveValue;
  path: string;
  mode: number;
  before: string;
  after: string;
  notes: Array<{ id: string; prior: NoteValue }>;
}

const digest = (text: string) => createHash("sha256").update(text).digest("hex");
const MAINTAINER = { kind: "maintainer" } as const;

function stale(message: string): never {
  throw new GatewayError("conflict", message);
}

function once(text: string, needle: string, what: string): number {
  const at = text.indexOf(needle);
  if (at < 0 || text.indexOf(needle, at + 1) >= 0) stale(`The ${what} is not exactly once in the destination; read it again`);
  return at;
}

function edited(before: string, value: LessonMoveValue): string {
  if (value.destination.kind === "global-skill-description") {
    const line = /^description:[ \t]*(.*)$/mu.exec(before.split(/^---$/mu)[1] ?? "");
    if (!line) stale("The skill has no description line");
    if (value.replaces !== undefined && line[1] !== value.replaces) stale("The skill description changed; read it again");
    return before.replace(line[0], `description: ${value.text}`);
  }
  if (value.replaces !== undefined) {
    const at = once(before, value.replaces, "replaced text");
    return `${before.slice(0, at)}${value.text}${before.slice(at + value.replaces.length)}`;
  }
  const anchor = value.destination.anchor;
  if (anchor !== undefined) {
    const lines = before.split("\n");
    const matches = lines.flatMap((line, index) => line === anchor ? [index] : []);
    if (matches.length !== 1) stale("The anchor line is not exactly once in the destination; read it again");
    lines.splice(matches[0]! + 1, 0, value.text);
    return lines.join("\n");
  }
  return `${before}${before === "" || before.endsWith("\n") ? "" : "\n"}${value.text}\n`;
}

export class LessonMoves {
  constructor(private readonly agentDir: string, private readonly tronHome: string,
    private readonly profile: () => Pick<HomeProfileItems, "apply" | "values" | "restore">) {}

  async value(lesson: string): Promise<LessonMoveValue | undefined> {
    return (await this.load())[lesson]?.value;
  }

  async set(lesson: string, value: LessonMoveValue | undefined, commandId: string): Promise<void> {
    if (value) await this.move(lesson, value, commandId);
    else await this.undo(lesson, commandId);
  }

  private async move(lesson: string, value: LessonMoveValue, commandId: string): Promise<void> {
    const state = await this.load();
    if (state[lesson]) stale(`Lesson ${lesson} has already moved; undo it first`);
    const path = value.destination.kind === "global-rule" ? join(this.agentDir, "AGENTS.md") : join(this.agentDir, "skills", value.destination.skill, "SKILL.md");
    const before = await readFile(path, "utf8");
    const after = edited(before, value);
    const mode = (await stat(path)).mode & 0o777;
    const profile = this.profile();
    const ids = value.retire.notes.map(note => note.id);
    const priors = await profile.values(ids);
    await durableAtomicWriteText(path, after, mode);
    const retired: string[] = [];
    try {
      for (const [index, note] of value.retire.notes.entries()) {
        await profile.apply({ action: "retire", id: note.id, expectedRevision: note.revisionId, reason: `Moved to lesson ${lesson}` }, MAINTAINER, `${commandId}:retire:${index}`);
        retired.push(note.id);
      }
    } catch (error) {
      await durableAtomicWriteText(path, before, mode);
      if (retired.length) await profile.restore(retired.map(id => ({ id, value: priors.get(id) ?? null })), MAINTAINER, `${commandId}:rollback`);
      throw error;
    }
    state[lesson] = { value, path, mode, before, after: digest(after), notes: ids.map(id => ({ id, prior: priors.get(id) ?? null })) };
    await durableAtomicWriteJson(this.statePath(), state);
  }

  private async undo(lesson: string, commandId: string): Promise<void> {
    const state = await this.load();
    const moved = state[lesson];
    if (!moved) throw new GatewayError("not_found", `Lesson ${lesson} has not moved`);
    if (digest(await readFile(moved.path, "utf8")) !== moved.after) stale("The destination changed since the move; restore it by hand or move again");
    await this.profile().restore(moved.notes.map(note => ({ id: note.id, value: note.prior })), MAINTAINER, `${commandId}:restore`);
    await durableAtomicWriteText(moved.path, moved.before, moved.mode);
    delete state[lesson];
    await durableAtomicWriteJson(this.statePath(), state);
  }

  private statePath(): string {
    return tronHomePath(this.tronHome, "state/home/lessons.json");
  }

  private async load(): Promise<Record<string, MovedLesson>> {
    try {
      return JSON.parse(await readFile(this.statePath(), "utf8")) as Record<string, MovedLesson>;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return {};
      throw error;
    }
  }
}
