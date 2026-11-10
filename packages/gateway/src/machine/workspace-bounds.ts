import { GatewayError } from "../errors.js";

export const WORKSPACE_MAXIMUM_ENTRIES = 1_000;
export const WORKSPACE_MAXIMUM_PROJECTED_BYTES = 768 * 1_024;

export async function projectBoundedEntries<T>(
  candidates: Iterable<T | undefined> | AsyncIterable<T | undefined>,
  maximumProjectedBytes: number,
  overflow: { message: string; retryable: boolean },
): Promise<T[]> {
  const projected: T[] = [];
  let projectedBytes = 2;
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
