import { lstat, realpath } from "node:fs/promises";
import { isAbsolute, join, parse } from "node:path";
import { GatewayError } from "../errors.js";

/** Command IDs are the idempotency key an RPC receipt and its helper argument
 * carry, so every admin surface admits the same bounded form. */
export const COMMAND_ID = /^[A-Za-z0-9._:-]{8,160}$/u;

const MAX_TIMESTAMP_BYTES = 64;
const MAX_PATH_BYTES = 4_096;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/u;
const ISO_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/u;
/** Persisted deployment state may carry a numeric UTC offset as well as `Z`. */
const ISO_TIMESTAMP_WITH_OFFSET = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/u;

/** One bounded failure line: the byte bound, the sentence used when a failure
 * clamps to nothing, and the rejection for a persisted value that carries no
 * failure at all. */
export interface FailureLine {
  maximum: number;
  fallback: string;
  rejection: string;
}

/** Clamp an error or helper failure to one control-free line of at most
 * `line.maximum` bytes. A byte slice can tear a multi-byte character, so a torn
 * tail is dropped rather than projected. */
export function boundedFailureText(error: unknown, line: FailureLine): string {
  const raw = error instanceof Error ? error.message : String(error);
  const cleaned = raw.replace(/[\u0000-\u001f\u007f]+/gu, " ").replace(/\s+/gu, " ").trim();
  if (Buffer.byteLength(cleaned) <= line.maximum) return cleaned || line.fallback;
  return Buffer.from(cleaned).subarray(0, line.maximum).toString("utf8").replace(/�+$/u, "");
}

/** Admit a persisted failure. A document that reports a failure has to say why,
 * so an empty or non-string value is rejected before it is bounded. */
export function admittedFailure(value: unknown, line: FailureLine): string {
  if (typeof value !== "string" || Buffer.byteLength(value) === 0) {
    throw new GatewayError("conflict", line.rejection);
  }
  return boundedFailureText(value, line);
}

export interface TimestampAdmission {
  /** Rejection for an absent value or one that is not an admitted ISO-8601 instant. */
  rejection: string;
  /** Rejection for a value that is not a bounded, control-free string; defaults to `rejection`. */
  shapeRejection?: string;
  /** Admit a numeric UTC offset as well as `Z`. */
  allowOffset?: boolean;
}

/** Admit one persisted timestamp. Only the admitted shapes parse to a stable
 * instant for ordering, and the bound keeps a document from projecting
 * unbounded text. */
export function admitIsoTimestamp(value: unknown, admission: TimestampAdmission): string {
  if (value === undefined || value === null) throw new GatewayError("conflict", admission.rejection);
  if (typeof value !== "string" || Buffer.byteLength(value) === 0 || Buffer.byteLength(value) > MAX_TIMESTAMP_BYTES
    || CONTROL_CHARACTERS.test(value)) {
    throw new GatewayError("conflict", admission.shapeRejection ?? admission.rejection);
  }
  if (!(admission.allowOffset ? ISO_TIMESTAMP_WITH_OFFSET : ISO_TIMESTAMP).test(value)) {
    throw new GatewayError("conflict", admission.rejection);
  }
  return value;
}

export interface TrustedDirectoryAdmission {
  /** Subject of every rejection, for example `Gateway update sourceRoot`. */
  subject: string;
  /** Root-relative files that must exist as regular, non-linked files. */
  markers?: string[];
  /** Rejection for a missing or linked marker; defaults to `${subject} is not a Tron repository`. */
  markerRejection?: string;
}

/** Admit a trusted absolute directory and return its resolved real path. The
 * path and every component must be control-free and free of symlinks, the
 * resolved target must be a regular directory, and every marker the caller
 * names must exist as a regular file. This is the only admission for a path an
 * admin surface later executes or reads from. */
export async function admitTrustedDirectory(value: unknown, admission: TrustedDirectoryAdmission): Promise<string> {
  const { subject } = admission;
  if (typeof value !== "string" || !isAbsolute(value) || Buffer.byteLength(value) > MAX_PATH_BYTES
    || CONTROL_CHARACTERS.test(value)) {
    throw new GatewayError("invalid_request", `${subject} must be an absolute path`);
  }
  const root = parse(value).root;
  let cursor = root;
  for (const component of value.slice(root.length).split(/[\\/]+/u).filter(Boolean)) {
    cursor = join(cursor, component);
    // Refuse a linked component before the walk can be redirected through it.
    const info = await lstat(cursor).catch(() => undefined);
    if (!info) throw new GatewayError("conflict", `${subject} is unavailable`);
    if (info.isSymbolicLink()) throw new GatewayError("conflict", `${subject} contains a symlink`);
  }
  const resolved = await realpath(value).catch(() => undefined);
  if (!resolved) throw new GatewayError("conflict", `${subject} is unavailable`);
  const info = await lstat(resolved);
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new GatewayError("conflict", `${subject} must be a regular directory`);
  }
  for (const marker of admission.markers ?? []) {
    const markerInfo = await lstat(join(resolved, marker)).catch(() => undefined);
    if (!markerInfo?.isFile() || markerInfo.isSymbolicLink()) {
      throw new GatewayError("conflict", admission.markerRejection ?? `${subject} is not a Tron repository`);
    }
  }
  return resolved;
}
