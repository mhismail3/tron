/**
 * @fileoverview Deploy Tron Tool
 *
 * Allows agents to trigger deployments of the Tron server.
 */

import type { TronTool, TronToolResult } from '@core/types/index.js';
import type { DeploymentController } from '@platform/deployment/types.js';
import type { DeployToolParams, DeployToolResult } from './types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('tool:deploy');

/**
 * Configuration for DeployTool
 */
export interface DeployToolConfig {
  /** Deployment controller instance */
  deploymentController: DeploymentController;
  /** Whether to allow prod deployments (safety flag) */
  allowProdDeployment?: boolean;
}

/**
 * Tool for deploying Tron server
 */
export class DeployTool implements TronTool<DeployToolParams, DeployToolResult> {
  readonly name = 'deploy_tron';
  readonly description =
    'Deploy changes to the Tron server. Can deploy to beta for testing or prod for production use.';

  readonly parameters = {
    type: 'object' as const,
    properties: {
      target: {
        type: 'string' as const,
        enum: ['beta', 'prod'],
        description: 'Target environment (beta or prod)',
      },
      runTests: {
        type: 'boolean' as const,
        description: 'Whether to run tests before deploying (default: true)',
      },
      requireApproval: {
        type: 'boolean' as const,
        description: 'Whether to require manual approval before swap (default: true for prod)',
      },
      autoRollbackOnFailure: {
        type: 'boolean' as const,
        description: 'Whether to automatically rollback on failure (default: true)',
      },
    },
    required: ['target'] as string[],
  };

  private config: DeployToolConfig;

  constructor(config: DeployToolConfig) {
    this.config = {
      allowProdDeployment: false,
      ...config,
    };
  }

  async execute(params: DeployToolParams): Promise<TronToolResult<DeployToolResult>> {
    const { target, runTests = true, requireApproval, autoRollbackOnFailure = true } = params;

    // Safety check for prod deployments
    if (target === 'prod' && !this.config.allowProdDeployment) {
      const errorMsg = 'Production deployments are disabled. Set allowProdDeployment to true in config to enable.';
      logger.warn('Production deployment blocked', { target });
      return {
        content: `Error: ${errorMsg}`,
        isError: true,
        details: {
          success: false,
          deploymentId: '',
          status: 'failed',
          startedAt: new Date().toISOString(),
          error: errorMsg,
        },
      };
    }

    // Default requireApproval based on target
    const shouldRequireApproval = requireApproval ?? (target === 'prod');

    try {
      logger.info('Starting deployment', {
        target,
        runTests,
        requireApproval: shouldRequireApproval,
      });

      const result = await this.config.deploymentController.deploy({
        source: 'current',
        target,
        runTests,
        requireApproval: shouldRequireApproval,
        autoRollbackOnFailure,
      });

      const toolResult: DeployToolResult = {
        success: result.success,
        deploymentId: result.deploymentId,
        status: result.status,
        startedAt: result.startedAt,
        completedAt: result.completedAt,
        error: result.error,
      };

      if (result.success) {
        return {
          content: `Deployment ${result.deploymentId} completed successfully to ${target}`,
          details: toolResult,
        };
      } else {
        return {
          content: `Deployment ${result.deploymentId} failed: ${result.error ?? 'Unknown error'}`,
          isError: true,
          details: toolResult,
        };
      }
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : 'Failed to initiate deployment';
      logger.error('Deployment failed', { error: errorMsg });
      return {
        content: `Error: ${errorMsg}`,
        isError: true,
        details: {
          success: false,
          deploymentId: '',
          status: 'failed',
          startedAt: new Date().toISOString(),
          error: errorMsg,
        },
      };
    }
  }
}
