/**
 * @fileoverview Tests for AgentFactory Tool Denial System
 *
 * TDD tests for the denial-based tool access control in AgentFactory:
 * 1. toolDenials = undefined -> all default tools
 * 2. toolDenials = { denyAll: true } -> no tools (text generation only)
 * 3. toolDenials = { tools: ['Bash', 'Write'] } -> deny specific tools
 * 4. isSubagent automatically denies subagent management tools
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { AgentFactory, createAgentFactory, type AgentFactoryConfig } from '../agent-factory.js';
import type { ToolDenialConfig } from '@capabilities/tools/index.js';

// =============================================================================
// Test Fixtures
// =============================================================================

function createMockConfig(overrides: Partial<AgentFactoryConfig> = {}): AgentFactoryConfig {
  return {
    getAuthForProvider: vi.fn().mockResolvedValue({
      type: 'api_key',
      apiKey: 'test-key',
    }),
    spawnSubsession: vi.fn().mockResolvedValue({ sessionId: 'sub_test' }),
    querySubagent: vi.fn().mockReturnValue({ status: 'pending' }),
    waitForSubagents: vi.fn().mockResolvedValue({ success: true }),
    forwardAgentEvent: vi.fn(),
    getSubagentTrackerForSession: vi.fn().mockReturnValue({
      spawn: vi.fn(),
      has: vi.fn().mockReturnValue(false),
    }),
    onTodosUpdated: vi.fn().mockResolvedValue(undefined),
    generateTodoId: () => 'todo_test123',
    dbPath: '/tmp/test.db',
    ...overrides,
  };
}

// =============================================================================
// Tests: Tool Denial System
// =============================================================================

describe('AgentFactory - Tool Denial System', () => {
  let config: AgentFactoryConfig;
  let factory: AgentFactory;

  beforeEach(() => {
    config = createMockConfig();
    factory = new AgentFactory(config);
  });

  describe('toolDenials = undefined (default behavior)', () => {
    it('includes all default tools when toolDenials is not specified', async () => {
      const agent = await factory.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514',
        undefined, // systemPrompt
        false,     // isSubagent
        undefined  // toolDenials - not specified
      );

      const tools = (agent as any).config.tools;
      const toolNames = tools.map((t: any) => t.name);

      // Should have core tools
      expect(toolNames).toContain('Read');
      expect(toolNames).toContain('Write');
      expect(toolNames).toContain('Edit');
      expect(toolNames).toContain('Bash');
      expect(toolNames).toContain('Search');
      expect(toolNames).toContain('Find');
      // Should have subagent tools (not a subagent)
      expect(toolNames).toContain('SpawnSubagent');
      expect(toolNames).toContain('QueryAgent');
      expect(toolNames).toContain('WaitForAgents');
    });
  });

  describe('toolDenials = { denyAll: true } (no tools)', () => {
    it('creates agent with zero tools when denyAll is true', async () => {
      const toolDenials: ToolDenialConfig = { denyAll: true };

      const agent = await factory.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-haiku-4-5-20251001',
        'You are a summarizer.',
        true,  // isSubagent
        toolDenials
      );

      const tools = (agent as any).config.tools;

      expect(tools).toEqual([]);
      expect(tools.length).toBe(0);
    });

    it('no-tools agent can still have system prompt', async () => {
      const customPrompt = 'You are a web content analyzer.';
      const toolDenials: ToolDenialConfig = { denyAll: true };

      const agent = await factory.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-haiku-4-5-20251001',
        customPrompt,
        true,
        toolDenials
      );

      const agentConfig = (agent as any).config;

      expect(agentConfig.tools).toEqual([]);
      expect(agentConfig.systemPrompt).toBe(customPrompt);
    });
  });

  describe('toolDenials = { tools: [...] } (deny specific tools)', () => {
    it('filters out denied tools', async () => {
      const toolDenials: ToolDenialConfig = {
        tools: ['Bash', 'Write', 'Edit'],
      };

      const agent = await factory.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514',
        undefined,
        false,
        toolDenials
      );

      const tools = (agent as any).config.tools;
      const toolNames = tools.map((t: any) => t.name);

      // Should NOT have denied tools
      expect(toolNames).not.toContain('Bash');
      expect(toolNames).not.toContain('Write');
      expect(toolNames).not.toContain('Edit');

      // Should have other tools
      expect(toolNames).toContain('Read');
      expect(toolNames).toContain('Search');
      expect(toolNames).toContain('Find');
    });

    it('keeps all tools not in the denial list', async () => {
      const toolDenials: ToolDenialConfig = {
        tools: ['SpawnSubagent'], // Only deny this one
      };

      const agent = await factory.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514',
        undefined,
        false,
        toolDenials
      );

      const tools = (agent as any).config.tools;
      const toolNames = tools.map((t: any) => t.name);

      expect(toolNames).not.toContain('SpawnSubagent');
      expect(toolNames).toContain('Read');
      expect(toolNames).toContain('Write');
      expect(toolNames).toContain('Edit');
      expect(toolNames).toContain('Bash');
    });
  });

  describe('isSubagent automatically denies subagent tools', () => {
    it('subagent cannot spawn other subagents', async () => {
      const agent = await factory.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514',
        undefined,
        true, // isSubagent = true
        undefined // No explicit denials
      );

      const tools = (agent as any).config.tools;
      const toolNames = tools.map((t: any) => t.name);

      // Subagent management tools should be denied
      expect(toolNames).not.toContain('SpawnSubagent');
      expect(toolNames).not.toContain('QueryAgent');
      expect(toolNames).not.toContain('WaitForAgents');

      // But other tools should be available
      expect(toolNames).toContain('Read');
      expect(toolNames).toContain('Write');
      expect(toolNames).toContain('Bash');
    });

    it('isSubagent denials are merged with explicit denials', async () => {
      const toolDenials: ToolDenialConfig = {
        tools: ['Bash', 'Write'],
      };

      const agent = await factory.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514',
        undefined,
        true, // isSubagent
        toolDenials
      );

      const tools = (agent as any).config.tools;
      const toolNames = tools.map((t: any) => t.name);

      // Explicit denials
      expect(toolNames).not.toContain('Bash');
      expect(toolNames).not.toContain('Write');

      // isSubagent denials
      expect(toolNames).not.toContain('SpawnSubagent');
      expect(toolNames).not.toContain('QueryAgent');
      expect(toolNames).not.toContain('WaitForAgents');

      // Should still have
      expect(toolNames).toContain('Read');
      expect(toolNames).toContain('Search');
    });

    it('denyAll takes precedence over isSubagent denials', async () => {
      const toolDenials: ToolDenialConfig = { denyAll: true };

      const agent = await factory.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-haiku-4-5-20251001',
        undefined,
        true, // isSubagent
        toolDenials
      );

      const tools = (agent as any).config.tools;
      expect(tools).toEqual([]);
    });
  });

  describe('non-subagent with no denials has all tools', () => {
    it('top-level agent has all tools including subagent management', async () => {
      const agent = await factory.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514',
        undefined,
        false, // NOT a subagent
        undefined // No denials
      );

      const tools = (agent as any).config.tools;
      const toolNames = tools.map((t: any) => t.name);

      // All tools should be available
      expect(toolNames).toContain('Read');
      expect(toolNames).toContain('Write');
      expect(toolNames).toContain('Edit');
      expect(toolNames).toContain('Bash');
      expect(toolNames).toContain('SpawnSubagent');
      expect(toolNames).toContain('QueryAgent');
      expect(toolNames).toContain('WaitForAgents');
    });
  });
});

// =============================================================================
// Tests: WebFetch Summarizer Use Case
// =============================================================================

describe('AgentFactory - WebFetch Summarizer Use Case', () => {
  it('can create a text-only Haiku subagent for summarization', async () => {
    const config = createMockConfig();
    const factory = new AgentFactory(config);

    const systemPrompt = `You are a web content analyzer.
Answer questions about the provided content concisely and accurately.
Do not make up information not present in the content.`;

    const toolDenials: ToolDenialConfig = { denyAll: true };

    const agent = await factory.createAgentForSession(
      'sess_summarizer',
      '/tmp/test',
      'claude-haiku-4-5-20251001',
      systemPrompt,
      true, // isSubagent
      toolDenials
    );

    const agentConfig = (agent as any).config;

    // No tools
    expect(agentConfig.tools).toEqual([]);

    // Custom system prompt
    expect(agentConfig.systemPrompt).toContain('web content analyzer');

    // Using Haiku model
    expect(agentConfig.provider.model).toBe('claude-haiku-4-5-20251001');
  });
});

// =============================================================================
// Tests: Subagent MaxTokens Configuration
// =============================================================================

describe('AgentFactory - Subagent MaxTokens', () => {
  let config: AgentFactoryConfig;
  let factory: AgentFactory;

  beforeEach(() => {
    config = createMockConfig();
    factory = new AgentFactory(config);
  });

  describe('subagent maxTokens based on model capacity', () => {
    it('sets maxTokens to 90% of model maxOutput for subagents', async () => {
      const agent = await factory.createAgentForSession(
        'sess_subagent',
        '/tmp/test',
        'claude-sonnet-4-5-20250929', // maxOutput: 64000
        undefined,
        true, // isSubagent
        undefined
      );

      const agentConfig = (agent as any).config;

      // Subagent should have maxTokens set to 90% of model's maxOutput (64000)
      // 64000 * 0.9 = 57600
      expect(agentConfig.maxTokens).toBe(57600);
    });

    it('uses 90% of model capacity for Claude 4.5 models', async () => {
      const agent = await factory.createAgentForSession(
        'sess_subagent',
        '/tmp/test',
        'claude-opus-4-5-20251101', // maxOutput: 64000
        undefined,
        true, // isSubagent
        undefined
      );

      const agentConfig = (agent as any).config;
      expect(agentConfig.maxTokens).toBe(57600); // 64000 * 0.9
    });

    it('does not set maxTokens for non-subagent (uses default)', async () => {
      const agent = await factory.createAgentForSession(
        'sess_normal',
        '/tmp/test',
        'claude-sonnet-4-5-20250929',
        undefined,
        false, // NOT a subagent
        undefined
      );

      const agentConfig = (agent as any).config;

      // Non-subagent should NOT have maxTokens set (uses provider default)
      expect(agentConfig.maxTokens).toBeUndefined();
    });

    it('falls back to default capacity if model not in registry', async () => {
      const agent = await factory.createAgentForSession(
        'sess_subagent',
        '/tmp/test',
        'claude-unknown-model', // Not in registry, defaults to maxOutput: 4096
        undefined,
        true, // isSubagent
        undefined
      );

      const agentConfig = (agent as any).config;

      // Default maxOutput is 4096, so 90% = 3686
      expect(agentConfig.maxTokens).toBe(3686); // Math.floor(4096 * 0.9)
    });
  });
});
