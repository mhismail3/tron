/**
 * @fileoverview Core Tron System Prompt
 *
 * The main system prompt for Tron agents defining the assistant's
 * role and capabilities. This is provider-agnostic.
 *
 * The prompt content is stored in core.md and loaded at module initialization.
 * This allows editing the prompt as plain markdown without escaping.
 */

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Core Tron system prompt defining the assistant's role and capabilities.
 *
 * This is the DEFAULT prompt loaded from core.md at module initialization.
 * Users can override it by creating .tron/SYSTEM.md in their project directory.
 */
export const TRON_CORE_PROMPT: string = fs.readFileSync(
  path.join(__dirname, 'core.md'),
  'utf-8'
);

/**
 * Working directory template - append to system prompt
 */
export const WORKING_DIRECTORY_SUFFIX = '\n\nCurrent working directory: {workingDirectory}';
