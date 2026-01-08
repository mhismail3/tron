#!/usr/bin/env npx tsx
/**
 * Test script for Tron Agent
 *
 * Usage:
 *   ANTHROPIC_API_KEY=your-key npx tsx test-agent.ts "your prompt here"
 *
 * Example:
 *   ANTHROPIC_API_KEY=sk-ant-xxx npx tsx test-agent.ts "What files are in the current directory?"
 */
import { TronAgent, ReadTool, WriteTool, EditTool, BashTool, } from './packages/core/src/index.js';
// Get API key from environment
const apiKey = process.env.ANTHROPIC_API_KEY;
if (!apiKey) {
    console.error('❌ Error: ANTHROPIC_API_KEY environment variable is required');
    console.error('');
    console.error('Usage:');
    console.error('  ANTHROPIC_API_KEY=your-key npx tsx test-agent.ts "your prompt"');
    process.exit(1);
}
// Get prompt from command line
const prompt = process.argv.slice(2).join(' ');
if (!prompt) {
    console.error('❌ Error: Please provide a prompt');
    console.error('');
    console.error('Usage:');
    console.error('  ANTHROPIC_API_KEY=your-key npx tsx test-agent.ts "What files are in this directory?"');
    process.exit(1);
}
// Working directory
const workingDirectory = process.cwd();
// Create tools
const tools = [
    new ReadTool({ workingDirectory }),
    new WriteTool({ workingDirectory }),
    new EditTool({ workingDirectory }),
    new BashTool({ workingDirectory }),
];
// Create agent
const agent = new TronAgent({
    provider: {
        model: 'claude-sonnet-4-20250514',
        auth: {
            type: 'api_key',
            apiKey,
        },
    },
    tools,
    systemPrompt: `You are Tron, a helpful coding assistant. You have access to tools for reading files, writing files, editing files, and running bash commands.

Working directory: ${workingDirectory}

Be concise and helpful. When using tools, explain what you're doing.`,
    maxTurns: 10,
});
// Track state for display
let currentText = '';
let isInToolCall = false;
// Listen to events
agent.onEvent((event) => {
    switch (event.type) {
        case 'agent_start':
            console.log('\n🤖 Tron Agent Starting...\n');
            console.log(`📁 Working directory: ${workingDirectory}`);
            console.log(`💬 Prompt: "${prompt}"\n`);
            console.log('─'.repeat(60));
            break;
        case 'turn_start':
            if ('turn' in event) {
                console.log(`\n📍 Turn ${event.turn}`);
            }
            break;
        case 'message_update':
            if ('content' in event) {
                process.stdout.write(event.content);
                currentText += event.content;
            }
            break;
        case 'tool_execution_start':
            if ('toolName' in event) {
                if (currentText) {
                    console.log('\n');
                }
                console.log(`\n🔧 Executing: ${event.toolName}`);
                isInToolCall = true;
                currentText = '';
            }
            break;
        case 'tool_execution_end':
            if ('toolName' in event && 'duration' in event) {
                const status = 'isError' in event && event.isError ? '❌' : '✅';
                console.log(`${status} ${event.toolName} completed (${event.duration}ms)`);
                isInToolCall = false;
            }
            break;
        case 'turn_end':
            if ('duration' in event) {
                console.log(`\n⏱️  Turn completed in ${event.duration}ms`);
            }
            break;
        case 'agent_end':
            console.log('\n' + '─'.repeat(60));
            if ('error' in event && event.error) {
                console.log(`\n❌ Agent ended with error: ${event.error}`);
            }
            else {
                console.log('\n✅ Agent completed successfully');
            }
            break;
    }
});
// Run the agent
console.log('');
try {
    const result = await agent.run(prompt);
    console.log(`\n📊 Stats:`);
    console.log(`   Turns: ${result.turns}`);
    console.log(`   Tokens: ${result.totalTokenUsage.input} in / ${result.totalTokenUsage.output} out`);
    if (!result.success) {
        console.error(`\n❌ Failed: ${result.error}`);
        process.exit(1);
    }
}
catch (error) {
    console.error(`\n❌ Error: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
}
//# sourceMappingURL=test-agent.js.map