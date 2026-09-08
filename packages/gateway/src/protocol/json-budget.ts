/** Dynamic JSON node ceiling shared with iOS JSONValueDecodingLimits.gateway.
 * Count encoded values, not object keys. Normally undefined object members are
 * omitted; projection fitting counts them as null because safeJson materializes
 * them later. Callers pass plain JSON-compatible projections, never canonical
 * objects or objects with custom toJSON serialization.
 */
export const GATEWAY_JSON_MAXIMUM_NODES = 32_768;

export function jsonNodeCount(value: unknown, stopAfter = GATEWAY_JSON_MAXIMUM_NODES, undefinedAsNull = false): number {
  const pending = [value];
  let nodes = 0;
  while (pending.length > 0) {
    const current = pending.pop();
    if (++nodes > stopAfter) return nodes;
    if (Array.isArray(current)) {
      if (nodes + pending.length + current.length > stopAfter) return stopAfter + 1;
      for (const member of current) pending.push(member);
    } else if (current !== null && typeof current === "object") {
      for (const member of Object.values(current)) {
        if (undefinedAsNull || member !== undefined) pending.push(member);
        if (nodes + pending.length > stopAfter) return stopAfter + 1;
      }
    }
  }
  return nodes;
}
