/**
 * @fileoverview Deployment domain - Self-deployment pipeline
 *
 * Provides RPC handlers for deployment operations.
 *
 * @see src/deployment/ for the underlying deployment controller implementation
 */

// Re-export deployment types and factory
export {
  type DeploymentController,
  type DeploymentControllerConfig,
  type DeployOptions,
  type DeploymentResult,
  type DeploymentStatus,
  type DeploymentState,
  type DeploymentTarget,
  type DeploymentSource,
  type HealthResult,
  TronDeploymentController,
  createDeploymentController,
  DEFAULT_DEPLOYMENT_CONFIG,
} from '@platform/deployment/index.js';

// Re-export health checker
export {
  HealthChecker,
  createHealthChecker,
} from '@platform/deployment/health-checker.js';
