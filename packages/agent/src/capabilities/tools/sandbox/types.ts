/**
 * @fileoverview Sandbox types
 *
 * Interfaces for the container-based sandbox system:
 * - Container records persisted in the registry
 * - Runner execution results
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

