/**
 * @fileoverview Chat component exports
 */

// Legacy components (still available for backwards compatibility)
export { MessageBubble, type Message } from './MessageBubble.js';
export { ToolCallCard, type ToolCall } from './ToolCallCard.js';

// New terminal-style components
export { MessageItem, type MessageItemProps } from './MessageItem.js';
export { MessageList, type MessageListProps } from './MessageList.js';
export { ThinkingBlock, type ThinkingBlockProps } from './ThinkingBlock.js';
export { StreamingContent, type StreamingContentProps } from './StreamingContent.js';
export { WelcomeBox, type WelcomeBoxProps } from './WelcomeBox.js';
export { ToolIndicator, type ToolIndicatorProps } from './ToolIndicator.js';

// Input components
export { InputBar } from './InputBar.js';
export { StatusBar } from './StatusBar.js';

// Main chat area
export { ChatArea, type ChatAreaProps } from './ChatArea.js';
