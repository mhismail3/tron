export const GATEWAY_VERSION = "0.1.0-beta.8";
// Protocol v8 replaces the per-setting RPCs with settings.change (#762). There
// is no v7 runtime path: an older client is refused with the typed mismatch
// close, which names the side to update, instead of failing on removed RPCs.
export const PROTOCOL_VERSION = 8;
export const MIN_PROTOCOL_VERSION = 8;
// Application-defined close code for a hello whose protocol the peer cannot
// speak. The version range it names travels in the close reason, so every
// client that decodes the code can name the stale side (mirrors iOS
// `GatewayProtocolMismatchClose.closeCode`). It lives beside the protocol
// version because the Gateway transport and the terminal client both refuse and
// read it, and server.ts cannot be imported from a client process.
export const PROTOCOL_MISMATCH_CLOSE_CODE = 4006;
