export interface ResourceRuntimeEntry {
  sessionId: string;
  bytes: number;
  subscribers: number;
}

export interface ResourceRecorder {
  recordTopicFrame(topic: string, bytes: number, subscribers: number): void;
  recordCatalogWalk(durationMs: number, files: number, requestPath?: boolean): void;
  recordOutboundBytes(bytes: number): void;
  recordOutboundCoalesced(bytes: number): void;
  recordRuntimeLoaded(): void;
  recordRuntimeEvicted(): void;
}
