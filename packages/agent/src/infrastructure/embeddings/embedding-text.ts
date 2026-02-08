/**
 * @fileoverview Embedding Text Builder
 *
 * Builds the text to embed from a memory ledger payload.
 * Concatenates the most semantically relevant fields.
 */

import type { MemoryLedgerPayload } from '@infrastructure/events/types/memory.js';

export function buildEmbeddingText(payload: MemoryLedgerPayload): string {
  const parts: string[] = [];

  if (payload.title) parts.push(payload.title);
  if (payload.input) parts.push(payload.input);
  if (payload.actions?.length) parts.push(payload.actions.join('. '));
  if (payload.lessons?.length) parts.push(payload.lessons.join('. '));
  if (payload.decisions?.length) {
    parts.push(payload.decisions.map(d => `${d.choice}: ${d.reason}`).join('. '));
  }
  if (payload.tags?.length) parts.push(payload.tags.join(' '));

  return parts.join('\n');
}
