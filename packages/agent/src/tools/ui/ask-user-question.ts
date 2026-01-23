/**
 * @fileoverview AskUserQuestion Tool
 *
 * An interactive tool that allows the agent to ask the user questions
 * with multiple choice options.
 *
 * ASYNC MODEL: The tool returns immediately with a summary of the questions.
 * The user's answers are submitted as a new user prompt to continue the
 * conversation. This enables:
 * - No blocking or timeouts
 * - User can answer at their leisure
 * - Agent turn ends cleanly after presenting questions
 */

import type { TronTool, TronToolResult } from '../../types/index.js';
import type { AskUserQuestionParams } from '../../types/ask-user-question.js';
import { validateAskUserQuestionParams } from '../../types/ask-user-question.js';
import { createLogger } from '../../logging/logger.js';

const logger = createLogger('tool:ask-user-question');

/**
 * Configuration for AskUserQuestion tool
 */
export interface AskUserQuestionConfig {
  workingDirectory: string;
}

export class AskUserQuestionTool implements TronTool<AskUserQuestionParams> {
  readonly name = 'AskUserQuestion';
  readonly description = `Ask the user interactive questions with multiple choice options.

Use this tool when you need to:
- Get user preferences or choices
- Clarify requirements before proceeding
- Present options for the user to select from
- Get approval for a plan or action

The user will see a question sheet with selectable options. Questions can be single-select
(choose one) or multi-select (choose multiple). You can also allow free-form "Other" input.

Rules:
- Maximum 5 questions per call
- Each question must have at least 2 options
- Question IDs must be unique within the call

IMPORTANT: When using this tool, do NOT output any text response after calling it.
The question tool should be the FINAL action in your response. The user will see the
questions in a dedicated UI and their answers will come back as a new message. Do not
add any explanatory text, summaries, or follow-up comments after the tool call.`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      questions: {
        type: 'array' as const,
        description: 'Array of questions to ask (1-5 questions)',
        items: {
          type: 'object' as const,
          properties: {
            id: {
              type: 'string' as const,
              description: 'Unique identifier for this question',
            },
            question: {
              type: 'string' as const,
              description: 'The question text to display',
            },
            options: {
              type: 'array' as const,
              description: 'Available options (minimum 2)',
              items: {
                type: 'object' as const,
                properties: {
                  label: {
                    type: 'string' as const,
                    description: 'Display text for the option',
                  },
                  value: {
                    type: 'string' as const,
                    description: 'Value returned when selected (defaults to label)',
                  },
                  description: {
                    type: 'string' as const,
                    description: 'Optional description for the option',
                  },
                },
                required: ['label'] as string[],
              },
              minItems: 2,
            },
            mode: {
              type: 'string' as const,
              enum: ['single', 'multi'],
              description: 'single: choose one, multi: choose multiple',
            },
            allowOther: {
              type: 'boolean' as const,
              description: 'Allow free-form "Other" response',
            },
            otherPlaceholder: {
              type: 'string' as const,
              description: 'Placeholder text for the "Other" input field',
            },
          },
          required: ['id', 'question', 'options', 'mode'] as string[],
        },
        minItems: 1,
        maxItems: 5,
      },
      context: {
        type: 'string' as const,
        description: 'Optional context to display with the questions',
      },
    },
    required: ['questions'] as string[],
  };

  readonly label = 'Ask User Question';
  readonly category = 'custom' as const;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  constructor(_config: AskUserQuestionConfig) {
    // Config accepted for API compatibility, not currently used in async mode
  }

  async execute(
    args: Record<string, unknown>,
    options?: {
      toolCallId?: string;
      sessionId?: string;
      signal?: AbortSignal;
    }
  ): Promise<TronToolResult> {
    const params = args as unknown as AskUserQuestionParams;

    // Validate parameters
    const validation = validateAskUserQuestionParams(params);
    if (!validation.valid) {
      return {
        content: `Invalid parameters: ${validation.error}`,
        isError: true,
        details: { validation },
      };
    }

    const toolCallId = options?.toolCallId;
    const sessionId = options?.sessionId;

    logger.info('Presenting questions to user (async mode)', {
      sessionId,
      toolCallId,
      questionCount: params.questions.length,
    });

    // ASYNC MODEL: Return immediately with formatted question summary.
    // The questions are already captured in the tool.call event that the
    // iOS app will render. User answers will come back as a new prompt.
    const formattedSummary = this.formatQuestionsForAgent(params);

    return {
      content: formattedSummary,
      isError: false,
      // Stop the turn immediately - don't loop back to the API
      // User answers will come as a new prompt in the next turn
      stopTurn: true,
      details: {
        async: true,
        questionCount: params.questions.length,
      },
    };
  }

  /**
   * Format questions into a summary string for the agent
   */
  private formatQuestionsForAgent(params: AskUserQuestionParams): string {
    const lines: string[] = ['Questions presented to user:'];

    params.questions.forEach((q, i) => {
      const optionLabels = q.options.map(o => o.label).join(' / ');
      lines.push(`${i + 1}. ${q.question} (${optionLabels})`);
    });

    lines.push('');
    lines.push('Awaiting user response...');

    return lines.join('\n');
  }
}
