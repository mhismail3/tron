/**
 * @fileoverview Comprehensive Tests for EvaluationFramework
 *
 * Tests for model evaluation including:
 * - Configuration options
 * - Standard and custom tasks
 * - Task registration and retrieval
 * - Report generation
 * - JSON export
 * - Model evaluation with mocked providers
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  EvaluationFramework,
  createEvaluationFramework,
  type EvaluationTask,
  type EvaluationProvider,
  type TaskResult,
  STANDARD_TASKS,
} from '../../src/eval/framework.js';

describe('EvaluationFramework', () => {
  let framework: EvaluationFramework;

  beforeEach(() => {
    framework = new EvaluationFramework();
  });

  describe('Configuration', () => {
    it('should accept custom configuration', () => {
      const customFramework = new EvaluationFramework({
        defaultTimeout: 60000,
        retryCount: 3,
        retryDelay: 2000,
        parallel: true,
        maxConcurrent: 10,
      });
      expect(customFramework).toBeDefined();
    });

    it('should accept empty configuration', () => {
      const defaultFramework = new EvaluationFramework();
      expect(defaultFramework).toBeDefined();
    });

    it('should accept providers map', () => {
      const providers = new Map<string, EvaluationProvider>();
      providers.set('test', {
        id: 'test',
        name: 'Test Provider',
        inputCostPer1k: 0.001,
        outputCostPer1k: 0.002,
        generate: async () => ({
          response: 'test',
          toolCalls: [],
          inputTokens: 10,
          outputTokens: 5,
          latencyMs: 100,
        }),
      });

      const customFramework = new EvaluationFramework({ providers });
      expect(customFramework).toBeDefined();
    });
  });

  describe('Factory Function', () => {
    it('should create framework with createEvaluationFramework', () => {
      const fw = createEvaluationFramework({
        defaultTimeout: 30000,
      });
      expect(fw).toBeDefined();
      expect(fw instanceof EvaluationFramework).toBe(true);
    });

    it('should create framework with default config', () => {
      const fw = createEvaluationFramework();
      expect(fw).toBeDefined();
    });
  });

  describe('Standard Tasks', () => {
    it('should include standard tasks', () => {
      expect(STANDARD_TASKS).toBeDefined();
      expect(Array.isArray(STANDARD_TASKS)).toBe(true);
      expect(STANDARD_TASKS.length).toBeGreaterThan(0);
    });

    it('should have tasks with required fields', () => {
      for (const task of STANDARD_TASKS) {
        expect(task).toHaveProperty('id');
        expect(task).toHaveProperty('name');
        expect(task).toHaveProperty('userPrompt');
        expect(task).toHaveProperty('category');
        expect(task).toHaveProperty('description');
      }
    });

    it('should have simple-math task', () => {
      const mathTask = STANDARD_TASKS.find(t => t.id === 'simple-math');
      expect(mathTask).toBeDefined();
      expect(mathTask?.category).toBe('reasoning');
      expect(mathTask?.expectedOutput?.containsKeywords).toContain('9386');
    });

    it('should have code-generation task', () => {
      const codeTask = STANDARD_TASKS.find(t => t.id === 'code-generation');
      expect(codeTask).toBeDefined();
      expect(codeTask?.category).toBe('coding');
    });

    it('should have difficulty levels', () => {
      for (const task of STANDARD_TASKS) {
        if (task.difficulty !== undefined) {
          expect(task.difficulty).toBeGreaterThanOrEqual(1);
          expect(task.difficulty).toBeLessThanOrEqual(5);
        }
      }
    });

    it('should have tags for filtering', () => {
      const tasksWithTags = STANDARD_TASKS.filter(t => t.tags && t.tags.length > 0);
      expect(tasksWithTags.length).toBeGreaterThan(0);
    });
  });

  describe('Interface', () => {
    it('should define registerTask method', () => {
      expect(typeof framework.registerTask).toBe('function');
    });

    it('should define getTasks method', () => {
      expect(typeof framework.getTasks).toBe('function');
    });

    it('should define evaluateTask method', () => {
      expect(typeof framework.evaluateTask).toBe('function');
    });

    it('should define evaluateModel method', () => {
      expect(typeof framework.evaluateModel).toBe('function');
    });

    it('should define compare method', () => {
      expect(typeof framework.compare).toBe('function');
    });

    it('should define registerProvider method', () => {
      expect(typeof framework.registerProvider).toBe('function');
    });

    it('should define generateReport method', () => {
      expect(typeof framework.generateReport).toBe('function');
    });

    it('should define exportJson method', () => {
      expect(typeof framework.exportJson).toBe('function');
    });
  });

  describe('Task Registration', () => {
    it('should allow custom task registration', () => {
      const customTask: EvaluationTask = {
        id: 'custom-1',
        name: 'Custom Test Task',
        description: 'A custom test task',
        userPrompt: 'Write a hello world function',
        category: 'coding',
      };

      framework.registerTask(customTask);
      const tasks = framework.getTasks();

      expect(tasks.some(t => t.id === 'custom-1')).toBe(true);
    });

    it('should preserve task properties', () => {
      const customTask: EvaluationTask = {
        id: 'test-task',
        name: 'Test Task',
        description: 'Test description',
        userPrompt: 'Test prompt',
        category: 'general',
        expectedOutput: {
          containsKeywords: ['expected', 'words'],
        },
        difficulty: 3,
        tags: ['test', 'custom'],
      };

      framework.registerTask(customTask);
      const registered = framework.getTasks().find(t => t.id === 'test-task');

      expect(registered?.name).toBe('Test Task');
      expect(registered?.description).toBe('Test description');
      expect(registered?.category).toBe('general');
      expect(registered?.difficulty).toBe(3);
      expect(registered?.tags).toContain('test');
    });

    it('should replace existing task with same ID', () => {
      const task1: EvaluationTask = {
        id: 'duplicate',
        name: 'First Task',
        description: 'First',
        userPrompt: 'First prompt',
        category: 'test',
      };

      const task2: EvaluationTask = {
        id: 'duplicate',
        name: 'Second Task',
        description: 'Second',
        userPrompt: 'Second prompt',
        category: 'test',
      };

      framework.registerTask(task1);
      framework.registerTask(task2);

      const tasks = framework.getTasks().filter(t => t.id === 'duplicate');
      expect(tasks.length).toBe(1);
      expect(tasks[0]?.name).toBe('Second Task');
    });

    it('should include both standard and custom tasks in getTasks', () => {
      const customTask: EvaluationTask = {
        id: 'my-custom-task',
        name: 'My Custom Task',
        description: 'Custom',
        userPrompt: 'Custom prompt',
        category: 'custom',
      };

      framework.registerTask(customTask);
      const allTasks = framework.getTasks();

      // Should include standard tasks
      expect(allTasks.some(t => t.id === 'simple-math')).toBe(true);
      // Should include custom task
      expect(allTasks.some(t => t.id === 'my-custom-task')).toBe(true);
    });
  });

  describe('Provider Registration', () => {
    it('should register a provider', () => {
      const provider: EvaluationProvider = {
        id: 'test-provider',
        name: 'Test Provider',
        inputCostPer1k: 0.001,
        outputCostPer1k: 0.002,
        generate: async () => ({
          response: 'response',
          toolCalls: [],
          inputTokens: 10,
          outputTokens: 5,
          latencyMs: 100,
        }),
      };

      framework.registerProvider(provider);
      // No direct way to verify, but shouldn't throw
      expect(true).toBe(true);
    });
  });

  describe('Report Generation', () => {
    it('should generate markdown report', () => {
      const results = [
        {
          modelId: 'test-model',
          tasks: [
            {
              taskId: 'task-1',
              taskName: 'Test Task 1',
              success: true,
              score: 0.9,
              latencyMs: 100,
              tokensUsed: { input: 50, output: 30, total: 80 },
              cost: { input: 0.00005, output: 0.00006, total: 0.00011 },
              response: 'Test response',
              toolCalls: [],
            },
            {
              taskId: 'task-2',
              taskName: 'Test Task 2',
              success: false,
              score: 0.3,
              latencyMs: 200,
              tokensUsed: { input: 60, output: 40, total: 100 },
              cost: { input: 0.00006, output: 0.00008, total: 0.00014 },
              response: 'Another response',
              toolCalls: [],
            },
          ] as TaskResult[],
        },
      ];

      const report = framework.generateReport(results);

      expect(typeof report).toBe('string');
      expect(report).toContain('# Model Evaluation Report');
      expect(report).toContain('test-model');
      expect(report).toContain('Test Task 1');
      expect(report).toContain('Test Task 2');
      expect(report).toContain('Average Score');
      expect(report).toContain('Success Rate');
    });

    it('should include success/failure indicators', () => {
      const results = [
        {
          modelId: 'model-1',
          tasks: [
            {
              taskId: 't1',
              taskName: 'Passed Task',
              success: true,
              score: 1,
              latencyMs: 50,
              tokensUsed: { input: 10, output: 10, total: 20 },
              cost: { input: 0, output: 0, total: 0 },
              response: '',
              toolCalls: [],
            },
            {
              taskId: 't2',
              taskName: 'Failed Task',
              success: false,
              score: 0,
              latencyMs: 50,
              tokensUsed: { input: 10, output: 10, total: 20 },
              cost: { input: 0, output: 0, total: 0 },
              response: '',
              toolCalls: [],
            },
          ] as TaskResult[],
        },
      ];

      const report = framework.generateReport(results);

      expect(report).toContain('✓');
      expect(report).toContain('✗');
    });

    it('should handle multiple models', () => {
      const results = [
        {
          modelId: 'model-a',
          tasks: [
            {
              taskId: 't1',
              taskName: 'Task 1',
              success: true,
              score: 0.8,
              latencyMs: 100,
              tokensUsed: { input: 20, output: 20, total: 40 },
              cost: { input: 0, output: 0, total: 0 },
              response: '',
              toolCalls: [],
            },
          ] as TaskResult[],
        },
        {
          modelId: 'model-b',
          tasks: [
            {
              taskId: 't1',
              taskName: 'Task 1',
              success: true,
              score: 0.9,
              latencyMs: 80,
              tokensUsed: { input: 25, output: 15, total: 40 },
              cost: { input: 0, output: 0, total: 0 },
              response: '',
              toolCalls: [],
            },
          ] as TaskResult[],
        },
      ];

      const report = framework.generateReport(results);

      expect(report).toContain('model-a');
      expect(report).toContain('model-b');
    });
  });

  describe('JSON Export', () => {
    it('should export results as JSON', () => {
      const results = [
        {
          modelId: 'test-model',
          tasks: [],
        },
      ];

      const json = framework.exportJson(results);
      const parsed = JSON.parse(json);

      expect(parsed[0].modelId).toBe('test-model');
    });

    it('should preserve all task data in JSON', () => {
      const results = [
        {
          modelId: 'model-1',
          tasks: [
            {
              taskId: 'task-1',
              taskName: 'Test Task',
              success: true,
              score: 0.95,
              latencyMs: 150,
              tokensUsed: { input: 100, output: 50, total: 150 },
              cost: { input: 0.0001, output: 0.0001, total: 0.0002 },
              response: 'Test response content',
              toolCalls: [{ name: 'test_tool', arguments: {} }],
            },
          ] as TaskResult[],
        },
      ];

      const json = framework.exportJson(results);
      const parsed = JSON.parse(json);

      expect(parsed[0].tasks[0].taskId).toBe('task-1');
      expect(parsed[0].tasks[0].score).toBe(0.95);
      expect(parsed[0].tasks[0].tokensUsed.total).toBe(150);
      expect(parsed[0].tasks[0].toolCalls.length).toBe(1);
    });

    it('should format JSON with indentation', () => {
      const results = [{ modelId: 'test', tasks: [] }];
      const json = framework.exportJson(results);

      // Should have newlines (formatted)
      expect(json).toContain('\n');
    });
  });

  describe('Task Evaluation', () => {
    it('should evaluate a task with provider', async () => {
      const mockProvider: EvaluationProvider = {
        id: 'mock',
        name: 'Mock Provider',
        inputCostPer1k: 0.001,
        outputCostPer1k: 0.002,
        generate: vi.fn().mockResolvedValue({
          response: 'The answer is 9386',
          toolCalls: [],
          inputTokens: 20,
          outputTokens: 10,
          latencyMs: 50,
        }),
      };

      const task: EvaluationTask = {
        id: 'test-eval',
        name: 'Test Evaluation',
        description: 'Test',
        userPrompt: 'What is 247 * 38?',
        category: 'math',
        expectedOutput: {
          containsKeywords: ['9386'],
        },
      };

      const result = await framework.evaluateTask(mockProvider, task);

      expect(result.taskId).toBe('test-eval');
      expect(result.success).toBe(true);
      expect(result.score).toBe(1);
      expect(result.latencyMs).toBe(50);
      expect(result.tokensUsed.input).toBe(20);
      expect(result.tokensUsed.output).toBe(10);
    });

    it('should handle failed evaluation', async () => {
      const mockProvider: EvaluationProvider = {
        id: 'mock',
        name: 'Mock Provider',
        inputCostPer1k: 0.001,
        outputCostPer1k: 0.002,
        generate: vi.fn().mockResolvedValue({
          response: 'Wrong answer',
          toolCalls: [],
          inputTokens: 20,
          outputTokens: 10,
          latencyMs: 50,
        }),
      };

      const task: EvaluationTask = {
        id: 'test-fail',
        name: 'Test Failure',
        description: 'Test',
        userPrompt: 'What is 247 * 38?',
        category: 'math',
        expectedOutput: {
          containsKeywords: ['9386'],
        },
      };

      const result = await framework.evaluateTask(mockProvider, task);

      expect(result.success).toBe(false);
      expect(result.score).toBe(0);
    });

    it('should calculate costs correctly', async () => {
      const mockProvider: EvaluationProvider = {
        id: 'mock',
        name: 'Mock Provider',
        inputCostPer1k: 0.01, // $0.01 per 1k input tokens
        outputCostPer1k: 0.03, // $0.03 per 1k output tokens
        generate: vi.fn().mockResolvedValue({
          response: 'Response',
          toolCalls: [],
          inputTokens: 1000,
          outputTokens: 500,
          latencyMs: 100,
        }),
      };

      const task: EvaluationTask = {
        id: 'cost-test',
        name: 'Cost Test',
        description: 'Test',
        userPrompt: 'Test',
        category: 'test',
      };

      const result = await framework.evaluateTask(mockProvider, task);

      expect(result.cost.input).toBeCloseTo(0.01); // 1000/1000 * 0.01
      expect(result.cost.output).toBeCloseTo(0.015); // 500/1000 * 0.03
      expect(result.cost.total).toBeCloseTo(0.025);
    });

    it('should handle provider errors with retries', async () => {
      let callCount = 0;
      const mockProvider: EvaluationProvider = {
        id: 'flaky',
        name: 'Flaky Provider',
        inputCostPer1k: 0.001,
        outputCostPer1k: 0.002,
        generate: vi.fn().mockImplementation(async () => {
          callCount++;
          if (callCount < 3) {
            throw new Error('Temporary failure');
          }
          return {
            response: 'Success after retry',
            toolCalls: [],
            inputTokens: 10,
            outputTokens: 5,
            latencyMs: 50,
          };
        }),
      };

      const fw = new EvaluationFramework({
        retryCount: 3,
        retryDelay: 10, // Short delay for tests
      });

      const task: EvaluationTask = {
        id: 'retry-test',
        name: 'Retry Test',
        description: 'Test',
        userPrompt: 'Test',
        category: 'test',
      };

      const result = await fw.evaluateTask(mockProvider, task);

      expect(result.response).toBe('Success after retry');
      expect(callCount).toBe(3);
    });
  });

  describe('Scoring', () => {
    it('should score based on keywords', async () => {
      const mockProvider: EvaluationProvider = {
        id: 'mock',
        name: 'Mock',
        inputCostPer1k: 0,
        outputCostPer1k: 0,
        generate: vi.fn().mockResolvedValue({
          response: 'hello world foo bar',
          toolCalls: [],
          inputTokens: 10,
          outputTokens: 10,
          latencyMs: 50,
        }),
      };

      const task: EvaluationTask = {
        id: 'keyword-test',
        name: 'Keyword Test',
        description: 'Test',
        userPrompt: 'Test',
        category: 'test',
        expectedOutput: {
          containsKeywords: ['hello', 'world', 'missing'],
        },
      };

      const result = await framework.evaluateTask(mockProvider, task);

      // 2 out of 3 keywords found
      expect(result.score).toBeCloseTo(2 / 3);
    });

    it('should score based on regex patterns', async () => {
      const mockProvider: EvaluationProvider = {
        id: 'mock',
        name: 'Mock',
        inputCostPer1k: 0,
        outputCostPer1k: 0,
        generate: vi.fn().mockResolvedValue({
          response: 'def is_prime(n):',
          toolCalls: [],
          inputTokens: 10,
          outputTokens: 10,
          latencyMs: 50,
        }),
      };

      const task: EvaluationTask = {
        id: 'pattern-test',
        name: 'Pattern Test',
        description: 'Test',
        userPrompt: 'Test',
        category: 'test',
        expectedOutput: {
          matchesPatterns: [/def\s+is_prime\s*\(/],
        },
      };

      const result = await framework.evaluateTask(mockProvider, task);

      expect(result.score).toBe(1);
    });

    it('should use custom scorer function', async () => {
      const mockProvider: EvaluationProvider = {
        id: 'mock',
        name: 'Mock',
        inputCostPer1k: 0,
        outputCostPer1k: 0,
        generate: vi.fn().mockResolvedValue({
          response: 'Custom response',
          toolCalls: [{ name: 'test_tool' }],
          inputTokens: 10,
          outputTokens: 10,
          latencyMs: 50,
        }),
      };

      const task: EvaluationTask = {
        id: 'custom-scorer',
        name: 'Custom Scorer',
        description: 'Test',
        userPrompt: 'Test',
        category: 'test',
        scorer: (response, toolCalls) => {
          return toolCalls.length > 0 ? 0.75 : 0.25;
        },
      };

      const result = await framework.evaluateTask(mockProvider, task);

      expect(result.score).toBe(0.75);
    });
  });
});
