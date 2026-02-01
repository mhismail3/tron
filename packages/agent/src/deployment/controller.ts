/**
 * @fileoverview Deployment controller implementation
 *
 * Manages the deployment pipeline for the Tron server:
 * 1. Build
 * 2. Test
 * 3. Start beta
 * 4. Optional approval
 * 5. Swap
 * 6. Verify
 */

import { randomUUID } from 'crypto';
import { spawn, type ChildProcess } from 'child_process';
import { EventEmitter } from 'events';
import type {
  DeploymentController,
  DeploymentControllerConfig,
  DeployOptions,
  DeploymentResult,
  DeploymentState,
  DeploymentStatus,
  DeploymentTarget,
  HealthResult,
} from './types.js';
import { DEFAULT_DEPLOYMENT_CONFIG } from './types.js';
import { HealthChecker } from './health-checker.js';
import { createLogger } from '../logging/index.js';

const logger = createLogger('deployment-controller');

/**
 * Deployment controller implementation
 */
export class TronDeploymentController extends EventEmitter implements DeploymentController {
  private config: Required<Omit<DeploymentControllerConfig, 'projectRoot'>> & { projectRoot: string };
  private healthChecker: HealthChecker;
  private state: DeploymentState = {
    current: null,
    lastSuccessful: null,
    history: [],
  };
  private betaProcess: ChildProcess | null = null;
  private pendingApprovals = new Map<string, {
    deployment: DeploymentResult;
    resolve: (result: DeploymentResult) => void;
    reject: (error: Error) => void;
  }>();

  constructor(config: DeploymentControllerConfig) {
    super();
    this.config = {
      ...DEFAULT_DEPLOYMENT_CONFIG,
      ...config,
    };
    this.healthChecker = new HealthChecker(this.config);
  }

  async deploy(options: DeployOptions): Promise<DeploymentResult> {
    if (this.state.current && !['completed', 'failed', 'rolled_back'].includes(this.state.current.status)) {
      throw new Error('A deployment is already in progress');
    }

    const deploymentId = randomUUID();
    const deployment: DeploymentResult = {
      success: false,
      deploymentId,
      status: 'building',
      startedAt: new Date().toISOString(),
    };

    this.state.current = deployment;
    this.emit('deployment_started', deployment);

    try {
      // Step 1: Build
      this.updateStatus(deployment, 'building');
      const buildResult = await this.runCommand('bun', ['run', 'build']);
      deployment.buildOutput = buildResult.output;

      if (!buildResult.success) {
        throw new Error(`Build failed: ${buildResult.output}`);
      }

      // Step 2: Test
      if (options.runTests) {
        this.updateStatus(deployment, 'testing');
        const testResult = await this.runCommand('bun', ['run', 'test']);
        deployment.testOutput = testResult.output;

        if (!testResult.success) {
          throw new Error(`Tests failed: ${testResult.output}`);
        }
      }

      // Step 3: Start beta server (if deploying to prod)
      if (options.target === 'prod') {
        this.updateStatus(deployment, 'starting_beta');
        await this.startBetaServer();

        const betaHealth = await this.healthChecker.waitForHealthy('beta');
        if (!betaHealth.healthy) {
          throw new Error(`Beta server failed to start: ${betaHealth.error}`);
        }
      }

      // Step 4: Wait for approval (if required)
      if (options.requireApproval) {
        this.updateStatus(deployment, 'awaiting_approval');

        // Wait for approval via approve() method
        await new Promise<void>((resolve, reject) => {
          this.pendingApprovals.set(deploymentId, {
            deployment,
            resolve: () => resolve(),
            reject,
          });

          // Emit event for notification
          this.emit('approval_required', {
            deploymentId,
            target: options.target,
          });
        });
      }

      // Step 5: Swap (deploy to target)
      this.updateStatus(deployment, 'swapping');
      await this.performSwap(options.target);

      // Step 6: Verify
      this.updateStatus(deployment, 'verifying');
      const targetHealth = await this.healthChecker.waitForHealthy(options.target);

      if (!targetHealth.healthy) {
        if (options.autoRollbackOnFailure) {
          await this.rollback();
        }
        throw new Error(`Target failed health check: ${targetHealth.error}`);
      }

      deployment.newVersion = targetHealth.version;

      // Success!
      this.updateStatus(deployment, 'completed');
      deployment.success = true;
      deployment.completedAt = new Date().toISOString();

      this.state.lastSuccessful = deployment;
      this.addToHistory(deployment);

      logger.info('Deployment completed successfully', {
        deploymentId,
        target: options.target,
        version: deployment.newVersion,
      });

      return deployment;

    } catch (error) {
      deployment.status = 'failed';
      deployment.error = error instanceof Error ? error.message : String(error);
      deployment.completedAt = new Date().toISOString();

      this.addToHistory(deployment);

      logger.error('Deployment failed', {
        deploymentId,
        error: deployment.error,
      });

      this.emit('deployment_failed', deployment);

      return deployment;

    } finally {
      // Clean up beta server if started
      await this.stopBetaServer();
      this.pendingApprovals.delete(deploymentId);
    }
  }

