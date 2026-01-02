/**
 * @fileoverview Context Viewer Component
 *
 * Displays the context audit in an interactive, scrollable view.
 * Shows exactly what was loaded into context on session start.
 *
 * Triggered via /context command or keyboard shortcut.
 */
import React, { useState, useMemo } from 'react';
import { Box, Text, useInput } from 'ink';
import type { ContextAuditData } from '@tron/core';

interface ContextViewerProps {
  audit: ContextAuditData;
  onClose: () => void;
}

type ViewTab = 'summary' | 'files' | 'ledger' | 'handoffs' | 'tokens';

export function ContextViewer({ audit, onClose }: ContextViewerProps): React.ReactElement {
  const [activeTab, setActiveTab] = useState<ViewTab>('summary');
  const [scrollOffset, setScrollOffset] = useState(0);

  const tabs: ViewTab[] = ['summary', 'files', 'ledger', 'handoffs', 'tokens'];

  useInput((input, key) => {
    if (input === 'q' || key.escape) {
      onClose();
    } else if (key.leftArrow || input === 'h') {
      const idx = tabs.indexOf(activeTab);
      const newIdx = idx > 0 ? idx - 1 : tabs.length - 1;
      setActiveTab(tabs[newIdx] ?? 'summary');
      setScrollOffset(0);
    } else if (key.rightArrow || input === 'l') {
      const idx = tabs.indexOf(activeTab);
      const newIdx = (idx + 1) % tabs.length;
      setActiveTab(tabs[newIdx] ?? 'summary');
      setScrollOffset(0);
    } else if (key.upArrow || input === 'k') {
      setScrollOffset(prev => Math.max(0, prev - 1));
    } else if (key.downArrow || input === 'j') {
      setScrollOffset(prev => prev + 1);
    }
  });

  const content = useMemo(() => {
    switch (activeTab) {
      case 'summary':
        return renderSummary(audit);
      case 'files':
        return renderContextFiles(audit);
      case 'ledger':
        return renderLedger(audit);
      case 'handoffs':
        return renderHandoffs(audit);
      case 'tokens':
        return renderTokens(audit);
      default:
        return [];
    }
  }, [activeTab, audit]);

  const visibleLines = content.slice(scrollOffset, scrollOffset + 20);

  return (
    <Box flexDirection="column" borderStyle="round" borderColor="blue" padding={1}>
      {/* Header */}
      <Box marginBottom={1}>
        <Text bold color="cyan">Context Audit</Text>
        <Text dimColor> - Session {audit.session.id.slice(0, 8)}</Text>
      </Box>

      {/* Tab bar */}
      <Box marginBottom={1}>
        {tabs.map((tab, idx) => (
          <React.Fragment key={tab}>
            {idx > 0 && <Text dimColor> | </Text>}
            <Text
              color={activeTab === tab ? 'green' : undefined}
              bold={activeTab === tab}
            >
              {tab.charAt(0).toUpperCase() + tab.slice(1)}
            </Text>
          </React.Fragment>
        ))}
      </Box>

      {/* Content */}
      <Box flexDirection="column" height={20}>
        {visibleLines.map((line, idx) => (
          <Text key={idx}>{line}</Text>
        ))}
        {content.length === 0 && <Text dimColor>No data available</Text>}
      </Box>

      {/* Scroll indicator */}
      {content.length > 20 && (
        <Box marginTop={1}>
          <Text dimColor>
            Lines {scrollOffset + 1}-{Math.min(scrollOffset + 20, content.length)} of {content.length}
          </Text>
        </Box>
      )}

      {/* Help */}
      <Box marginTop={1}>
        <Text dimColor>←/→ switch tabs | ↑/↓ scroll | q/ESC close</Text>
      </Box>
    </Box>
  );
}

function renderSummary(audit: ContextAuditData): string[] {
  const lines: string[] = [];

  lines.push(`Session Type: ${audit.session.type}`);
  lines.push(`Started: ${audit.session.startedAt.toISOString()}`);
  lines.push(`Working Dir: ${audit.session.workingDirectory}`);
  lines.push(`Model: ${audit.session.model}`);
  lines.push(`Provider: ${audit.session.provider}`);
  lines.push('');
  lines.push('--- Quick Stats ---');
  lines.push(`Context Files: ${audit.contextFiles.length}`);
  lines.push(`Handoffs Loaded: ${audit.handoffs.length}`);
  lines.push(`Tools Registered: ${audit.tools.length}`);
  lines.push(`Hook Modifications: ${audit.hookModifications.length}`);
  lines.push('');
  lines.push('--- Token Budget ---');
  lines.push(`Context: ~${audit.tokenEstimates.contextTokens} tokens`);
  lines.push(`System Prompt: ~${audit.tokenEstimates.systemPromptTokens} tokens`);
  lines.push(`Tools: ~${audit.tokenEstimates.toolTokens} tokens`);
  lines.push(`Total Base: ~${audit.tokenEstimates.totalBaseTokens} tokens`);

  if (audit.session.parentSessionId) {
    lines.push('');
    lines.push('--- Fork/Resume Info ---');
    lines.push(`Parent Session: ${audit.session.parentSessionId}`);
    if (audit.session.forkPoint !== undefined) {
      lines.push(`Fork Point: Message ${audit.session.forkPoint}`);
    }
  }

  return lines;
}

