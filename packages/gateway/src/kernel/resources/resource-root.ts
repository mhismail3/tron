export interface TronWorkspaceDescriptor {
  root: string;
  available: boolean;
  reason?: "unavailable" | "owned_elsewhere" | "closed";
}

/** The actual root owner at the kernel start, context-read and required-dispose cuts. */
export interface ResourceRoot {
  initialize(): Promise<void>;
  describe(): Promise<TronWorkspaceDescriptor>;
  dispose(): Promise<void>;
}
