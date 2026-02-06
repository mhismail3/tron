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
import { ANTHROPIC_MODELS } from '@llm/providers/models.js';
import { OPENAI_MODELS } from '@llm/providers/openai/index.js';
import { GEMINI_MODELS } from '@llm/providers/google/index.js';
import { InvalidParamsError } from './base.js';

// =============================================================================
// Helpers
// =============================================================================

/**
 * Derive Gemini family from model ID.
 * "gemini-3-pro-preview" → "Gemini 3"
 * "gemini-2.5-flash" → "Gemini 2.5"
 */
function deriveGeminiFamily(modelId: string): string {
  if (modelId.includes('gemini-3')) return 'Gemini 3';
  if (modelId.includes('gemini-2.5')) return 'Gemini 2.5';
  if (modelId.includes('gemini-2')) return 'Gemini 2';
  return 'Gemini';
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
  const switchHandler: MethodHandler<ModelSwitchParams> = async (request, context) => {
    const params = request.params!;

    // Validate model exists (check all providers)
    const anthropicModel = ANTHROPIC_MODELS.find((m) => m.id === params.model);
    const codexModel = params.model in OPENAI_MODELS ? OPENAI_MODELS[params.model] : undefined;
    const geminiModel = params.model in GEMINI_MODELS ? GEMINI_MODELS[params.model] : undefined;
    if (!anthropicModel && !codexModel && !geminiModel) {
      throw new InvalidParamsError(`Unknown model: ${params.model}`);
    }

    return context.sessionManager.switchModel(params.sessionId, params.model);
  };

  const listHandler: MethodHandler = async () => {
    // Build model list from all providers
    const models: ModelListResult['models'] = [
      // Anthropic models — all metadata directly from ANTHROPIC_MODELS
      ...ANTHROPIC_MODELS.map((m) => ({
        id: m.id,
        name: m.shortName,
        provider: 'anthropic',
        contextWindow: m.contextWindow,
        supportsThinking: m.supportsThinking,
        supportsImages: true, // All Claude models support images
        supportsReasoning: m.supportsReasoning ?? false,
        reasoningLevels: m.reasoningLevels,
        defaultReasoningLevel: m.defaultReasoningLevel,
        tier: m.tier,
        isLegacy: m.legacy ?? false,
        family: m.family,
        maxOutput: m.maxOutput,
        description: m.description,
        inputCostPerMillion: m.inputCostPerMillion,
        outputCostPerMillion: m.outputCostPerMillion,
        recommended: m.recommended ?? false,
        releaseDate: m.releaseDate,
      })),
      // OpenAI Codex models — all metadata directly from OPENAI_MODELS
      ...Object.entries(OPENAI_MODELS).map(([id, m]) => ({
        id,
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
        family: m.family,
        maxOutput: m.maxOutput,
        description: m.description,
        inputCostPerMillion: m.inputCostPerMillion,
        outputCostPerMillion: m.outputCostPerMillion,
        recommended: m.recommended,
      })),
      // Google Gemini models — derive family from ID, normalize pricing from per-1k
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
        family: deriveGeminiFamily(id),
        maxOutput: m.maxOutput,
        description: `${m.name} — ${m.tier} tier${m.preview ? ' (preview)' : ''}`,
        inputCostPerMillion: m.inputCostPer1k * 1000,
        outputCostPerMillion: m.outputCostPer1k * 1000,
        recommended: m.tier === 'pro' && id.includes('gemini-3'),
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
