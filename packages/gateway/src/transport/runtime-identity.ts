export interface GatewayRuntimeIdentity {
  sourceRevision?: string;
  buildFingerprint?: string;
  runtimeEpoch?: string;
}

const MAX_IDENTITY_BYTES = 256;

function optionalIdentity(value: string | undefined): string | undefined {
  if (!value) return undefined;
  if (Buffer.byteLength(value) > MAX_IDENTITY_BYTES || /[\u0000-\u001f\u007f]/u.test(value)) return undefined;
  return value;
}

/** Optional provenance is supplied by the owning isolated supervisor. */
export function runtimeIdentity(environment: NodeJS.ProcessEnv = process.env): GatewayRuntimeIdentity {
  const result: GatewayRuntimeIdentity = {};
  const sourceRevision = optionalIdentity(environment.TRON_GATEWAY_SOURCE_REVISION);
  const buildFingerprint = optionalIdentity(environment.TRON_GATEWAY_BUILD_FINGERPRINT);
  const runtimeEpoch = optionalIdentity(environment.TRON_GATEWAY_RUNTIME_EPOCH);
  if (sourceRevision !== undefined) result.sourceRevision = sourceRevision;
  if (buildFingerprint !== undefined) result.buildFingerprint = buildFingerprint;
  if (runtimeEpoch !== undefined) result.runtimeEpoch = runtimeEpoch;
  return result;
}
