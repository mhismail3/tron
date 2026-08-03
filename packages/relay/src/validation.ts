import type {
  AlertRequest,
  BackgroundRequest,
  Environment,
  NotificationRequest,
} from "./contracts";

const DEVICE_TOKEN = /^[0-9a-f]{32,200}$/i;
const OPAQUE_ID = /^[A-Za-z0-9._:-]{1,128}$/;
const TOPIC_ENVIRONMENTS: Readonly<Record<string, readonly Environment[]>> = {
  "com.tron.mobile.beta": ["sandbox"],
  "com.tron.mobile": ["sandbox", "production"],
};

export function validateNotificationRequest(
  value: unknown,
):
  | { ok: true; value: NotificationRequest }
  | { ok: false; error: string } {
  if (!isRecord(value) || (value.kind !== "alert" && value.kind !== "background")) {
    return { ok: false, error: "invalid_kind" };
  }
  const common = [
    "kind",
    "requestId",
    "deviceToken",
    "topic",
    "environment",
    "expiresAt",
    "collapseId",
    "badge",
    "serverId",
  ];
  const allowed =
    value.kind === "alert"
      ? [...common, "title", "body", "threadKey", "category", "deliveryId"]
      : common;
  if (Object.keys(value).some((key) => !allowed.includes(key))) {
    return { ok: false, error: "unknown_field" };
  }
  if (
    !isOpaqueId(value.requestId) ||
    typeof value.deviceToken !== "string" ||
    !DEVICE_TOKEN.test(value.deviceToken) ||
    typeof value.topic !== "string" ||
    (value.environment !== "sandbox" && value.environment !== "production") ||
    !TOPIC_ENVIRONMENTS[value.topic]?.includes(value.environment) ||
    !validFutureDate(value.expiresAt) ||
    !isBoundedString(value.collapseId, 1, 64) ||
    !Number.isSafeInteger(value.badge) ||
    (value.badge as number) < 0 ||
    (value.badge as number) > 9999 ||
    !isOpaqueId(value.serverId)
  ) {
    return { ok: false, error: "invalid_request" };
  }
  if (value.kind === "background") {
    return { ok: true, value: value as unknown as BackgroundRequest };
  }
  if (
    !isBoundedString(value.title, 1, 120) ||
    !isBoundedString(value.body, 1, 512) ||
    (value.threadKey !== undefined &&
      !isBoundedString(value.threadKey, 1, 64)) ||
    (value.category !== "TRON_NOTIFICATION" &&
      value.category !== "TRON_REMINDER") ||
    !isOpaqueId(value.deliveryId)
  ) {
    return { ok: false, error: "invalid_alert" };
  }
  return { ok: true, value: value as unknown as AlertRequest };
}

export function isOpaqueId(value: unknown): value is string {
  return typeof value === "string" && OPAQUE_ID.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isBoundedString(
  value: unknown,
  minimum: number,
  maximum: number,
): value is string {
  return (
    typeof value === "string" &&
    value.length >= minimum &&
    value.length <= maximum
  );
}

function validFutureDate(value: unknown): boolean {
  if (typeof value !== "string") return false;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && timestamp > Date.now() - 60_000;
}
