export const GATEWAY_VERSION = "0.1.0-beta.7";
// Protocol v3 is the first wire version that carries the v2 extension
// presentation aggregate. Keep the minimum at v3: a v2 peer can complete a
// hello exchange but cannot decode the required presentation projection.
export const PROTOCOL_VERSION = 3;
export const MIN_PROTOCOL_VERSION = 3;
export const PI_VERSION = "0.84.1";
