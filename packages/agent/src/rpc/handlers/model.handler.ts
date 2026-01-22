/**
 * @fileoverview Model RPC Handlers
 *
 * Handlers for model.* RPC methods:
 * - model.switch: Switch session to a different model
 * - model.list: List available models across all providers
 */

import type {
  RpcRequest,
  RpcResponse,
  ModelSwitchParams,
  ModelListResult,
} from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';
import { ANTHROPIC_MODELS, OPENAI_CODEX_MODELS } from '../../providers/models.js';
import { GEMINI_MODELS } from '../../providers/google.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle model.switch request
 *
 * Switches the session to use a different model.
 * Validates that the model exists across all providers.
 */
export async function handleModelSwitch(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as ModelSwitchParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }
  if (!params?.model) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'model is required');
  }

  // Validate model exists (check all providers)
  const anthropicModel = ANTHROPIC_MODELS.find((m) => m.id === params.model);
  const codexModel = OPENAI_CODEX_MODELS.find((m) => m.id === params.model);
  const geminiModel = params.model in GEMINI_MODELS ? GEMINI_MODELS[params.model] : undefined;
  if (!anthropicModel && !codexModel && !geminiModel) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', `Unknown model: ${params.model}`);
  }

  const result = await context.sessionManager.switchModel(params.sessionId, params.model);
  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle model.list request
 *
 * Returns a list of all available models across all providers
 * with their capabilities and tiers.
 */
export async function handleModelList(
  request: RpcRequest,
  _context: RpcContext
): Promise<RpcResponse> {
  // Build model list from all providers
  const models: ModelListResult['models'] = [
    // Anthropic models
    ...ANTHROPIC_MODELS.map((m) => ({
      id: m.id,
      name: m.shortName,
      provider: 'anthropic',
      contextWindow: m.contextWindow,
      supportsThinking: m.supportsThinking,
      supportsImages: true, // All Claude models support images
      tier: m.tier,
      isLegacy: m.legacy ?? false,
    })),
    // OpenAI Codex models
    ...OPENAI_CODEX_MODELS.map((m) => ({
      id: m.id,
      name: m.shortName,
      provider: 'openai-codex',
      contextWindow: m.contextWindow,
      supportsThinking: false,
      supportsImages: true,
      supportsReasoning: m.supportsReasoning,
      reasoningLevels: m.reasoningLevels,
      defaultReasoningLevel: m.defaultReasoningLevel,
      tier: m.tier,
      isLegacy: false,
    })),
    // Google Gemini models
    ...Object.entries(GEMINI_MODELS).map(([id, m]) => ({
      id,
      name: m.shortName,
      provider: 'google',
      contextWindow: m.contextWindow,
      supportsThinking: m.supportsThinking,
      supportsImages: true, // Gemini supports images
      tier: m.tier,
      isLegacy: false,
      isPreview: m.preview ?? false,
      thinkingLevel: m.defaultThinkingLevel,
      supportedThinkingLevels: m.supportedThinkingLevels,
    })),
  ];

  const result: ModelListResult = { models };
  return MethodRegistry.successResponse(request.id, result);
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create model handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createModelHandlers(): MethodRegistration[] {
  const switchHandler: MethodHandler = async (request, context) => {
    const response = await handleModelSwitch(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const listHandler: MethodHandler = async (request, context) => {
    const response = await handleModelList(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw new Error(response.error?.message || 'Unknown error');
  };

  return [
    {
      method: 'model.switch',
      handler: switchHandler,
      options: {
        requiredParams: ['sessionId', 'model'],
        requiredManagers: ['sessionManager'],
        description: 'Switch session to a different model',
      },
    },
    {
      method: 'model.list',
      handler: listHandler,
      options: {
        description: 'List available models',
      },
    },
  ];
}
