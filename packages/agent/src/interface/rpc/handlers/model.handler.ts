/**
 * @fileoverview Model RPC Handlers
 *
 * Handlers for model.* RPC methods:
 * - model.switch: Switch session to a different model
 * - model.list: List available models across all providers
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type {
  ModelSwitchParams,
  ModelListResult,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { ANTHROPIC_MODELS, OPENAI_CODEX_MODELS } from '@llm/providers/models.js';
import { GEMINI_MODELS } from '@llm/providers/google/index.js';
import { InvalidParamsError } from './base.js';

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create model handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createModelHandlers(): MethodRegistration[] {
  const switchHandler: MethodHandler<ModelSwitchParams> = async (request, context) => {
    const params = request.params!;

    // Validate model exists (check all providers)
    const anthropicModel = ANTHROPIC_MODELS.find((m) => m.id === params.model);
    const codexModel = OPENAI_CODEX_MODELS.find((m) => m.id === params.model);
    const geminiModel = params.model in GEMINI_MODELS ? GEMINI_MODELS[params.model] : undefined;
    if (!anthropicModel && !codexModel && !geminiModel) {
      throw new InvalidParamsError(`Unknown model: ${params.model}`);
    }

    return context.sessionManager.switchModel(params.sessionId, params.model);
  };

  const listHandler: MethodHandler = async () => {
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
    return result;
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
