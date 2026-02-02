/**
 * @fileoverview Deployment module types
 *
 * Types for the self-deployment pipeline that allows
 * agents to deploy changes to the Tron server.
 */

/**
 * Deployment target environment
 */
export type DeploymentTarget = 'beta' | 'prod';

/**
 * Deployment source
 */
export type DeploymentSource = 'current' | 'beta';

/**
 * Deployment status
 */
export type DeploymentStatus =
  | 'idle'
  | 'building'
  | 'testing'
  | 'starting_beta'
  | 'awaiting_approval'
  | 'swapping'
  | 'verifying'
  | 'completed'
  | 'failed'
  | 'rolled_back';

/**
 * Health check result
 */
export interface HealthResult {
  /** Whether the service is healthy */
  healthy: boolean;
  /** Service version */
  version?: string;
  /** Response time in ms */
  responseTimeMs?: number;
  /** Error message if unhealthy */
  error?: string;
  /** Additional status info */
  details?: Record<string, unknown>;
}

/**
 * Deployment options
 */
export interface DeployOptions {
  /** Source of the deployment */
  source: DeploymentSource;
  /** Target environment */
  target: DeploymentTarget;
  /** Whether to run tests before deploying */
  runTests: boolean;
  /** Whether to require manual approval before swap */
  requireApproval: boolean;
  /** Whether to automatically rollback on failure */
  autoRollbackOnFailure: boolean;
  /** Optional commit message for the deployment */
  commitMessage?: string;
}

/**
 * Deployment result
 */
export interface DeploymentResult {
  /** Whether the deployment succeeded */
  success: boolean;
  /** Deployment ID for tracking */
  deploymentId: string;
  /** Current status */
  status: DeploymentStatus;
  /** Timestamp when deployment started */
  startedAt: string;
  /** Timestamp when deployment completed (if finished) */
  completedAt?: string;
  /** Error message if failed */
  error?: string;
  /** Build output */
  buildOutput?: string;
  /** Test output */
  testOutput?: string;
  /** Previous version (for rollback) */
  previousVersion?: string;
  /** New version */
  newVersion?: string;
}

/**
 * Deployment state
 */
export interface DeploymentState {
  /** Current deployment (if any) */
  current: DeploymentResult | null;
  /** Last successful deployment */
  lastSuccessful: DeploymentResult | null;
  /** Deployment history (most recent first) */
  history: DeploymentResult[];
}

/**
 * Deployment controller interface
 */
export interface DeploymentController {
  /**
   * Trigger a new deployment
   */
  deploy(options: DeployOptions): Promise<DeploymentResult>;

  /**
   * Get current deployment status
   */
  getStatus(): DeploymentState;

  /**
   * Approve a pending deployment
   */
  approve(deploymentId: string): Promise<DeploymentResult>;

  /**
   * Rollback to previous version
   */
  rollback(): Promise<DeploymentResult>;

  /**
   * Health check a target environment
   */
  healthCheck(target: DeploymentTarget): Promise<HealthResult>;

  /**
   * Cancel an in-progress deployment
   */
  cancel(deploymentId: string): Promise<boolean>;
}

/**
 * Configuration for the deployment controller
 */
export interface DeploymentControllerConfig {
  /** Path to the Tron project root */
  projectRoot: string;
  /** Beta server port */
  betaPort?: number;
  /** Beta health port */
  betaHealthPort?: number;
  /** Production server port */
  prodPort?: number;
  /** Production health port */
  prodHealthPort?: number;
  /** Health check timeout in ms */
  healthCheckTimeoutMs?: number;
  /** Maximum deployment history to keep */
  maxHistoryEntries?: number;
}

/**
 * Default deployment configuration
 */
export const DEFAULT_DEPLOYMENT_CONFIG: Required<Omit<DeploymentControllerConfig, 'projectRoot'>> = {
  betaPort: 8082,
  betaHealthPort: 8083,
  prodPort: 8080,
  prodHealthPort: 8081,
  healthCheckTimeoutMs: 10000,
  maxHistoryEntries: 50,
};
