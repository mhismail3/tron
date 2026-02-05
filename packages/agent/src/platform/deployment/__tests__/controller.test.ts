/**
 * @fileoverview Tests for TronDeploymentController
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { TronDeploymentController, createDeploymentController } from '../controller.js';
import type { DeploymentControllerConfig, DeployOptions } from '../types.js';

// Mock child_process
vi.mock('child_process', () => ({
  spawn: vi.fn(() => {
    const events: Record<string, ((...args: unknown[]) => void)[]> = {};
    return {
      stdout: {
        on: vi.fn((event: string, cb: (data: Buffer) => void) => {
          if (event === 'data') {
            setTimeout(() => cb(Buffer.from('Build successful')), 10);
          }
        }),
      },
      stderr: {
        on: vi.fn(),
      },
      on: vi.fn((event: string, cb: (...args: unknown[]) => void) => {
        if (!events[event]) events[event] = [];
        events[event].push(cb);
        if (event === 'close') {
          setTimeout(() => cb(0), 20);
        }
      }),
      kill: vi.fn(),
    };
  }),
}));

describe('TronDeploymentController', () => {
  let controller: TronDeploymentController;
  const mockConfig: DeploymentControllerConfig = {
    projectRoot: '/test/path',
    betaPort: 8082,
    betaHealthPort: 8083,
    prodPort: 8080,
    prodHealthPort: 8081,
    healthCheckTimeoutMs: 1000,
  };

  const defaultOptions: DeployOptions = {
    source: 'current',
    target: 'beta',
    runTests: false,
    requireApproval: false,
    autoRollbackOnFailure: true,
  };

  beforeEach(() => {
    controller = new TronDeploymentController(mockConfig);
    vi.stubGlobal('fetch', vi.fn());

    // Default healthy response
    vi.mocked(fetch).mockResolvedValue({
      ok: true,
      json: async () => ({ status: 'ok', version: '1.0.0' }),
    } as Response);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  describe('getStatus', () => {
    it('should return initial state', () => {
      const status = controller.getStatus();

      expect(status.current).toBeNull();
      expect(status.lastSuccessful).toBeNull();
      expect(status.history).toHaveLength(0);
    });
  });

  describe('deploy', () => {
    it('should complete a basic deployment', async () => {
      const result = await controller.deploy(defaultOptions);

      expect(result.success).toBe(true);
      expect(result.status).toBe('completed');
      expect(result.deploymentId).toBeDefined();
      expect(result.startedAt).toBeDefined();
      expect(result.completedAt).toBeDefined();
    });

    it('should include build output', async () => {
      const result = await controller.deploy(defaultOptions);

      expect(result.buildOutput).toBeDefined();
      expect(result.buildOutput).toContain('Build successful');
    });

    it('should emit deployment_started event', async () => {
      const listener = vi.fn();
      controller.on('deployment_started', listener);

      await controller.deploy(defaultOptions);

      expect(listener).toHaveBeenCalledTimes(1);
      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          deploymentId: expect.any(String),
        })
      );
    });

    it('should update state with deployment', async () => {
      await controller.deploy(defaultOptions);

      const status = controller.getStatus();
      expect(status.lastSuccessful).not.toBeNull();
      expect(status.history).toHaveLength(1);
    });

    it('should reject concurrent deployments', async () => {
      // Start first deployment (don't await)
      const firstDeploy = controller.deploy(defaultOptions);

      // Try to start second deployment
      await expect(controller.deploy(defaultOptions)).rejects.toThrow(
        'deployment is already in progress'
      );

      // Wait for first to complete
      await firstDeploy;
    });
  });

  describe('deploy with tests', () => {
    it('should run tests when configured', async () => {
      const result = await controller.deploy({
        ...defaultOptions,
        runTests: true,
      });

      expect(result.success).toBe(true);
      expect(result.testOutput).toBeDefined();
    });
  });

  describe('deploy to prod', () => {
    it('should start beta server when deploying to prod', async () => {
      const betaListener = vi.fn();
      controller.on('start_beta_server', betaListener);

      await controller.deploy({
        ...defaultOptions,
        target: 'prod',
      });

      expect(betaListener).toHaveBeenCalledWith({
        port: 8082,
        healthPort: 8083,
      });
    });
  });

  describe('deploy with approval', () => {
    it('should wait for approval when required', async () => {
      const approvalListener = vi.fn();
      controller.on('approval_required', approvalListener);

      // Start deployment in background
      const deployPromise = controller.deploy({
        ...defaultOptions,
        requireApproval: true,
      });

      // Wait for approval event
      await new Promise((resolve) => setTimeout(resolve, 100));

      expect(approvalListener).toHaveBeenCalled();

      // Approve the deployment
      const deploymentId = approvalListener.mock.calls[0][0].deploymentId;
      await controller.approve(deploymentId);

      const result = await deployPromise;
      expect(result.success).toBe(true);
    });

    it('should fail if approval not found', async () => {
      await expect(controller.approve('non-existent')).rejects.toThrow(
        'No pending approval found'
      );
    });
  });

  describe('healthCheck', () => {
    it('should check health of target', async () => {
      const result = await controller.healthCheck('prod');

      expect(result.healthy).toBe(true);
      expect(fetch).toHaveBeenCalledWith(
        'http://localhost:8081/health',
        expect.anything()
      );
    });

    it('should check health of beta', async () => {
      await controller.healthCheck('beta');

      expect(fetch).toHaveBeenCalledWith(
        'http://localhost:8083/health',
        expect.anything()
      );
    });
  });

  describe('rollback', () => {
    it('should fail if no previous deployment', async () => {
      await expect(controller.rollback()).rejects.toThrow(
        'No previous successful deployment'
      );
    });

    it('should rollback to previous version', async () => {
      // First, do a successful deployment
      await controller.deploy(defaultOptions);

      // Now rollback
      const result = await controller.rollback();

      expect(result.success).toBe(true);
      expect(result.status).toBe('rolled_back');
    });
  });

  describe('cancel', () => {
    it('should cancel pending approval', async () => {
      // Start deployment with approval
      const deployPromise = controller.deploy({
        ...defaultOptions,
        requireApproval: true,
      });

      // Wait for approval event
      await new Promise((resolve) => setTimeout(resolve, 100));

      const status = controller.getStatus();
      const deploymentId = status.current?.deploymentId;

      const cancelled = await controller.cancel(deploymentId!);
      expect(cancelled).toBe(true);

      // Deployment should fail
      const result = await deployPromise;
      expect(result.success).toBe(false);
      expect(result.error).toContain('cancelled');
    });

    it('should return false for non-pending deployment', async () => {
      const cancelled = await controller.cancel('non-existent');
      expect(cancelled).toBe(false);
    });
  });

  describe('history management', () => {
    it('should limit history to maxHistoryEntries', async () => {
      vi.useFakeTimers();
      const smallHistoryController = new TronDeploymentController({
        ...mockConfig,
        maxHistoryEntries: 3,
      });

      vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ status: 'ok' }),
      } as Response));

      // Do 5 deployments (fake timers make the 1s swap delay instant)
      for (let i = 0; i < 5; i++) {
        const promise = smallHistoryController.deploy(defaultOptions);
        await vi.advanceTimersByTimeAsync(2000);
        await promise;
      }

      const status = smallHistoryController.getStatus();
      expect(status.history).toHaveLength(3);
      vi.useRealTimers();
    });
  });

  describe('factory function', () => {
    it('should create controller with createDeploymentController', async () => {
      const factoryController = createDeploymentController(mockConfig);
      const status = factoryController.getStatus();

      expect(status.current).toBeNull();
    });
  });
});
