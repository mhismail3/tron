import { createHash } from "node:crypto";
import { GatewayError } from "../errors.js";

export interface CatalogPage<T> {
  items: T[];
  nextCursor?: string;
}

export const MODEL_CATALOG_MAX_ITEMS = 25_000;
export const MODEL_CATALOG_MAX_ENCODED_BYTES = 16 * 1_048_576;
export const MODEL_CATALOG_PAGE_ENCODED_BYTES = 800_000;
const MODEL_CATALOG_LEASE_TTL_MS = 30_000;
const MODEL_CATALOG_LEASES_PER_OWNER = 4;
const MODEL_CATALOG_GLOBAL_LEASES = 8;
const CURSOR_PATTERN = /^([0-9a-f]{64}):(0|[1-9][0-9]*)$/;

interface PreparedCatalog<T> {
  items: readonly T[];
  itemEncodedBytes: readonly number[];
  fingerprint: string;
}

interface StoredCatalog {
  catalog: PreparedCatalog<unknown>;
  expiresAt: number;
  access: number;
}

/** Connection-runtime-local immutable model traversals avoid repeated whole-catalog work. */
export class ModelCatalogPager {
  private readonly byOwner = new Map<object, Map<string, StoredCatalog>>();
  private access = 0;

  async page<T>(
    owner: object,
    rawCursor: unknown,
    rawLimit: unknown,
    build: () => Promise<readonly T[]>,
  ): Promise<CatalogPage<T>> {
    const limit = catalogPageLimit(rawLimit);
    const now = Date.now();
    const stored = this.liveCatalogs(owner, now);
    let catalog: PreparedCatalog<T>;
    if (rawCursor === undefined) {
      catalog = prepareCatalog(await build());
      this.access += 1;
      stored.set(catalog.fingerprint, {
        catalog: catalog as PreparedCatalog<unknown>,
        expiresAt: now + MODEL_CATALOG_LEASE_TTL_MS,
        access: this.access,
      });
      this.evictOwnerOverflow(stored);
      this.evictGlobalOverflow();
    } else {
      const fingerprint = cursorFingerprint(rawCursor);
      const entry = stored.get(fingerprint);
      if (!entry) {
        throw new GatewayError("conflict", "Model catalog cursor expired; restart the listing", true);
      }
      this.access += 1;
      entry.access = this.access;
      entry.expiresAt = now + MODEL_CATALOG_LEASE_TTL_MS;
      catalog = entry.catalog as PreparedCatalog<T>;
    }
    return pagePreparedCatalog(catalog, rawCursor, limit);
  }

  private liveCatalogs(owner: object, now: number): Map<string, StoredCatalog> {
    for (const [candidateOwner, catalogs] of this.byOwner) {
      for (const [fingerprint, entry] of catalogs) {
        if (entry.expiresAt <= now) catalogs.delete(fingerprint);
      }
      if (catalogs.size === 0) this.byOwner.delete(candidateOwner);
    }
    const stored = this.byOwner.get(owner) ?? new Map<string, StoredCatalog>();
    this.byOwner.set(owner, stored);
    return stored;
  }

  private evictOwnerOverflow(stored: Map<string, StoredCatalog>): void {
    while (stored.size > MODEL_CATALOG_LEASES_PER_OWNER) {
      const oldest = [...stored].sort((left, right) => left[1].access - right[1].access)[0]?.[0];
      if (!oldest) return;
      stored.delete(oldest);
    }
  }

  private evictGlobalOverflow(): void {
    while ([...this.byOwner.values()].reduce((total, catalogs) => total + catalogs.size, 0)
      > MODEL_CATALOG_GLOBAL_LEASES) {
      let oldest: { owner: object; fingerprint: string; access: number } | undefined;
      for (const [owner, catalogs] of this.byOwner) {
        for (const [fingerprint, entry] of catalogs) {
          if (!oldest || entry.access < oldest.access) oldest = { owner, fingerprint, access: entry.access };
        }
      }
      if (!oldest) return;
      const catalogs = this.byOwner.get(oldest.owner);
      catalogs?.delete(oldest.fingerprint);
      if (catalogs?.size === 0) this.byOwner.delete(oldest.owner);
    }
  }
}