  getStatus(): DeploymentState {
    return { ...this.state };
  }

  async approve(deploymentId: string): Promise<DeploymentResult> {
    const pending = this.pendingApprovals.get(deploymentId);

    if (!pending) {
      throw new Error(`No pending approval found for deployment ${deploymentId}`);
    }

    pending.resolve(pending.deployment);

    logger.info('Deployment approved', { deploymentId });
    this.emit('deployment_approved', { deploymentId });

    // The deployment will continue from where it was waiting
    // Return current state
    return pending.deployment;
  }

  async rollback(): Promise<DeploymentResult> {
    const lastSuccessful = this.state.lastSuccessful;

    if (!lastSuccessful) {
      throw new Error('No previous successful deployment to rollback to');
    }

    const deploymentId = randomUUID();
    const deployment: DeploymentResult = {
      success: false,
      deploymentId,
      status: 'swapping',
      startedAt: new Date().toISOString(),
      previousVersion: this.state.current?.newVersion,
    };

    this.state.current = deployment;

    try {
      // Perform rollback swap
      await this.performSwap('prod');

      // Verify
      this.updateStatus(deployment, 'verifying');
      const health = await this.healthChecker.waitForHealthy('prod');

      if (!health.healthy) {
        throw new Error(`Rollback verification failed: ${health.error}`);
      }

      deployment.status = 'rolled_back';
      deployment.success = true;
      deployment.completedAt = new Date().toISOString();
      deployment.newVersion = health.version;

      this.addToHistory(deployment);

      logger.info('Rollback completed', {
        deploymentId,
        version: deployment.newVersion,
      });

      this.emit('rollback_completed', deployment);

      return deployment;

    } catch (error) {
      deployment.status = 'failed';
      deployment.error = error instanceof Error ? error.message : String(error);
      deployment.completedAt = new Date().toISOString();

      this.addToHistory(deployment);

      logger.error('Rollback failed', {
        deploymentId,
        error: deployment.error,
      });

      return deployment;
    }
  }

  async healthCheck(target: DeploymentTarget): Promise<HealthResult> {
    return this.healthChecker.check(target);
  }

  async cancel(deploymentId: string): Promise<boolean> {
    const pending = this.pendingApprovals.get(deploymentId);

    if (pending) {
      pending.reject(new Error('Deployment cancelled'));
      this.pendingApprovals.delete(deploymentId);
      return true;
    }

    // Can't cancel a deployment not waiting for approval
    return false;
  }

  // Private helpers

  private updateStatus(deployment: DeploymentResult, status: DeploymentStatus): void {
    deployment.status = status;
    this.emit('status_changed', { deploymentId: deployment.deploymentId, status });
  }

  private async runCommand(
    command: string,
    args: string[]
  ): Promise<{ success: boolean; output: string }> {
    return new Promise((resolve) => {
      const process = spawn(command, args, {
        cwd: this.config.projectRoot,
        shell: true,
      });

      let output = '';

      process.stdout?.on('data', (data) => {
        output += data.toString();
      });

      process.stderr?.on('data', (data) => {
        output += data.toString();
      });

      process.on('close', (code) => {
        resolve({
          success: code === 0,
          output,
        });
      });

      process.on('error', (error) => {
        resolve({
          success: false,
          output: error.message,
        });
      });
    });
  }

  private async startBetaServer(): Promise<void> {
    // In a real implementation, this would start the beta server
    // For now, we'll emit an event that can be handled by the system
    this.emit('start_beta_server', {
      port: this.config.betaPort,
      healthPort: this.config.betaHealthPort,
    });

    logger.info('Starting beta server', {
      port: this.config.betaPort,
      healthPort: this.config.betaHealthPort,
    });
  }

  private async stopBetaServer(): Promise<void> {
    if (this.betaProcess) {
      this.betaProcess.kill();
      this.betaProcess = null;
    }

    this.emit('stop_beta_server');
  }

  private async performSwap(target: DeploymentTarget): Promise<void> {
    // In a real implementation, this would:
    // 1. Stop the target server
    // 2. Copy/symlink the new build
    // 3. Start the target server

    // For now, emit events for external handling
    this.emit('swap_start', { target });

    logger.info('Performing swap', { target });

    // Simulate swap delay
    await new Promise((resolve) => setTimeout(resolve, 1000));

    this.emit('swap_complete', { target });
  }

  private addToHistory(deployment: DeploymentResult): void {
    this.state.history.unshift(deployment);

    // Trim history
    if (this.state.history.length > this.config.maxHistoryEntries) {
      this.state.history = this.state.history.slice(0, this.config.maxHistoryEntries);
    }
  }
}

/**
 * Create a deployment controller instance
 */
export function createDeploymentController(
  config: DeploymentControllerConfig
): DeploymentController {
  return new TronDeploymentController(config);
}