function renderContextFiles(audit: ContextAuditData): string[] {
  const lines: string[] = [];

  if (audit.contextFiles.length === 0) {
    lines.push('No context files loaded');
    return lines;
  }

  for (const file of audit.contextFiles) {
    lines.push(`[${file.type.toUpperCase()}] ${file.path}`);
    lines.push(`  ${file.charCount} chars, ${file.lineCount} lines`);
    lines.push(`  Loaded: ${file.loadedAt.toISOString()}`);
    lines.push('');
    lines.push('  Preview:');
    const previewLines = file.preview.split('\n').slice(0, 5);
    for (const pl of previewLines) {
      lines.push(`  │ ${pl.slice(0, 70)}${pl.length > 70 ? '...' : ''}`);
    }
    lines.push('');
  }

  return lines;
}

function renderLedger(audit: ContextAuditData): string[] {
  const lines: string[] = [];

  if (!audit.ledger) {
    lines.push('No ledger state loaded');
    return lines;
  }

  const ledger = audit.ledger;

  if (ledger.now) {
    lines.push(`Working On: ${ledger.now}`);
  }
  if (ledger.next && ledger.next.length > 0) {
    lines.push('');
    lines.push('Next Steps:');
    for (const step of ledger.next) {
      lines.push(`  • ${step}`);
    }
  }
  if (ledger.done && ledger.done.length > 0) {
    lines.push('');
    lines.push('Completed:');
    for (const item of ledger.done.slice(-5)) {
      lines.push(`  ✓ ${item}`);
    }
  }
  if (ledger.constraints && ledger.constraints.length > 0) {
    lines.push('');
    lines.push('Constraints:');
    for (const c of ledger.constraints) {
      lines.push(`  ! ${c}`);
    }
  }
  if (ledger.workingFiles && ledger.workingFiles.length > 0) {
    lines.push('');
    lines.push('Working Files:');
    for (const f of ledger.workingFiles) {
      lines.push(`  - ${f}`);
    }
  }
  if (ledger.decisions && ledger.decisions.length > 0) {
    lines.push('');
    lines.push('Decisions:');
    for (const d of ledger.decisions.slice(-5)) {
      lines.push(`  → ${d.choice}: ${d.reason}`);
    }
  }

  return lines;
}

function renderHandoffs(audit: ContextAuditData): string[] {
  const lines: string[] = [];

  if (audit.handoffs.length === 0) {
    lines.push('No handoffs loaded');
    return lines;
  }

  for (const handoff of audit.handoffs) {
    lines.push(`[${handoff.id.slice(0, 8)}] From session ${handoff.sessionId.slice(0, 8)}`);
    lines.push(`Created: ${handoff.timestamp.toISOString()}`);
    lines.push(`Size: ${handoff.charCount} chars`);
    lines.push('');
    lines.push('Summary:');
    const summaryLines = handoff.summary.split('\n');
    for (const sl of summaryLines.slice(0, 5)) {
      lines.push(`  ${sl.slice(0, 70)}${sl.length > 70 ? '...' : ''}`);
    }
    lines.push('');
    lines.push('---');
    lines.push('');
  }

  return lines;
}

function renderTokens(audit: ContextAuditData): string[] {
  const lines: string[] = [];

  lines.push('=== Token Usage Breakdown ===');
  lines.push('');
  lines.push('Context Files:');

  let totalContextChars = 0;
  for (const file of audit.contextFiles) {
    const tokens = Math.ceil(file.charCount / 4);
    lines.push(`  ${file.path}: ~${tokens} tokens (${file.charCount} chars)`);
    totalContextChars += file.charCount;
  }
  lines.push(`  Subtotal: ~${Math.ceil(totalContextChars / 4)} tokens`);
  lines.push('');

  lines.push('System Prompt Sections:');
  for (const section of audit.systemPrompt.sections) {
    const tokens = Math.ceil(section.charCount / 4);
    lines.push(`  ${section.name}: ~${tokens} tokens (from ${section.source})`);
  }
  lines.push(`  Total: ~${Math.ceil(audit.systemPrompt.totalCharCount / 4)} tokens`);
  lines.push('');

  lines.push('Tools:');
  for (const tool of audit.tools) {
    const tokens = Math.ceil((tool.name.length + tool.description.length + tool.schemaCharCount) / 4);
    lines.push(`  ${tool.name}: ~${tokens} tokens`);
  }
  lines.push(`  Subtotal: ~${audit.tokenEstimates.toolTokens} tokens`);
  lines.push('');

  lines.push('Hook Modifications:');
  if (audit.hookModifications.length === 0) {
    lines.push('  (none)');
  } else {
    for (const mod of audit.hookModifications) {
      const delta = mod.charDelta >= 0 ? `+${mod.charDelta}` : `${mod.charDelta}`;
      lines.push(`  ${mod.hookId} (${mod.event}): ${delta} chars`);
    }
  }
  lines.push('');

  lines.push('=== Total Base Context ===');
  lines.push(`~${audit.tokenEstimates.totalBaseTokens} tokens before user messages`);

  return lines;
}

export default ContextViewer;
