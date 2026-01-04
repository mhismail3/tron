/**
 * @fileoverview Command Parser
 *
 * Parses slash commands and provides fuzzy filtering.
 */

import type { ParsedCommand, CommandMatch } from './types.js';
import { getCommands } from './registry.js';

// =============================================================================
// Parsing
// =============================================================================

/**
 * Check if input is a command (starts with /)
 */
export function isCommand(input: string): boolean {
  return input.startsWith('/');
}

/**
 * Parse a slash command from input
 */
export function parseCommand(input: string): ParsedCommand | null {
  if (!isCommand(input)) {
    return null;
  }

  const trimmed = input.slice(1).trim(); // Remove leading /
  if (!trimmed) {
    return null;
  }

  const parts = trimmed.split(/\s+/);
  const name = parts[0]?.toLowerCase() ?? '';
  const args = parts.slice(1);

  return {
    name,
    args,
    raw: input,
  };
}

/**
 * Extract partial command name from input
 * Returns empty string if input is just "/"
 */
export function getPartialCommand(input: string): string {
  if (!isCommand(input)) {
    return '';
  }

  const afterSlash = input.slice(1);
  const firstSpace = afterSlash.indexOf(' ');

  if (firstSpace === -1) {
    return afterSlash.toLowerCase();
  }

  return afterSlash.slice(0, firstSpace).toLowerCase();
}

// =============================================================================
// Fuzzy Matching
// =============================================================================

/**
 * Calculate fuzzy match score between query and target
 * Returns score and matched character indices
 */
function fuzzyMatch(
  query: string,
  target: string,
): { score: number; matchedChars: number[] } | null {
  const queryLower = query.toLowerCase();
  const targetLower = target.toLowerCase();

  if (!query) {
    return { score: 1, matchedChars: [] }; // Empty query matches everything
  }

  const matchedChars: number[] = [];
  let queryIndex = 0;
  let consecutiveMatches = 0;
  let score = 0;

  for (let i = 0; i < targetLower.length && queryIndex < queryLower.length; i++) {
    if (targetLower[i] === queryLower[queryIndex]) {
      matchedChars.push(i);

      // Bonus for consecutive matches
      if (matchedChars.length > 1 && matchedChars[matchedChars.length - 2] === i - 1) {
        consecutiveMatches++;
        score += consecutiveMatches * 2;
      } else {
        consecutiveMatches = 0;
        score += 1;
      }

      // Bonus for matching at start
      if (i === 0) {
        score += 10;
      }

      // Bonus for matching after separator
      if (i > 0 && (targetLower[i - 1] === '-' || targetLower[i - 1] === '_')) {
        score += 5;
      }

      queryIndex++;
    }
  }

  // All query characters must match
  if (queryIndex !== queryLower.length) {
    return null;
  }

  // Bonus for shorter targets (exact or near-exact matches)
  score += Math.max(0, 10 - (target.length - query.length));

  return { score, matchedChars };
}

// =============================================================================
// Filtering
// =============================================================================

/**
 * Filter commands by partial query
 */
export function filterCommands(query: string): CommandMatch[] {
  const commands = getCommands();
  const matches: CommandMatch[] = [];

  for (const command of commands) {
    // Try matching name
    let result = fuzzyMatch(query, command.name);
    if (result) {
      matches.push({
        command,
        score: result.score,
        matchedChars: result.matchedChars,
      });
      continue;
    }

    // Try matching alias
    if (command.alias) {
      result = fuzzyMatch(query, command.alias);
      if (result) {
        matches.push({
          command,
          score: result.score - 1, // Slight penalty for alias match
          matchedChars: result.matchedChars,
        });
        continue;
      }
    }

    // Try matching description
    result = fuzzyMatch(query, command.description);
    if (result) {
      matches.push({
        command,
        score: result.score - 5, // Penalty for description match
        matchedChars: [],
      });
    }
  }

  // Sort by score (descending)
  return matches.sort((a, b) => b.score - a.score);
}

/**
 * Get top N command matches
 */
export function getTopMatches(query: string, limit = 5): CommandMatch[] {
  return filterCommands(query).slice(0, limit);
}
