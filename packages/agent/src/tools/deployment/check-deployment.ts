/**
 * @fileoverview Check Deployment Tool
 *
 * Allows agents to check the status of deployments and server health.
 */

import type { TronTool, TronToolResult } from '../../types/index.js';
import type { DeploymentController } from '../../deployment/types.js';
import { HealthChecker } from '../../deployment/health-checker.js';
import type { CheckDeploymentParams, CheckDeploymentResult } from './types.js';
import { createLogger } from '../../logging/index.js';

const logger = createLogger('tool:check-deployment');

/**
 * Configuration for CheckDeploymentTool
 */
export interface CheckDeploymentToolConfig {
  /** Deployment controller instance */
  deploymentController: DeploymentController;
  /** Health checker instance */
  healthChecker: HealthChecker;
}

/**
 * Tool for checking deployment status and health
 */
export class CheckDeploymentTool implements TronTool<CheckDeploymentParams, CheckDeploymentResult> {
  readonly name = 'check_deployment';
  readonly description =
    'Check the status of a deployment and the health of deployed servers.';

  readonly parameters = {
    type: 'object' as const,
    properties: {
      deploymentId: {
        type: 'string' as const,
        description: 'Specific deployment ID to check (defaults to current/latest)',
      },
    },
    required: [] as string[],
  };

  private config: CheckDeploymentToolConfig;

  constructor(config: CheckDeploymentToolConfig) {
    this.config = config;
  }

  async execute(_params: CheckDeploymentParams): Promise<TronToolResult<CheckDeploymentResult>> {
    try {
      // Get deployment state
      const state = this.config.deploymentController.getStatus();

      // Get health status for both environments
      const [betaHealth, prodHealth] = await Promise.all([
        this.config.healthChecker.check('beta').catch((e) => ({
          healthy: false,
          error: e instanceof Error ? e.message : 'Health check failed',
          version: undefined as string | undefined,
        })),
        this.config.healthChecker.check('prod').catch((e) => ({
          healthy: false,
          error: e instanceof Error ? e.message : 'Health check failed',
          version: undefined as string | undefined,
        })),
      ]);

      const now = new Date().toISOString();

      // Determine if there's an active deployment (not completed, failed, or rolled back)
      const isActive = state.current !== null &&
        !['completed', 'failed', 'rolled_back'].includes(state.current.status);

      const result: CheckDeploymentResult = {
        hasActiveDeployment: isActive,
        health: {
          beta: {
            healthy: betaHealth.healthy,
            lastCheck: now,
            version: betaHealth.version,
            error: betaHealth.error,
          },
          prod: {
            healthy: prodHealth.healthy,
            lastCheck: now,
            version: prodHealth.version,
            error: prodHealth.error,
          },
        },
      };

      // Add current deployment details if any
      if (state.current) {
        result.currentDeployment = {
          id: state.current.deploymentId,
          status: state.current.status,
          startedAt: state.current.startedAt,
          completedAt: state.current.completedAt,
          error: state.current.error,
        };
      }

      // Add last successful deployment if any
      if (state.lastSuccessful) {
        result.lastSuccessful = {
          id: state.lastSuccessful.deploymentId,
          startedAt: state.lastSuccessful.startedAt,
          completedAt: state.lastSuccessful.completedAt,
          version: state.lastSuccessful.newVersion,
        };
      }

      logger.debug('Deployment status checked', {
        hasActiveDeployment: isActive,
        betaHealthy: betaHealth.healthy,
        prodHealthy: prodHealth.healthy,
      });

      // Format summary
      const lines: string[] = [];
      lines.push(`Active deployment: ${isActive ? 'Yes' : 'No'}`);
      if (state.current) {
        lines.push(`Current: ${state.current.deploymentId} (${state.current.status})`);
      }
      lines.push(`Beta health: ${betaHealth.healthy ? 'Healthy' : 'Unhealthy'}`);
      lines.push(`Prod health: ${prodHealth.healthy ? 'Healthy' : 'Unhealthy'}`);

      return {
        content: lines.join('\n'),
        details: result,
      };
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : 'Failed to check deployment status';
      logger.error('Failed to check deployment', { error: errorMsg });
      return {
        content: `Error: ${errorMsg}`,
        isError: true,
        details: {
          hasActiveDeployment: false,
          health: {},
        },
      };
    }
  }
}
