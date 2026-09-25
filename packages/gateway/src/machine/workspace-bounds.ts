import { GatewayError } from "../errors.js";

/** One ceiling for both workspace listing surfaces: `filesystem.list` and
 * `session.workspace.list` fail visibly above 1,000 examined entries or 768 KiB
 * of projected metadata rather than returning a partial listing. */
export const WORKSPACE_MAXIMUM_ENTRIES = 1_000;
export const WORKSPACE_MAXIMUM_PROJECTED_BYTES = 768 * 1_024;

/** Projects candidate entries under one encoded-metadata ceiling.
 *
 * Each candidate costs its JSON encoding plus the separating comma. A candidate
 * that would cross the ceiling rejects the whole listing, so no caller can
 * publish a partial one, and candidates stream, so a caller's entry ceiling
 * still applies while its directory is being read. Callers keep their own
 * message and retryability because the two surfaces report the same ceiling
 * differently. */
export async function projectBoundedEntries<T>(
  candidates: Iterable<T | undefined> | AsyncIterable<T | undefined>,
  maximumProjectedBytes: number,
  overflow: { message: string; retryable: boolean },
): Promise<T[]> {
  const projected: T[] = [];
  let projectedBytes = 2; // The enclosing JSON array brackets.
  for await (const candidate of candidates) {
    if (!candidate) continue;
    const candidateBytes = Buffer.byteLength(JSON.stringify(candidate)) + 1;
    if (candidateBytes > maximumProjectedBytes - projectedBytes) {
      throw new GatewayError("conflict", overflow.message, overflow.retryable);
    }
    projected.push(candidate);
    projectedBytes += candidateBytes;
  }
  return projected;
}
