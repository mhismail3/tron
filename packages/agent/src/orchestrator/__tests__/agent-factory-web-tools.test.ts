/**
 * @fileoverview Agent Factory Web Tools Integration Tests
 *
 * Tests for WebFetch and WebSearch tool instantiation in AgentFactory.
 * Verifies that:
 * 1. WebFetch tool is always added (uses real subagent for summarization)
 * 2. WebSearch tool is added when braveSearchApiKey is provided
 * 3. Blocked domains are passed correctly
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { AgentFactory, createAgentFactory, type AgentFactoryConfig } from '../agent-factory.js';
import { WebFetchTool, UnifiedSearchTool } from '../../tools/index.js';

// =============================================================================
// Test Fixtures
// =============================================================================

/**
 * Create a minimal mock AgentFactoryConfig for testing tool instantiation.
 */
function createMockConfig(overrides: Partial<AgentFactoryConfig> = {}): AgentFactoryConfig {
  return {
    getAuthForProvider: vi.fn().mockResolvedValue({
      type: 'api_key',
      apiKey: 'test-anthropic-key',
    }),
    spawnSubsession: vi.fn().mockResolvedValue({ sessionId: 'sub_test', success: true }),
    querySubagent: vi.fn().mockReturnValue({ status: 'pending' }),
    waitForSubagents: vi.fn().mockResolvedValue({ success: true }),
    forwardAgentEvent: vi.fn(),
    getSubagentTrackerForSession: vi.fn().mockReturnValue(undefined),
    onTodosUpdated: vi.fn().mockResolvedValue(undefined),
    generateTodoId: () => 'todo_test123',
    dbPath: '/tmp/test.db',
    ...overrides,
  };
}

// =============================================================================
// Unit Tests: createAgentFactory
// =============================================================================

describe('createAgentFactory', () => {
  it('creates an AgentFactory instance', () => {
    const config = createMockConfig();
    const factory = createAgentFactory(config);

    expect(factory).toBeInstanceOf(AgentFactory);
  });
});

// =============================================================================
// Unit Tests: Web Tools Instantiation
// =============================================================================

