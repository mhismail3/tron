import { GatewayError } from "../../errors.js";
import type { Direction } from "./tool-contract.js";
import type { ValueType } from "./settings-types.js";

export interface LessonMoveValue {
  destination: { kind: "global-rule"; file: "AGENTS.md"; anchor?: string } | { kind: "global-skill-description"; skill: string };
  text: string;
  replaces?: string;
  retire: { notes: Array<{ id: string; revisionId: string; text: string }> };
}

const object = (value: unknown, label: string): Record<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("invalid_request", `${label} must be an object`);
  return value as Record<string, unknown>;
};
const text = (value: unknown, label: string, max: number): string => {
  if (typeof value !== "string" || value.trim() === "" || Buffer.byteLength(value) > max) throw new GatewayError("invalid_request", `${label} must be non-empty text of at most ${max} bytes`);
  return value;
};
const only = (value: Record<string, unknown>, fields: readonly string[], label: string) => {
  const extra = Object.keys(value).find(field => !fields.includes(field));
  if (extra) throw new GatewayError("invalid_request", `${label}.${extra} is not a lesson move field`);
};

function validateLessonMove(raw: unknown, label: string): LessonMoveValue {
  const value = object(raw, label);
  only(value, ["destination", "text", "replaces", "retire"], label);
  const destination = object(value.destination, `${label}.destination`);
  let target: LessonMoveValue["destination"];
  if (destination.kind === "global-rule") {
    only(destination, ["kind", "file", "anchor"], `${label}.destination`);
    if (destination.file !== "AGENTS.md") throw new GatewayError("invalid_request", `${label}.destination.file must be AGENTS.md`);
    target = { kind: "global-rule", file: "AGENTS.md", ...(destination.anchor === undefined ? {} : { anchor: text(destination.anchor, `${label}.destination.anchor`, 2_000) }) };
  } else if (destination.kind === "global-skill-description") {
    only(destination, ["kind", "skill"], `${label}.destination`);
    const skill = text(destination.skill, `${label}.destination.skill`, 64);
    if (!/^[a-z0-9][a-z0-9-]*$/u.test(skill)) throw new GatewayError("invalid_request", `${label}.destination.skill must be a skill name`);
    target = { kind: "global-skill-description", skill };
  } else throw new GatewayError("invalid_request", `${label}.destination.kind must be global-rule or global-skill-description`);
  const moved = text(value.text, `${label}.text`, 2_000);
  const replaces = value.replaces === undefined ? undefined : text(value.replaces, `${label}.replaces`, 2_000);
  if (target.kind === "global-skill-description") {
    if (moved.length > 160 || /[\r\n\u2028\u2029]/u.test(moved)) throw new GatewayError("invalid_request", `${label}.text must be one line of at most 160 characters for a skill description`);
    if (replaces === undefined) throw new GatewayError("invalid_request", `${label}.replaces must name the current skill description`);
  } else if (target.anchor !== undefined && replaces !== undefined) throw new GatewayError("invalid_request", `${label} takes an anchor or replaced text, not both`);
  const retire = object(value.retire, `${label}.retire`);
  only(retire, ["notes"], `${label}.retire`);
  if (!Array.isArray(retire.notes) || retire.notes.length === 0 || retire.notes.length > 32) throw new GatewayError("invalid_request", `${label}.retire.notes must name 1 to 32 notes`);
  const notes = retire.notes.map((note, index) => {
    const entry = object(note, `${label}.retire.notes[${index}]`);
    only(entry, ["id", "revisionId", "text"], `${label}.retire.notes[${index}]`);
    return { id: text(entry.id, `${label}.retire.notes[${index}].id`, 200), revisionId: text(entry.revisionId, `${label}.retire.notes[${index}].revisionId`, 200),
      text: text(entry.text, `${label}.retire.notes[${index}].text`, 2_000) };
  });
  return { destination: target, text: moved, ...(replaces === undefined ? {} : { replaces }), retire: { notes } };
}

export const lessonMoveDirection = (): Direction => "widen";

export const lessonMoveType: ValueType = {
  kind: "lessonMove",
  validate: (value, label) => validateLessonMove(value, label),
  format: value => {
    const move = value as LessonMoveValue;
    const where = move.destination.kind === "global-rule" ? "global AGENTS.md" : `skill ${move.destination.skill} description`;
    return `${where}: ${move.text}${move.replaces ? ` (replaces: ${move.replaces})` : ""}; retires ${move.retire.notes.length} note${move.retire.notes.length === 1 ? "" : "s"}: ${move.retire.notes.map(note => JSON.stringify(note.text)).join("; ")}`;
  },
};
