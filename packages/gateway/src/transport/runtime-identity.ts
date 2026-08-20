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
  return {
    ...(optionalIdentity(environment.TRON_GATEWAY_SOURCE_REVISION) ? { sourceRevision: environment.TRON_GATEWAY_SOURCE_REVISION } : {}),
    ...(optionalIdentity(environment.TRON_GATEWAY_BUILD_FINGERPRINT) ? { buildFingerprint: environment.TRON_GATEWAY_BUILD_FINGERPRINT } : {}),
    ...(optionalIdentity(environment.TRON_GATEWAY_RUNTIME_EPOCH) ? { runtimeEpoch: environment.TRON_GATEWAY_RUNTIME_EPOCH } : {}),
  };
}