/** Stateless helper retained for focused policy tests and non-runtime callers. */
export function pageCatalog<T>(items: readonly T[], rawCursor: unknown, rawLimit: unknown): CatalogPage<T> {
  const limit = catalogPageLimit(rawLimit);
  return pagePreparedCatalog(prepareCatalog(items), rawCursor, limit);
}

function prepareCatalog<T>(items: readonly T[]): PreparedCatalog<T> {
  if (items.length > MODEL_CATALOG_MAX_ITEMS) {
    throw new GatewayError("conflict", "Model catalog exceeds the item limit");
  }
  const hash = createHash("sha256");
  const itemEncodedBytes: number[] = [];
  let encodedBytes = 0;
  for (const item of items) {
    const encoded = JSON.stringify(item);
    if (encoded === undefined) {
      throw new GatewayError("invalid_request", "Model catalog contains an unsupported value");
    }
    const bytes = Buffer.byteLength(encoded);
    if (bytes > MODEL_CATALOG_PAGE_ENCODED_BYTES) {
      throw new GatewayError("conflict", "One model exceeds the page byte limit");
    }
    if (bytes > MODEL_CATALOG_MAX_ENCODED_BYTES - encodedBytes) {
      throw new GatewayError("conflict", "Model catalog exceeds the encoded byte limit");
    }
    encodedBytes += bytes;
    itemEncodedBytes.push(bytes);
    hash.update(String(bytes));
    hash.update(":");
    hash.update(encoded);
  }
  return { items, itemEncodedBytes, fingerprint: hash.digest("hex") };
}

function pagePreparedCatalog<T>(
  catalog: PreparedCatalog<T>,
  rawCursor: unknown,
  limit: number,
): CatalogPage<T> {
  const cursor = parseCursor(rawCursor, catalog.fingerprint, catalog.items.length);
  let end = cursor;
  let pageBytes = 2;
  while (end < catalog.items.length && end - cursor < limit) {
    const nextBytes = catalog.itemEncodedBytes[end]! + (end === cursor ? 0 : 1);
    if (nextBytes > MODEL_CATALOG_PAGE_ENCODED_BYTES - pageBytes) break;
    pageBytes += nextBytes;
    end += 1;
  }
  if (end === cursor && cursor < catalog.items.length) {
    throw new GatewayError("conflict", "One model exceeds the page byte limit");
  }
  return {
    items: catalog.items.slice(cursor, end),
    ...(end < catalog.items.length ? { nextCursor: `${catalog.fingerprint}:${end}` } : {}),
  };
}

function catalogPageLimit(rawLimit: unknown): number {
  const limit = rawLimit === undefined ? 200 : Number(rawLimit);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500) {
    throw new GatewayError("invalid_request", "limit must be between 1 and 500");
  }
  return limit;
}

function cursorFingerprint(rawCursor: unknown): string {
  if (typeof rawCursor !== "string") {
    throw new GatewayError("invalid_request", "cursor must be an opaque model catalog cursor");
  }
  const match = CURSOR_PATTERN.exec(rawCursor);
  if (!match) throw new GatewayError("invalid_request", "cursor must be an opaque model catalog cursor");
  return match[1]!;
}

function parseCursor(rawCursor: unknown, fingerprint: string, itemCount: number): number {
  if (rawCursor === undefined) return 0;
  const match = CURSOR_PATTERN.exec(typeof rawCursor === "string" ? rawCursor : "");
  const offset = match ? Number(match[2]) : Number.NaN;
  if (!match || !Number.isSafeInteger(offset) || offset < 0 || offset >= itemCount) {
    throw new GatewayError("invalid_request", "cursor must be an opaque model catalog cursor");
  }
  if (match[1] !== fingerprint) {
    throw new GatewayError("conflict", "Model catalog changed during pagination; restart the listing", true);
  }
  return offset;
}
