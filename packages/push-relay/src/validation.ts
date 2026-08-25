import {
  MAX_MESSAGE_BYTES,
  MAX_TITLE_BYTES,
  ROUTES,
  type InstallationRegistration,
  type NotificationRequest,
  type PushRoute,
} from "./contracts";
import { utf8 } from "./crypto";

const OPAQUE_ID = /^[A-Za-z0-9_-]{16,128}$/;
const SESSION_ROUTE_ID = /^[A-Za-z0-9_:-]{1,160}$/;
const KEY_ID = /^[A-Za-z0-9_-]{32,128}$/;
const HASH = /^[0-9a-f]{64}$/;
const APNS_TOKEN = /^(?:[0-9a-f]{2}){1,256}$/;
const BASE64URL = /^[A-Za-z0-9_-]{16,16384}$/;

export function validateRegistration(value: unknown):
  | { ok: true; value: InstallationRegistration }
  | { ok: false; error: string } {
  if (!isRecord(value) || (value.proof !== "attestation" && value.proof !== "assertion")) {
    return { ok: false, error: "invalid_proof" };
  }
  const proofField = value.proof === "attestation" ? "attestationObject" : "assertionObject";
  const allowed = [
    "version", "proof", "challengeId", "challenge", "keyId", "apnsToken", "route", "bindingHash", proofField,
  ];
  if (Object.keys(value).some((key) => !allowed.includes(key))) {
    return { ok: false, error: "unknown_field" };
  }
  if (
    value.version !== 1 ||
    !isOpaqueId(value.challengeId) ||
    typeof value.challenge !== "string" || !BASE64URL.test(value.challenge) ||
    typeof value.keyId !== "string" || !KEY_ID.test(value.keyId) ||
    typeof value.apnsToken !== "string" || !APNS_TOKEN.test(value.apnsToken) || value.apnsToken !== value.apnsToken.toLowerCase() ||
    !isPushRoute(value.route) ||
    typeof value.bindingHash !== "string" || !HASH.test(value.bindingHash) ||
    typeof value[proofField] !== "string" || !BASE64URL.test(value[proofField])
  ) {
    return { ok: false, error: "invalid_registration" };
  }
  return { ok: true, value: value as unknown as InstallationRegistration };
}

export function validateNotification(value: unknown, now = Date.now()):
  | { ok: true; value: NotificationRequest }
  | { ok: false; error: string } {
  if (!isRecord(value)) return { ok: false, error: "invalid_request" };
  const allowed = ["version", "kind", "requestId", "message", "title", "sessionId", "machineId", "expiresAt"];
  if (Object.keys(value).some((key) => !allowed.includes(key))) {
    return { ok: false, error: "unknown_field" };
  }
  const expiration = typeof value.expiresAt === "string" ? Date.parse(value.expiresAt) : Number.NaN;
  const hasSessionId = value.sessionId !== undefined;
  const hasMachineId = value.machineId !== undefined;
  if (
    value.version !== 1 || value.kind !== "agent_alert" ||
    !isOpaqueId(value.requestId) ||
    typeof value.message !== "string" || value.message.length < 1 || utf8(value.message).byteLength > MAX_MESSAGE_BYTES ||
    (value.title !== undefined && (typeof value.title !== "string" || value.title.length < 1 || utf8(value.title).byteLength > MAX_TITLE_BYTES)) ||
    hasSessionId !== hasMachineId ||
    (hasSessionId && (!isSessionRouteId(value.sessionId) || !isMachineRouteId(value.machineId))) ||
    !Number.isFinite(expiration) || expiration < now - 60_000 || expiration > now + 24 * 60 * 60 * 1000
  ) {
    return { ok: false, error: "invalid_request" };
  }
  return { ok: true, value: value as unknown as NotificationRequest };
}

export function isOpaqueId(value: unknown): value is string {
  return typeof value === "string" && OPAQUE_ID.test(value);
}

function isSessionRouteId(value: unknown): value is string {
  return typeof value === "string" && SESSION_ROUTE_ID.test(value);
}

function isMachineRouteId(value: unknown): value is string {
  return typeof value === "string" && utf8(value).byteLength > 0 && utf8(value).byteLength <= 256
    && !/[\u0000-\u001f\u007f]/.test(value);
}

export function isPushRoute(value: unknown): value is PushRoute {
  return typeof value === "string" && Object.hasOwn(ROUTES, value);
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
