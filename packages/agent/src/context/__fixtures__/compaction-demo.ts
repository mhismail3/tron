#!/usr/bin/env npx tsx
/**
 * Compaction Demo - Test the ContextManager compaction flow without burning tokens
 *
 * Run with: npx tsx packages/agent/test/context/compaction-demo.ts
 */

import { createContextManager } from '../context-manager.js';
import { ContextSimulator } from './context-simulator.js';
import { createMockSummarizer } from './mock-summarizer.js';

async function main() {
  console.log('='.repeat(70));
  console.log('ContextManager Compaction Demo');
  console.log('='.repeat(70));

  // Create a ContextManager for Claude (200k context)
  const cm = createContextManager({
    model: 'claude-sonnet-4-20250514',
    workingDirectory: '/Users/demo/project',
  });

  console.log('\n📊 Initial State:');
  console.log(`   Model: ${cm.getModel()}`);
  console.log(`   Context Limit: ${cm.getContextLimit().toLocaleString()} tokens`);
  console.log(`   Provider: ${cm.getProviderType()}`);
  console.log(`   System Prompt: "${cm.getSystemPrompt().substring(0, 50)}..."`);

  // Generate a simulated session at 85% context (alert threshold)
  console.log('\n🔧 Simulating session at 85% context usage...');
  const simulator = new ContextSimulator({ targetTokens: 170000, seed: 12345 });
  const session = simulator.generateSession();

  // Load messages into ContextManager
  cm.setMessages(session.messages);

  console.log(`   Generated ${session.turnCount} turns, ${session.messages.length} messages`);
  console.log(`   Estimated tokens: ${session.estimatedTokens.toLocaleString()}`);

  // Check thresholds
  const snapshot = cm.getSnapshot();
  console.log('\n📈 Context Snapshot:');
  console.log(`   Current Tokens: ${snapshot.currentTokens.toLocaleString()}`);
  console.log(`   Usage: ${(snapshot.usagePercent * 100).toFixed(1)}%`);
  console.log(`   Threshold Level: ${snapshot.thresholdLevel.toUpperCase()}`);
  console.log(`   Breakdown:`);
  console.log(`     - System Prompt: ${snapshot.breakdown.systemPrompt.toLocaleString()} tokens`);
  console.log(`     - Tools: ${snapshot.breakdown.tools.toLocaleString()} tokens`);
  console.log(`     - Messages: ${snapshot.breakdown.messages.toLocaleString()} tokens`);

  // Check if compaction is needed
  console.log('\n⚠️  Compaction Check:');
  console.log(`   shouldCompact(): ${cm.shouldCompact()}`);

  const validation = cm.canAcceptTurn({ estimatedResponseTokens: 5000 });
  console.log(`   canAcceptTurn({ estimatedResponseTokens: 5000 }):`);
  console.log(`     - canProceed: ${validation.canProceed}`);
  console.log(`     - needsCompaction: ${validation.needsCompaction}`);
  console.log(`     - wouldExceedLimit: ${validation.wouldExceedLimit}`);

  // Preview compaction (using mock summarizer - no API calls!)
  console.log('\n🔮 Compaction Preview (using mock summarizer):');
  const summarizer = createMockSummarizer();
  const preview = await cm.previewCompaction({ summarizer });

  console.log(`   Tokens Before: ${preview.tokensBefore.toLocaleString()}`);
  console.log(`   Tokens After: ${preview.tokensAfter.toLocaleString()}`);
  console.log(`   Compression Ratio: ${(preview.compressionRatio * 100).toFixed(1)}%`);
  console.log(`   Preserved Turns: ${preview.preservedTurns}`);
  console.log(`   Summarized Turns: ${preview.summarizedTurns}`);
  console.log(`   Summary Preview: "${preview.summary.substring(0, 100)}..."`);

  // Execute compaction
  console.log('\n✅ Executing Compaction...');
  const result = await cm.executeCompaction({ summarizer });

  console.log(`   Success: ${result.success}`);
  console.log(`   Tokens Before: ${result.tokensBefore.toLocaleString()}`);
  console.log(`   Tokens After: ${result.tokensAfter.toLocaleString()}`);
  console.log(`   Reduction: ${((1 - result.compressionRatio) * 100).toFixed(1)}%`);

  // Check state after compaction
  const afterSnapshot = cm.getSnapshot();
  console.log('\n📉 After Compaction:');
  console.log(`   Current Tokens: ${afterSnapshot.currentTokens.toLocaleString()}`);
  console.log(`   Usage: ${(afterSnapshot.usagePercent * 100).toFixed(1)}%`);
  console.log(`   Threshold Level: ${afterSnapshot.thresholdLevel.toUpperCase()}`);
  console.log(`   Messages: ${cm.getMessages().length}`);

  // Show the compacted messages structure
  console.log('\n📝 Compacted Message Structure:');
  const messages = cm.getMessages();
  for (let i = 0; i < Math.min(3, messages.length); i++) {
    const msg = messages[i];
    const content = typeof msg.content === 'string'
      ? msg.content.substring(0, 60)
      : '[complex content]';
    console.log(`   ${i + 1}. [${msg.role}] "${content}..."`);
  }
  if (messages.length > 3) {
    console.log(`   ... and ${messages.length - 3} more messages`);
  }

  // Test model switching
  console.log('\n🔄 Model Switching Test:');
  console.log(`   Current model: ${cm.getModel()} (${cm.getProviderType()})`);
  console.log(`   Switching to gpt-5.2-codex...`);

  cm.switchModel('gpt-5.2-codex');

  console.log(`   New model: ${cm.getModel()} (${cm.getProviderType()})`);
  console.log(`   New context limit: ${cm.getContextLimit().toLocaleString()}`);
  console.log(`   System prompt empty (Codex uses tool clarification): ${cm.getSystemPrompt() === ''}`);
  console.log(`   Tool clarification available: ${cm.getToolClarificationMessage() !== null}`);

  console.log('\n' + '='.repeat(70));
  console.log('Demo Complete! All compaction operations work without API calls.');
  console.log('='.repeat(70));
}

main().catch(console.error);
