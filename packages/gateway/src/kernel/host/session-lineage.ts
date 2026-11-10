import type { FileEntry, SessionManager } from "../pi/coding-agent.js";

export interface SessionLineageState {
  sessionId: string;
  sealed: boolean;
  materializing?: boolean;
  lineageId?: string;
  ordinal?: number;
  attemptId?: string;
  expectedPath?: string;
}

export interface SessionLineagePolicy {
  state(sessionId: string): SessionLineageState;
  openRefusal(sessionId: string, path: string): Promise<Error | undefined>;
  assertWritable(sessionId: string): void;
  identityRefusal(sessionId: string): Error;
  publicationUncertain(): boolean;
}

export interface LineageRuntimePort<Runtime> {
  materializeRuntime(sessionId: string, construct: () => Promise<Runtime>): Promise<{ slot: Runtime; existing: boolean }>;
  liveRuntime(sessionId: string): Runtime | undefined;
  orderedRuntime(sessionId: string): Promise<Runtime | undefined>;
  sessionDirectory(cwd: string): string;
  canonicalEntries(sessionId: string): Promise<{ entries: readonly FileEntry[] | null; live: boolean }>;
  createRuntimeOver(sessionId: string, build: {
    profile: string;
    prepare(): Promise<SessionManager>;
    authority(): object;
    admitted(slot: Runtime): void;
    published(slot: Runtime): Promise<void>;
    failed(): void;
  }): Promise<Runtime>;
}

