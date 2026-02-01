/**
 * @fileoverview Health checker for deployment verification
 *
 * Checks the health of beta and production servers during deployment.
 */

import type { HealthResult, DeploymentTarget, DeploymentControllerConfig } from './types.js';
import { DEFAULT_DEPLOYMENT_CONFIG } from './types.js';
import { createLogger } from '../logging/index.js';

const logger = createLogger('health-checker');

/**
 * Health checker for deployment targets
 */
export class HealthChecker {
  private config: Required<Omit<DeploymentControllerConfig, 'projectRoot'>> & { projectRoot: string };

  constructor(config: DeploymentControllerConfig) {
    this.config = {
      ...DEFAULT_DEPLOYMENT_CONFIG,
      ...config,
    };
  }

  /**
   * Check health of a deployment target
   */
  async check(target: DeploymentTarget): Promise<HealthResult> {
    const port = target === 'beta' ? this.config.betaHealthPort : this.config.prodHealthPort;
    const url = `http://localhost:${port}/health`;

    const startTime = Date.now();

    try {
      const controller = new AbortController();
      const timeout = setTimeout(
        () => controller.abort(),
        this.config.healthCheckTimeoutMs
      );

      const response = await fetch(url, {
        signal: controller.signal,
        headers: { 'Accept': 'application/json' },
      });

      clearTimeout(timeout);

      const responseTimeMs = Date.now() - startTime;

      if (!response.ok) {
        return {
          healthy: false,
          responseTimeMs,
          error: `HTTP ${response.status}: ${response.statusText}`,
        };
      }

      const data = await response.json() as { status?: string; version?: string };

      if (data.status !== 'ok') {
        return {
          healthy: false,
          responseTimeMs,
          error: `Unhealthy status: ${data.status}`,
          details: data,
        };
      }

      logger.debug('Health check passed', {
        target,
        responseTimeMs,
        version: data.version,
      });

      return {
        healthy: true,
        version: data.version,
        responseTimeMs,
        details: data,
      };
    } catch (error) {
      const responseTimeMs = Date.now() - startTime;

      if (error instanceof Error) {
        if (error.name === 'AbortError') {
          return {
            healthy: false,
            responseTimeMs,
            error: `Health check timed out after ${this.config.healthCheckTimeoutMs}ms`,
          };
        }

        return {
          healthy: false,
          responseTimeMs,
          error: error.message,
        };
      }

      return {
        healthy: false,
        responseTimeMs,
        error: 'Unknown error during health check',
      };
    }
  }

  /**
   * Wait for a target to become healthy
   */
  async waitForHealthy(
    target: DeploymentTarget,
    options: {
      maxAttempts?: number;
      delayMs?: number;
    } = {}
  ): Promise<HealthResult> {
    const { maxAttempts = 30, delayMs = 1000 } = options;

    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      logger.debug('Health check attempt', { target, attempt, maxAttempts });

      const result = await this.check(target);

      if (result.healthy) {
        return result;
      }

      if (attempt < maxAttempts) {
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      }
    }

    return {
      healthy: false,
      error: `Target ${target} did not become healthy after ${maxAttempts} attempts`,
    };
  }
}

/**
 * Create a health checker instance
 */
export function createHealthChecker(config: DeploymentControllerConfig): HealthChecker {
  return new HealthChecker(config);
}