describe('AgentFactory Web Tools', () => {
  let config: AgentFactoryConfig;
  let factory: AgentFactory;

  beforeEach(() => {
    config = createMockConfig();
    factory = new AgentFactory(config);
  });

  describe('WebFetch tool', () => {
    it('is always added (uses real subagent for summarization)', async () => {
      // WebFetch no longer requires anthropicApiKey - uses real subagent spawning
      const configWithoutKey = createMockConfig();
      const factoryWithoutKey = new AgentFactory(configWithoutKey);

      const agent = await factoryWithoutKey.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514'
      );

      // Check that WebFetch IS in the tools list (always available now)
      const tools = (agent as any).config.tools;
      const webFetchTool = tools.find((t: any) => t.name === 'WebFetch');
      expect(webFetchTool).toBeDefined();
      expect(webFetchTool).toBeInstanceOf(WebFetchTool);
    });

    it('uses real subagent spawning callback', async () => {
      const spawnSubsessionMock = vi.fn().mockResolvedValue({
        sessionId: 'summarizer_123',
        success: true,
        output: 'Summarized content',
      });

      const configWithMock = createMockConfig({
        spawnSubsession: spawnSubsessionMock,
      });
      const factoryWithMock = new AgentFactory(configWithMock);

      const agent = await factoryWithMock.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514'
      );

      // WebFetch is configured with subagent spawning
      const tools = (agent as any).config.tools;
      const webFetchTool = tools.find((t: any) => t.name === 'WebFetch') as WebFetchTool;
      expect(webFetchTool).toBeDefined();

      // The onSpawnSubagent callback should be wired to spawnSubsession
      const toolConfig = (webFetchTool as any).config;
      expect(toolConfig.onSpawnSubagent).toBeDefined();
    });

    it('passes blocked domains to WebFetch URL validator', async () => {
      const blockedDomains = ['malware.com', 'phishing.net'];
      const configWithBlocked = createMockConfig({
        blockedWebDomains: blockedDomains,
      });
      const factoryWithBlocked = new AgentFactory(configWithBlocked);

      const agent = await factoryWithBlocked.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514'
      );

      // Check that WebFetch has the blocked domains configured
      const tools = (agent as any).config.tools;
      const webFetchTool = tools.find((t: any) => t.name === 'WebFetch') as WebFetchTool;
      expect(webFetchTool).toBeDefined();

      // The tool should have the URL validator with blocked domains
      const toolConfig = (webFetchTool as any).config;
      expect(toolConfig.urlValidator?.blockedDomains).toEqual(blockedDomains);
    });
  });

  describe('WebSearch tool', () => {
    it('is not added when braveSearchApiKey is not provided', async () => {
      // Config without braveSearchApiKey
      const configWithoutKey = createMockConfig();
      const factoryWithoutKey = new AgentFactory(configWithoutKey);

      const agent = await factoryWithoutKey.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514'
      );

      // Check that WebSearch is not in the tools list
      const tools = (agent as any).config.tools;
      const webSearchTool = tools.find((t: any) => t.name === 'WebSearch');
      expect(webSearchTool).toBeUndefined();
    });

    it('is added when braveSearchApiKey is provided', async () => {
      const configWithKey = createMockConfig({
        braveSearchApiKey: 'BSA-test-key-456',
      });
      const factoryWithKey = new AgentFactory(configWithKey);

      const agent = await factoryWithKey.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514'
      );

      // Check that WebSearch is in the tools list (now using UnifiedSearchTool)
      const tools = (agent as any).config.tools;
      const webSearchTool = tools.find((t: any) => t.name === 'WebSearch');
      expect(webSearchTool).toBeDefined();
      expect(webSearchTool).toBeInstanceOf(UnifiedSearchTool);
    });

    it('passes blocked domains to WebSearch', async () => {
      const blockedDomains = ['spam.com', 'ads.net'];
      const configWithBlocked = createMockConfig({
        braveSearchApiKey: 'BSA-test-key-456',
        blockedWebDomains: blockedDomains,
      });
      const factoryWithBlocked = new AgentFactory(configWithBlocked);

      const agent = await factoryWithBlocked.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514'
      );

      // Check that WebSearch has the blocked domains configured
      const tools = (agent as any).config.tools;
      const webSearchTool = tools.find((t: any) => t.name === 'WebSearch') as UnifiedSearchTool;
      expect(webSearchTool).toBeDefined();

      // The tool should have blocked domains configured (stored as configBlockedDomains)
      const configBlockedDomains = (webSearchTool as any).configBlockedDomains;
      expect(configBlockedDomains).toEqual(blockedDomains);
    });
  });

  describe('both tools together', () => {
    it('adds both tools when braveSearchApiKey is provided', async () => {
      const configWithBoth = createMockConfig({
        braveSearchApiKey: 'BSA-test-key-456',
      });
      const factoryWithBoth = new AgentFactory(configWithBoth);

      const agent = await factoryWithBoth.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514'
      );

      const tools = (agent as any).config.tools;
      const webFetchTool = tools.find((t: any) => t.name === 'WebFetch');
      const webSearchTool = tools.find((t: any) => t.name === 'WebSearch');

      expect(webFetchTool).toBeDefined();
      expect(webSearchTool).toBeDefined();
    });

    it('shares blocked domains between both tools', async () => {
      const blockedDomains = ['blocked.com', 'unwanted.org'];
      const configWithBoth = createMockConfig({
        braveSearchApiKey: 'BSA-test-key-456',
        blockedWebDomains: blockedDomains,
      });
      const factoryWithBoth = new AgentFactory(configWithBoth);

      const agent = await factoryWithBoth.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514'
      );

      const tools = (agent as any).config.tools;
      const webFetchTool = tools.find((t: any) => t.name === 'WebFetch');
      const webSearchTool = tools.find((t: any) => t.name === 'WebSearch');

      const fetchConfig = (webFetchTool as any).config;
      const searchBlockedDomains = (webSearchTool as any).configBlockedDomains;

      expect(fetchConfig.urlValidator?.blockedDomains).toEqual(blockedDomains);
      expect(searchBlockedDomains).toEqual(blockedDomains);
    });
  });

  describe('subagent sessions', () => {
    it('still includes web tools for subagent sessions', async () => {
      const configWithKeys = createMockConfig({
        braveSearchApiKey: 'BSA-test-key-456',
      });
      const factoryWithKeys = new AgentFactory(configWithKeys);

      // Create a subagent session (isSubagent = true)
      const agent = await factoryWithKeys.createAgentForSession(
        'sess_sub',
        '/tmp/test',
        'claude-sonnet-4-20250514',
        undefined,
        true // isSubagent
      );

      const tools = (agent as any).config.tools;
      const webFetchTool = tools.find((t: any) => t.name === 'WebFetch');
      const webSearchTool = tools.find((t: any) => t.name === 'WebSearch');

      // Web tools should be available to subagents too
      expect(webFetchTool).toBeDefined();
      expect(webSearchTool).toBeDefined();
    });
  });

  describe('WebFetch subagent spawning', () => {
    it('spawns subagent with toolDenials: denyAll for text-only mode', async () => {
      const spawnSubsessionMock = vi.fn().mockResolvedValue({
        sessionId: 'summarizer_456',
        success: true,
        output: 'Test answer',
      });

      const configWithMock = createMockConfig({
        spawnSubsession: spawnSubsessionMock,
      });
      const factoryWithMock = new AgentFactory(configWithMock);

      const agent = await factoryWithMock.createAgentForSession(
        'sess_test',
        '/tmp/test',
        'claude-sonnet-4-20250514'
      );

      // Get the WebFetch tool and its callback
      const tools = (agent as any).config.tools;
      const webFetchTool = tools.find((t: any) => t.name === 'WebFetch') as WebFetchTool;
      const toolConfig = (webFetchTool as any).config;

      // Call the onSpawnSubagent callback directly
      const result = await toolConfig.onSpawnSubagent({
        task: 'Test task',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 3,
      });

      // Verify the spawn was called with correct parameters
      expect(spawnSubsessionMock).toHaveBeenCalledTimes(1);
      const spawnCall = spawnSubsessionMock.mock.calls[0];

      // Check that toolDenials: { denyAll: true } was passed
      expect(spawnCall[1].toolDenials).toEqual({ denyAll: true });
      // Check that systemPrompt was passed
      expect(spawnCall[1].systemPrompt).toContain('web content analyzer');
      // Check that blocking: true was passed
      expect(spawnCall[1].blocking).toBe(true);
    });
  });
});
