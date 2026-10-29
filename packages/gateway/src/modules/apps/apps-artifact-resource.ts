import { GatewayError } from "../../errors.js";

/** One address contract, shared by the projection producer and HTTP adapter. */
export function appArtifactPath(id: string, revision: string): string {
  return `/v1/apps/${encodeURIComponent(id)}/artifacts/${encodeURIComponent(revision)}`;
}
export function parseAppArtifactPath(path: string): { id: string; revision: string } | undefined {
  const match = /^\/v1\/apps\/([^/]+)\/artifacts\/([^/]+)$/.exec(path);
  if (!match) return;
  try { return { id: decodeURIComponent(match[1]!), revision: decodeURIComponent(match[2]!) }; }
  catch { throw new GatewayError("invalid_request", "Invalid app artifact address"); }
}
