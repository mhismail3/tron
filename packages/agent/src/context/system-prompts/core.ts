/**
 * @fileoverview Core Tron System Prompt
 *
 * The main system prompt for Tron agents defining the assistant's
 * role and capabilities. This is provider-agnostic.
 *
 * The prompt content is stored in core.md and loaded at module initialization.
 * This allows editing the prompt as plain markdown without escaping.
 */

import { existsSync, readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Core Tron system prompt defining the assistant's role and capabilities.
 *
 * This is the DEFAULT prompt loaded from core.md at module initialization.
 * Users can override it by creating .tron/SYSTEM.md in their project directory.
 *
 * Path resolution supports both tsc build (core.md is sibling) and
 * esbuild production bundle (core.md is in system-prompts/ subdirectory).
 */
const coreMdPath = existsSync(join(__dirname, 'core.md'))
  ? join(__dirname, 'core.md')
  : join(__dirname, 'system-prompts', 'core.md');

export const TRON_CORE_PROMPT: string = readFileSync(coreMdPath, 'utf-8');

/**
 * Working directory template - append to system prompt
 */
export const WORKING_DIRECTORY_SUFFIX = '\n\nCurrent working directory: {workingDirectory}';
