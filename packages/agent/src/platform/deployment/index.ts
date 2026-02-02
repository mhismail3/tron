/**
 * @fileoverview Self-deployment module exports
 *
 * Provides infrastructure for agents to deploy changes to Tron:
 * - DeploymentController: Orchestrates the deployment pipeline
 * - HealthChecker: Verifies service health during deployment
 *
 * @example
 * ```typescript
 * import { createDeploymentController } from '@tron/agent/deployment';
 *
 * const controller = createDeploymentController({
 *   projectRoot: '/path/to/tron'
 * });
 *
 * // Deploy to beta
 * const result = await controller.deploy({
 *   source: 'current',
 *   target: 'beta',
 *   runTests: true,
 *   requireApproval: false,
 *   autoRollbackOnFailure: true
 * });
 *
 * // Check production health
 * const health = await controller.healthCheck('prod');
 * ```
 */

export * from './types.js';
export * from './health-checker.js';
export * from './controller.js';
