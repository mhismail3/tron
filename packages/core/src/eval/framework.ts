/**
 * @fileoverview Model Evaluation Framework
 *
 * Provides a standardized way to evaluate and compare LLM performance across:
 * - Response quality
 * - Latency
 * - Token usage and cost
 * - Task completion rates
 * - Tool usage accuracy
 *
 * @example
 * ```typescript
 * const framework = new EvaluationFramework({ providers: [...] });
 *
 * const results = await framework.evaluateModel('claude-sonnet-4-20250514', {
 *   tasks: standardTasks,
 * });
 *
 * const comparison = await framework.compare(['claude-sonnet-4-20250514', 'gpt-4o'], standardTasks);
 * ```
 */
import { createLogger } from '../logging/logger.js';

const logger = createLogger('eval:framework');

// =============================================================================
// Types
// =============================================================================

/**
 * A task for model evaluation
 */
export interface EvaluationTask {
  /** Unique task ID */
  id: string;
  /** Task name */
  name: string;
  /** Task description */
  description: string;
  /** Category (e.g., 'coding', 'reasoning', 'tool_use') */
  category: string;
  /** System prompt to use */
  systemPrompt?: string;
  /** User message/prompt */
  userPrompt: string;
  /** Expected response characteristics */
  expectedOutput?: {
    /** Keywords that should be present */
    containsKeywords?: string[];
    /** Regex patterns to match */
    matchesPatterns?: RegExp[];
    /** Expected tool calls */
    toolCalls?: Array<{ name: string; argumentPatterns?: Record<string, unknown> }>;
    /** Expected length range */
    lengthRange?: { min?: number; max?: number };
  };
  /** Scoring function (returns 0-1) */
  scorer?: (response: string, toolCalls: unknown[]) => number;
  /** Maximum time allowed (ms) */
  timeout?: number;
  /** Task difficulty (1-5) */
  difficulty?: number;
  /** Tags for filtering */
  tags?: string[];
}

/**
 * Result of evaluating a single task
 */
export interface TaskResult {
  taskId: string;
  taskName: string;
  success: boolean;
  score: number;
  latencyMs: number;
  tokensUsed: {
    input: number;
    output: number;
    total: number;
  };
  cost: {
    input: number;
    output: number;
    total: number;
  };
  response: string;
  toolCalls: unknown[];
  error?: string;
  metadata?: Record<string, unknown>;
}

/**
 * Aggregate metrics for a model
 */
export interface ModelMetrics {
  /** Average score across tasks (0-1) */
  averageScore: number;
  /** Success rate (tasks passed / total) */
  successRate: number;
  /** Average latency in ms */
  averageLatencyMs: number;
  /** P50 latency */
  p50LatencyMs: number;
  /** P95 latency */
  p95LatencyMs: number;
  /** Total tokens used */
  totalTokens: {
    input: number;
    output: number;
    total: number;
  };
  /** Total cost */
  totalCost: {
    input: number;
    output: number;
    total: number;
  };
  /** Per-category scores */
  categoryScores: Record<string, { score: number; count: number }>;
  /** Task count */
  taskCount: number;
}

/**
 * Full evaluation result for a model
 */
export interface EvaluationResult {
  modelId: string;
  timestamp: Date;
  metrics: ModelMetrics;
  taskResults: TaskResult[];
  configuration: {
    maxTokens?: number;
    temperature?: number;
    [key: string]: unknown;
  };
}

/**
 * Comparison result between models
 */
export interface ComparisonResult {
  modelId: string;
  metrics: ModelMetrics;
  rank: number;
  relativeScore: number;
}

/**
 * Provider interface for evaluation
 */
export interface EvaluationProvider {
  id: string;
  name: string;
  inputCostPer1k: number;
  outputCostPer1k: number;
  generate: (
    systemPrompt: string | undefined,
    userPrompt: string,
    tools?: unknown[],
    options?: Record<string, unknown>
  ) => Promise<{
    response: string;
    toolCalls: unknown[];
    inputTokens: number;
    outputTokens: number;
    latencyMs: number;
  }>;
}

/**
 * Configuration for the evaluation framework
 */
export interface EvaluationFrameworkConfig {
  /** Registered providers */
  providers: Map<string, EvaluationProvider>;
  /** Default timeout per task (ms) */
  defaultTimeout?: number;
  /** Number of retries on failure */
  retryCount?: number;
  /** Delay between retries (ms) */
  retryDelay?: number;
  /** Enable parallel task execution */
  parallel?: boolean;
  /** Maximum concurrent tasks */
  maxConcurrent?: number;
}

