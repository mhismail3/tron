/** One live runtime in the sample: its canonical transcript size is the byte
 * estimate of what it holds until runtime residency is measured directly. */
export interface ResourceRuntimeEntry {
  sessionId: string;
  bytes: number;
  subscribers: number;
}

/**
 * What the owners of measurable work report to the sampler. Each call counts
 * one occurrence at the site that already knows it; the sampler never scans to
 * discover what happened.
 */
export interface ResourceRecorder {
  /** One serialized frame offered on a topic, and the recipients it had. */
  recordTopicFrame(topic: string, bytes: number, subscribers: number): void;
  /** One catalog walk, with the time it took, the files it read, and whether a
   * request was waiting on it. */
  recordCatalogWalk(durationMs: number, files: number, requestPath?: boolean): void;
  recordOutboundBytes(bytes: number): void;
  /** One superseded frame dropped in a connection's outbound queue, with the
   * encoded bytes it would have sent: the state G-4 kept off a slow link. */
  recordOutboundCoalesced(bytes: number): void;
  /** One runtime that became live, counted where it is published: a load and an
   * eviction inside one window are otherwise invisible to a set comparison. */
  recordRuntimeLoaded(): void;
  /** One published runtime that was disposed, counted at its disposal; a start
   * that was retired before it was ever live is not an eviction. */
  recordRuntimeEvicted(): void;
}
