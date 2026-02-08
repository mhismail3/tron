/**
 * @fileoverview Sandbox tool types
 *
 * Interfaces for the container-based sandbox system:
 * - Container records persisted in the registry
 * - Runner execution results
 * - Tool parameter types
 */

// =============================================================================
// Container Registry Types
// =============================================================================

export interface ContainerRecord {
  name: string;
  image: string;
  createdAt: string;
  createdBySession: string;
  workingDirectory: string;
  ports: string[];
  purpose?: string;
}

export interface ContainerRegistryFile {
  containers: ContainerRecord[];
}

// =============================================================================
// Container Runner Types
// =============================================================================

export interface ContainerRunResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  interrupted?: boolean;
}

// =============================================================================
// Tool Parameter Types
// =============================================================================

export type SandboxAction = 'create' | 'exec' | 'stop' | 'start' | 'remove' | 'list' | 'logs';

export interface SandboxParams {
  action: SandboxAction;
  name?: string;
  image?: string;
  command?: string;
  cpus?: number;
  memory?: string;
  ports?: string[];
  env?: string[];
  volumes?: string[];
  workdir?: string;
  timeout?: number;
  detach?: boolean;
  tail?: number;
  purpose?: string;
}

// =============================================================================
// Tool Config
// =============================================================================

export interface SandboxToolConfig {
  sessionId: string;
  workingDirectory: string;
  tronHome: string;
}
