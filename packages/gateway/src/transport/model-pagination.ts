import { GatewayError } from "../errors.js";

export interface CatalogPage<T> {
  items: T[];
  nextCursor?: string;
}

/** Bounds model discovery independently of the generic JSON safety projector. */
export function pageCatalog<T>(items: readonly T[], rawCursor: unknown, rawLimit: unknown): CatalogPage<T> {
  const cursor = rawCursor === undefined ? 0 : Number(rawCursor);
  const limit = rawLimit === undefined ? 200 : Number(rawLimit);
  if (!Number.isSafeInteger(cursor) || cursor < 0) {
    throw new GatewayError("invalid_request", "cursor must be a non-negative integer");
  }
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500) {
    throw new GatewayError("invalid_request", "limit must be between 1 and 500");
  }
  const page = items.slice(cursor, cursor + limit);
  const next = cursor + page.length;
  return {
    items: page,
    ...(next < items.length ? { nextCursor: String(next) } : {}),
  };
}
