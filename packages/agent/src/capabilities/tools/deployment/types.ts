/**
 * @fileoverview Deployment tool types
 *
 * Types for self-deployment tools.
 */

import type { DeploymentStatus } from '@platform/deployment/types.js';

/**
 * Parameters for deploy_tron tool
 */
export interface DeployToolParams {
  /** Target environment to deploy to */
  target: 'beta' | 'prod';
  /** Whether to run tests before deploying */
  runTests?: boolean;
  /** Whether to require manual approval before swap */
  requireApproval?: boolean;
  /** Whether to automatically rollback on failure */
  autoRollbackOnFailure?: boolean;
}

/**
 * Result of deploy_tron tool
 */
export interface DeployToolResult {
  /** Whether the deployment succeeded */
  success: boolean;
  /** Deployment ID for tracking */
  deploymentId: string;
  /** Current status of the deployment */
  status: DeploymentStatus;
  /** Timestamp when deployment started */
  startedAt: string;
  /** Timestamp when deployment completed (if finished) */
  completedAt?: string;
  /** Error details if failed */
  error?: string;
}

/**
 * Parameters for check_deployment tool
 */
export interface CheckDeploymentParams {
  /** Optional deployment ID to check (defaults to current/latest) */
  deploymentId?: string;
}

/**
 * Result of check_deployment tool
 */
export interface CheckDeploymentResult {
  /** Whether there is an active deployment */
  hasActiveDeployment: boolean;
  /** Current deployment details (if any) */
  currentDeployment?: {
    id: string;
    status: DeploymentStatus;
    startedAt: string;
    completedAt?: string;
    error?: string;
  };
  /** Last successful deployment (if any) */
  lastSuccessful?: {
    id: string;
    startedAt: string;
    completedAt?: string;
    version?: string;
  };
  /** Health status of deployment targets */
  health: {
    beta?: {
      healthy: boolean;
      lastCheck: string;
      version?: string;
      error?: string;
    };
    prod?: {
      healthy: boolean;
      lastCheck: string;
      version?: string;
      error?: string;
    };
  };
}
