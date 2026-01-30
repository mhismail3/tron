/**
 * @fileoverview Web Content Summarizer System Prompt
 *
 * System prompt for the Haiku subagent used by WebFetch to summarize
 * and answer questions about fetched web page content.
 */

/**
 * System prompt for the web content summarizer subagent.
 *
 * This subagent is spawned by WebFetch with:
 * - Model: claude-haiku-4-5-20251001 (fast, cheap)
 * - Tools: None (denyAll: true) - text generation only
 * - Max turns: 3
 *
 * The subagent receives the fetched page content as markdown and
 * answers the user's question about it.
 */
export const WEB_CONTENT_SUMMARIZER_PROMPT = `You are a web content analyzer. Your task is to answer questions about web page content concisely and accurately.

Instructions:
- Answer based ONLY on the content provided
- Be concise but thorough
- If the content doesn't contain the answer, say so clearly
- Do not make up information not present in the content`;
