import { lstat, realpath } from "node:fs/promises";
import { isAbsolute, join, parse } from "node:path";
import { GatewayError } from "../errors.js";

export const COMMAND_ID = /^[A-Za-z0-9._:-]{8,160}$/u;

const MAX_TIMESTAMP_BYTES = 64;
const MAX_PATH_BYTES = 4_096;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/u;
const ISO_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/u;
const ISO_TIMESTAMP_WITH_OFFSET = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/u;

export interface FailureLine {
  maximum: number;
  fallback: string;
  rejection: string;
}

export function boundedFailureText(error: unknown, line: FailureLine): string {
  const raw = error instanceof Error ? error.message : String(error);
  const cleaned = raw.replace(/[\u0000-\u001f\u007f]+/gu, " ").replace(/\s+/gu, " ").trim();
  if (Buffer.byteLength(cleaned) <= line.maximum) return cleaned || line.fallback;
  return Buffer.from(cleaned).subarray(0, line.maximum).toString("utf8").replace(/�+$/u, "");
}

export function admittedFailure(value: unknown, line: FailureLine): string {
  if (typeof value !== "string" || Buffer.byteLength(value) === 0) {
    throw new GatewayError("conflict", line.rejection);
  }
  return boundedFailureText(value, line);
}

interface TimestampAdmission {
  rejection: string;
  shapeRejection?: string;
  allowOffset?: boolean;
}

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

export async function admitTronSourceRoot(value: unknown): Promise<string> {
  return admitTrustedDirectory(value, {
    subject: "Source repository",
    markers: ["packages/gateway/package.json", "packages/ios-app/project.yml", "scripts/tron"],
  });
}

interface TrustedDirectoryAdmission {
  subject: string;
  markers?: string[];
}

export async function admitTrustedDirectory(value: unknown, admission: TrustedDirectoryAdmission): Promise<string> {
  if (typeof value !== "string" || !isAbsolute(value) || Buffer.byteLength(value) > MAX_PATH_BYTES
    || CONTROL_CHARACTERS.test(value)) {
    throw new GatewayError("invalid_request", `${admission.subject} must be an absolute path`);
  }
  const subject = `${admission.subject} ${JSON.stringify(value)}`;
  const root = parse(value).root;
  let cursor = root;
  for (const component of value.slice(root.length).split(/[\\/]+/u).filter(Boolean)) {
    cursor = join(cursor, component);
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
      throw new GatewayError("conflict", `${subject} is not a Tron repository (missing or linked marker: ${marker})`);
    }
  }
  return resolved;
}
