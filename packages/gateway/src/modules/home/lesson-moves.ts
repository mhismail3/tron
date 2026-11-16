import { createHash } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../../errors.js";
import { durableAtomicWriteJson, durableAtomicWriteText } from "../../foundation/durable-json.js";
import { tronHomePath } from "../../foundation/tron-home-layout.js";
import { parseFrontmatter } from "../../kernel/pi/coding-agent.js";
import type { LessonMoveValue } from "../../kernel/settings/lesson-move-value.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import type { HomeProfileItems } from "./home-profile.js";

type NoteValue = Awaited<ReturnType<HomeProfileItems["values"]>> extends Map<string, infer V> ? V : never;

interface MovedLesson {
  value: LessonMoveValue;
  path: string;
  mode: number;
  before: string;
  after: string;
  notes: Array<{ id: string; prior: NoteValue; moved: NoteValue }>;
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

function description(text: string): unknown {
  try { return parseFrontmatter<Record<string, unknown>>(text).frontmatter.description; }
  catch { return undefined; }
}

function edited(before: string, value: LessonMoveValue): string {
  if (value.destination.kind === "global-skill-description") {
    if (description(before) !== value.replaces) stale("The skill description changed; read it again");
    const block = /^---\r?\n([^]*?)\r?\n---/u.exec(before);
    const line = block ? /^description:.*$/mu.exec(block[1]!) : null;
    if (!block || !line) stale("The skill has no description line");
    const at = block.index + block[0].indexOf(block[1]!) + line.index;
    const after = `${before.slice(0, at)}description: ${JSON.stringify(value.text)}${before.slice(at + line[0].length)}`;
    if (description(after) !== value.text) stale("The new description does not round-trip through the skill frontmatter");
    return after;
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
  private readonly mutex = new AsyncMutex();

  constructor(private readonly agentDir: string, private readonly tronHome: string,
    private readonly profile: () => Pick<HomeProfileItems, "apply" | "values" | "restore">) {}

  async value(lesson: string): Promise<LessonMoveValue | undefined> {
    const state = await this.load();
    return Object.hasOwn(state, lesson) ? state[lesson]!.value : undefined;
  }

  set(lesson: string, value: LessonMoveValue | undefined, commandId: string): Promise<void> {
    return this.mutex.run(() => value ? this.move(lesson, value, commandId) : this.undo(lesson, commandId));
  }

  private async move(lesson: string, value: LessonMoveValue, commandId: string): Promise<void> {
    const state = await this.load();
    if (Object.hasOwn(state, lesson)) stale(`Lesson ${lesson} has already moved; undo it first`);
    const path = value.destination.kind === "global-rule" ? join(this.agentDir, "AGENTS.md") : join(this.agentDir, "skills", value.destination.skill, "SKILL.md");
    const profile = this.profile();
    const ids = value.retire.notes.map(note => note.id);
    const priors = await profile.values(ids);
    for (const note of value.retire.notes) {
      const prior = priors.get(note.id);
      if (!prior || prior.revisionId !== note.revisionId || prior.state !== "active" || prior.text !== note.text) stale(`Note ${note.id} is no longer the active revision you read; read it again`);
    }
    const before = await readFile(path, "utf8");
    const after = edited(before, value);
    const mode = (await stat(path)).mode & 0o777;
    if (digest(await readFile(path, "utf8")) !== digest(before)) stale("The destination changed while the move was prepared; read it again");
    await durableAtomicWriteText(path, after, mode);
    const retired: string[] = [];
    try {
      for (const [index, note] of value.retire.notes.entries()) {
        await profile.apply({ action: "retire", id: note.id, expectedRevision: note.revisionId, reason: `Moved to lesson ${lesson}` }, MAINTAINER, `${commandId}:retire:${index}`);
        retired.push(note.id);
      }
      const moved = await profile.values(ids);
      state[lesson] = { value, path, mode, before, after: digest(after), notes: ids.map(id => ({ id, prior: priors.get(id) ?? null, moved: moved.get(id) ?? null })) };
      await durableAtomicWriteJson(this.statePath(), state);
    } catch (error) {
      await durableAtomicWriteText(path, before, mode);
      if (retired.length) await profile.restore(retired.map(id => ({ id, value: priors.get(id) ?? null })), MAINTAINER, `${commandId}:rollback`);
      throw error;
    }
  }

  private async undo(lesson: string, commandId: string): Promise<void> {
    const state = await this.load();
    if (!Object.hasOwn(state, lesson)) throw new GatewayError("not_found", `Lesson ${lesson} has not moved`);
    const moved = state[lesson]!;
    if (digest(await readFile(moved.path, "utf8")) !== moved.after) stale("The destination changed since the move; restore it by hand or move again");
    const profile = this.profile();
    const current = await profile.values(moved.notes.map(note => note.id));
    if (moved.notes.some(note => JSON.stringify(current.get(note.id) ?? null) !== JSON.stringify(note.moved))) stale("A retired note changed since the move; restore it by hand");
    await durableAtomicWriteText(moved.path, moved.before, moved.mode);
    try {
      await profile.restore(moved.notes.map(note => ({ id: note.id, value: note.prior })), MAINTAINER, `${commandId}:restore`);
      const { [lesson]: _undone, ...rest } = state;
      await durableAtomicWriteJson(this.statePath(), rest);
    } catch (error) {
      try {
        await durableAtomicWriteText(moved.path, edited(moved.before, moved.value), moved.mode);
      } finally {
        await profile.restore(moved.notes.map(note => ({ id: note.id, value: note.moved })), MAINTAINER, `${commandId}:rollback`);
        const current = await profile.values(moved.notes.map(note => note.id));
        moved.notes = moved.notes.map(note => ({ ...note, moved: current.get(note.id) ?? null }));
        await durableAtomicWriteJson(this.statePath(), state);
      }
      throw error;
    }
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