/**
 * Options for running evaluations
 */
export interface EvaluationOptions {
  tasks: EvaluationTask[];
  maxTokens?: number;
  temperature?: number;
  timeout?: number;
  parallel?: boolean;
  onTaskComplete?: (result: TaskResult) => void;
  onProgress?: (completed: number, total: number) => void;
}

// =============================================================================
// Standard Tasks
// =============================================================================

export const STANDARD_TASKS: EvaluationTask[] = [
  {
    id: 'simple-math',
    name: 'Simple Math',
    description: 'Basic arithmetic calculation',
    category: 'reasoning',
    userPrompt: 'What is 247 * 38? Show your work.',
    expectedOutput: {
      containsKeywords: ['9386'],
    },
    difficulty: 1,
    tags: ['math', 'basic'],
  },
  {
    id: 'code-generation',
    name: 'Code Generation',
    description: 'Generate a simple function',
    category: 'coding',
    userPrompt: 'Write a Python function that checks if a number is prime. Include docstring and type hints.',
    expectedOutput: {
      containsKeywords: ['def', 'bool', 'return'],
      matchesPatterns: [/def\s+is_prime\s*\(/],
    },
    difficulty: 2,
    tags: ['python', 'function'],
  },
  {
    id: 'code-debugging',
    name: 'Code Debugging',
    description: 'Find and fix a bug',
    category: 'coding',
    userPrompt: `Fix the bug in this function:
\`\`\`python
def factorial(n):
    if n == 0:
        return 1
    return n * factorial(n)  # Bug here
\`\`\``,
    expectedOutput: {
      containsKeywords: ['n - 1', 'n-1'],
    },
    difficulty: 2,
    tags: ['python', 'debugging'],
  },
  {
    id: 'text-summary',
    name: 'Text Summarization',
    description: 'Summarize a paragraph',
    category: 'language',
    userPrompt: `Summarize this in one sentence: "The mitochondria are membrane-bound organelles found in the cytoplasm of eukaryotic cells. They generate most of the cell's supply of adenosine triphosphate (ATP), used as a source of chemical energy. In addition to supplying cellular energy, mitochondria are involved in other tasks, such as signaling, cellular differentiation, and cell death, as well as maintaining control of the cell cycle and cell growth."`,
    expectedOutput: {
      containsKeywords: ['mitochondria', 'ATP', 'energy'],
      lengthRange: { max: 500 },
    },
    difficulty: 1,
    tags: ['summarization', 'science'],
  },
  {
    id: 'json-generation',
    name: 'JSON Generation',
    description: 'Generate structured JSON',
    category: 'structured',
    userPrompt: 'Generate a JSON object representing a person with name, age, email, and a list of hobbies.',
    expectedOutput: {
      matchesPatterns: [/"name"\s*:/i, /"age"\s*:/i, /"email"\s*:/i, /"hobbies"\s*:\s*\[/i],
    },
    difficulty: 1,
    tags: ['json', 'structured'],
  },
  {
    id: 'reasoning-logic',
    name: 'Logical Reasoning',
    description: 'Solve a logic puzzle',
    category: 'reasoning',
    userPrompt: 'If all roses are flowers, and some flowers fade quickly, can we conclude that some roses fade quickly? Explain your reasoning.',
    expectedOutput: {
      containsKeywords: ['cannot', 'not necessarily', 'no'],
    },
    difficulty: 3,
    tags: ['logic', 'syllogism'],
  },
  {
    id: 'code-review',
    name: 'Code Review',
    description: 'Review code for issues',
    category: 'coding',
    userPrompt: `Review this code and list any issues:
\`\`\`javascript
function getUser(id) {
  var user = null;
  fetch('/api/users/' + id)
    .then(res => res.json())
    .then(data => user = data);
  return user;
}
\`\`\``,
    expectedOutput: {
      containsKeywords: ['async', 'await', 'return', 'null'],
    },
    difficulty: 3,
    tags: ['javascript', 'review', 'async'],
  },
  {
    id: 'explanation',
    name: 'Technical Explanation',
    description: 'Explain a technical concept',
    category: 'language',
    userPrompt: 'Explain what a hash table is to someone who knows basic programming but not data structures. Be concise.',
    expectedOutput: {
      containsKeywords: ['key', 'value', 'lookup', 'O(1)'],
      lengthRange: { min: 100, max: 1000 },
    },
    difficulty: 2,
    tags: ['explanation', 'data-structures'],
  },
];

// =============================================================================
// Evaluation Framework Implementation
// =============================================================================

export class EvaluationFramework {
  private config: Required<Omit<EvaluationFrameworkConfig, 'providers'>> & {
    providers: Map<string, EvaluationProvider>;
  };
  private customTasks: EvaluationTask[] = [];

  constructor(config: Partial<EvaluationFrameworkConfig> = {}) {
    this.config = {
      providers: config.providers ?? new Map(),
      defaultTimeout: config.defaultTimeout ?? 60000,
      retryCount: config.retryCount ?? 2,
      retryDelay: config.retryDelay ?? 1000,
      parallel: config.parallel ?? false,
      maxConcurrent: config.maxConcurrent ?? 5,
    };
  }

  /**
   * Register a custom task
   */
  registerTask(task: EvaluationTask): void {
    // Remove existing task with same ID if present
    this.customTasks = this.customTasks.filter(t => t.id !== task.id);
    this.customTasks.push(task);
    logger.info('Task registered', { id: task.id, name: task.name });
  }

  /**
   * Get all tasks (standard + custom)
   */
  getTasks(): EvaluationTask[] {
    return [...STANDARD_TASKS, ...this.customTasks];
  }

  /**
   * Evaluate a single task with a provider (public wrapper)
   */
  async evaluateTask(
    provider: EvaluationProvider,
    task: EvaluationTask,
    options: Partial<EvaluationOptions> = {}
  ): Promise<TaskResult> {
    return this.runTask(provider, task, {
      tasks: [task],
      ...options,
    });
  }

  /**
   * Generate markdown report from evaluation results
   */
  generateReport(results: Array<{ modelId: string; tasks: TaskResult[] }>): string {
    const lines: string[] = [
      '# Model Evaluation Report',
      '',
      `Generated: ${new Date().toISOString()}`,
      '',
    ];

    for (const result of results) {
      lines.push(`## ${result.modelId}`);
      lines.push('');
      lines.push('| Task | Score | Latency (ms) | Tokens | Success |');
      lines.push('|------|-------|--------------|--------|---------|');

      for (const task of result.tasks) {
        lines.push(
          `| ${task.taskName} | ${(task.score * 100).toFixed(1)}% | ${task.latencyMs} | ${task.tokensUsed.total} | ${task.success ? '✓' : '✗'} |`
        );
      }

      // Summary
      const avgScore = result.tasks.reduce((a, t) => a + t.score, 0) / result.tasks.length;
      const avgLatency = result.tasks.reduce((a, t) => a + t.latencyMs, 0) / result.tasks.length;
      const totalTokens = result.tasks.reduce((a, t) => a + t.tokensUsed.total, 0);
      const successRate = result.tasks.filter(t => t.success).length / result.tasks.length;

      lines.push('');
      lines.push('**Summary:**');
      lines.push(`- Average Score: ${(avgScore * 100).toFixed(1)}%`);
      lines.push(`- Average Latency: ${avgLatency.toFixed(0)}ms`);
      lines.push(`- Total Tokens: ${totalTokens}`);
      lines.push(`- Success Rate: ${(successRate * 100).toFixed(1)}%`);
      lines.push('');
    }

    return lines.join('\n');
  }

  /**
   * Export results as JSON
   */
  exportJson(results: Array<{ modelId: string; tasks?: TaskResult[] }>): string {
    return JSON.stringify(results, null, 2);
  }

  /**
   * Register a provider
   */
  registerProvider(provider: EvaluationProvider): void {
    this.config.providers.set(provider.id, provider);
    logger.info('Provider registered', { id: provider.id, name: provider.name });
  }

  /**
   * Evaluate a model on a set of tasks
   */
  async evaluateModel(
    modelId: string,
    options: EvaluationOptions
  ): Promise<EvaluationResult> {
    const provider = this.config.providers.get(modelId);
    if (!provider) {
      throw new Error(`Provider not found: ${modelId}`);
    }

    logger.info('Starting model evaluation', {
      modelId,
      taskCount: options.tasks.length,
    });

    const taskResults: TaskResult[] = [];
    const startTime = Date.now();

    // Execute tasks
    if (options.parallel) {
      // Parallel execution with concurrency limit
      const results = await this.runParallel(
        options.tasks,
        (task) => this.runTask(provider, task, options),
        options.onProgress
      );
      taskResults.push(...results);
    } else {
      // Sequential execution
      for (let i = 0; i < options.tasks.length; i++) {
        const task = options.tasks[i]!;
        const result = await this.runTask(provider, task, options);
        taskResults.push(result);

        options.onTaskComplete?.(result);
        options.onProgress?.(i + 1, options.tasks.length);
      }
    }

    // Calculate metrics
    const metrics = this.calculateMetrics(taskResults);

    const result: EvaluationResult = {
      modelId,
      timestamp: new Date(),
      metrics,
      taskResults,
      configuration: {
        maxTokens: options.maxTokens,
        temperature: options.temperature,
      },
    };

    const duration = Date.now() - startTime;
    logger.info('Evaluation complete', {
      modelId,
      duration,
      averageScore: metrics.averageScore,
      successRate: metrics.successRate,
    });

    return result;
  }

  /**
   * Compare multiple models
   */
  async compare(
    modelIds: string[],
    tasks: EvaluationTask[],
    options?: Omit<EvaluationOptions, 'tasks'>
  ): Promise<ComparisonResult[]> {
    logger.info('Starting model comparison', {
      modelCount: modelIds.length,
      taskCount: tasks.length,
    });

    const results: EvaluationResult[] = [];

    for (const modelId of modelIds) {
      try {
        const result = await this.evaluateModel(modelId, { ...options, tasks });
        results.push(result);
      } catch (error) {
        logger.error('Model evaluation failed', { modelId, error });
      }
    }

    // Rank by average score
    const sorted = [...results].sort(
      (a, b) => b.metrics.averageScore - a.metrics.averageScore
    );

    const maxScore = sorted[0]?.metrics.averageScore || 1;

    return sorted.map((result, index) => ({
      modelId: result.modelId,
      metrics: result.metrics,
      rank: index + 1,
      relativeScore: result.metrics.averageScore / maxScore,
    }));
  }

  /**
   * Run a single task
   */
  private async runTask(
    provider: EvaluationProvider,
    task: EvaluationTask,
    options: EvaluationOptions
  ): Promise<TaskResult> {
    const timeout = task.timeout ?? options.timeout ?? this.config.defaultTimeout;
    let lastError: Error | undefined;

    for (let attempt = 0; attempt <= this.config.retryCount; attempt++) {
      try {
        const result = await this.executeWithTimeout(
          () => provider.generate(
            task.systemPrompt,
            task.userPrompt,
            undefined,
            {
              maxTokens: options.maxTokens,
              temperature: options.temperature,
            }
          ),
          timeout
        );

        // Score the response
        const score = this.scoreResponse(task, result.response, result.toolCalls);
        const success = score >= 0.5;

        // Calculate cost
        const cost = {
          input: (result.inputTokens / 1000) * provider.inputCostPer1k,
          output: (result.outputTokens / 1000) * provider.outputCostPer1k,
          total: 0,
        };
        cost.total = cost.input + cost.output;

        return {
          taskId: task.id,
          taskName: task.name,
          success,
          score,
          latencyMs: result.latencyMs,
          tokensUsed: {
            input: result.inputTokens,
            output: result.outputTokens,
            total: result.inputTokens + result.outputTokens,
          },
          cost,
          response: result.response,
          toolCalls: result.toolCalls,
        };
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error));
        logger.warn('Task attempt failed', {
          taskId: task.id,
          attempt,
          error: lastError.message,
        });

        if (attempt < this.config.retryCount) {
          await this.delay(this.config.retryDelay);
        }
      }
    }

    // All attempts failed
    return {
      taskId: task.id,
      taskName: task.name,
      success: false,
      score: 0,
      latencyMs: 0,
      tokensUsed: { input: 0, output: 0, total: 0 },
      cost: { input: 0, output: 0, total: 0 },
      response: '',
      toolCalls: [],
      error: lastError?.message,
    };
  }

  /**
   * Score a response against expected output
   */
  private scoreResponse(
    task: EvaluationTask,
    response: string,
    toolCalls: unknown[]
  ): number {
    // Use custom scorer if provided
    if (task.scorer) {
      return task.scorer(response, toolCalls);
    }

    const expected = task.expectedOutput;
    if (!expected) {
      return response.length > 0 ? 1 : 0;
    }

    let totalChecks = 0;
    let passedChecks = 0;

    // Check keywords
    if (expected.containsKeywords) {
      totalChecks += expected.containsKeywords.length;
      for (const keyword of expected.containsKeywords) {
        if (response.toLowerCase().includes(keyword.toLowerCase())) {
          passedChecks++;
        }
      }
    }

    // Check patterns
    if (expected.matchesPatterns) {
      totalChecks += expected.matchesPatterns.length;
      for (const pattern of expected.matchesPatterns) {
        if (pattern.test(response)) {
          passedChecks++;
        }
      }
    }

    // Check length
    if (expected.lengthRange) {
      totalChecks++;
      const len = response.length;
      const min = expected.lengthRange.min ?? 0;
      const max = expected.lengthRange.max ?? Infinity;
      if (len >= min && len <= max) {
        passedChecks++;
      }
    }

    // Check tool calls
    if (expected.toolCalls) {
      totalChecks += expected.toolCalls.length;
      for (const expectedCall of expected.toolCalls) {
        const found = toolCalls.some((tc: unknown) => {
          if (typeof tc !== 'object' || tc === null) return false;
          const call = tc as { name?: string };
          return call.name === expectedCall.name;
        });
        if (found) {
          passedChecks++;
        }
      }
    }

    return totalChecks > 0 ? passedChecks / totalChecks : 1;
  }

  /**
   * Calculate aggregate metrics
   */
  private calculateMetrics(results: TaskResult[]): ModelMetrics {
    if (results.length === 0) {
      return {
        averageScore: 0,
        successRate: 0,
        averageLatencyMs: 0,
        p50LatencyMs: 0,
        p95LatencyMs: 0,
        totalTokens: { input: 0, output: 0, total: 0 },
        totalCost: { input: 0, output: 0, total: 0 },
        categoryScores: {},
        taskCount: 0,
      };
    }

    const successCount = results.filter(r => r.success).length;
    const latencies = results.map(r => r.latencyMs).sort((a, b) => a - b);

    const categoryScores: Record<string, { score: number; count: number }> = {};

    let totalInputTokens = 0;
    let totalOutputTokens = 0;
    let totalInputCost = 0;
    let totalOutputCost = 0;
    let totalScore = 0;

    for (const result of results) {
      totalScore += result.score;
      totalInputTokens += result.tokensUsed.input;
      totalOutputTokens += result.tokensUsed.output;
      totalInputCost += result.cost.input;
      totalOutputCost += result.cost.output;
    }

    return {
      averageScore: totalScore / results.length,
      successRate: successCount / results.length,
      averageLatencyMs: latencies.reduce((a, b) => a + b, 0) / latencies.length,
      p50LatencyMs: this.percentile(latencies, 50),
      p95LatencyMs: this.percentile(latencies, 95),
      totalTokens: {
        input: totalInputTokens,
        output: totalOutputTokens,
        total: totalInputTokens + totalOutputTokens,
      },
      totalCost: {
        input: totalInputCost,
        output: totalOutputCost,
        total: totalInputCost + totalOutputCost,
      },
      categoryScores,
      taskCount: results.length,
    };
  }

  /**
   * Calculate percentile
   */
  private percentile(sorted: number[], p: number): number {
    if (sorted.length === 0) return 0;
    const index = Math.ceil((p / 100) * sorted.length) - 1;
    return sorted[Math.max(0, index)] ?? 0;
  }

  /**
   * Run tasks in parallel with concurrency limit
   */
  private async runParallel<T, R>(
    items: T[],
    executor: (item: T) => Promise<R>,
    onProgress?: (completed: number, total: number) => void
  ): Promise<R[]> {
    const results: R[] = [];
    let completed = 0;
    const total = items.length;

    const queue = [...items];
    const running: Promise<void>[] = [];

    const runNext = async (): Promise<void> => {
      const item = queue.shift();
      if (!item) return;

      try {
        const result = await executor(item);
        results.push(result);
        completed++;
        onProgress?.(completed, total);
      } finally {
        if (queue.length > 0) {
          running.push(runNext());
        }
      }
    };

    // Start initial batch
    for (let i = 0; i < Math.min(this.config.maxConcurrent, items.length); i++) {
      running.push(runNext());
    }

    await Promise.all(running);
    return results;
  }

  /**
   * Execute with timeout
   */
  private async executeWithTimeout<T>(
    fn: () => Promise<T>,
    timeoutMs: number
  ): Promise<T> {
    return Promise.race([
      fn(),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error('Timeout')), timeoutMs)
      ),
    ]);
  }

  /**
   * Delay helper
   */
  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createEvaluationFramework(
  config?: Partial<EvaluationFrameworkConfig>
): EvaluationFramework {
  return new EvaluationFramework(config);
}
