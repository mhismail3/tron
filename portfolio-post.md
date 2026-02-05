---
title: Tron
slug: tron
date: 2026-02-05
summary: A personal AI coding agent built from scratch — event-sourced TypeScript server, native iOS client over WebSocket, multi-model LLM support, and a sub-agent system for parallel task execution. The whole stack is mine, from the system prompt to the context window.
github: https://github.com/mhismail3/tron
tags:
  - TypeScript
  - Swift
  - SwiftUI
  - SQLite
  - WebSocket
  - AI Agents
  - Event Sourcing
  - iOS
status: "🔄 Active"
cover: cover.jpg
gallery:
  - gallery-1.png
  - gallery-2.png
  - gallery-3.png
  - gallery-4.png
---

## Why Build Your Own Agent

I wrote about this a bit in a [previous blog post](/posts/2026-01-21-from-claude-code-wrappers-to-building-my-own-agent) — after spending weeks trying to wrap Claude Code through Telegram bots and Discord, I realized I was fighting someone else's abstractions. Parsing terminal output is fragile. The Agent SDK meant paying for API calls on top of a Max subscription. Everything felt like a workaround.

What I actually wanted was control. Control over the system prompt — what the agent knows, how it reasons, what persona it takes on. Control over the context window — when to compact, what to preserve, how to manage memory across sessions. Control over the execution layer — which tools are available, how they're validated, what happens before and after every action the agent takes.

So I built **Tron** from scratch. TypeScript server, event-sourced state, real-time streaming, multi-model LLM support, and eventually a native iOS app as the primary interface. It's been my daily driver for the past couple of months.

---

## The Architecture

The server runs as a persistent daemon on my Mac mini. It handles the full agent loop: receiving messages, constructing prompts, streaming LLM responses, executing tools, and recording everything as immutable events in SQLite.

The event sourcing part is the foundation everything else is built on. Every user message, every assistant response, every tool call and result — all of it gets written as an event with a `parentId` forming a tree structure. This means I can fork a session from any point in history, rewind if something goes wrong, or reconstruct the full state of any conversation by walking the event chain. It's not just for auditability — it's saved me real debugging time more than once.

On top of that sits a layered architecture: core types and dependency injection at the bottom, then infrastructure (logging, settings, auth), then the LLM provider layer, then capabilities (tools, hooks, guardrails), then the runtime (agent loop, context management), and finally the interface layer that exposes everything over JSON-RPC 2.0 via WebSocket.

### Multi-Model Support

Tron supports three LLM providers through a unified interface — Anthropic (Claude), OpenAI (GPT-4o, o1, o3), and Google (Gemini). Each provider follows the same composition pattern: an auth module, a message converter, a stream handler, and provider-specific types. Swapping models mid-session is a first-class operation. I mostly use Claude Opus 4.5, but being able to drop into Gemini Flash for quick tasks or test against GPT-4o keeps things flexible.

---

## From Terminal to iOS

I started with two interfaces: a terminal UI built with Ink (React for the terminal) and a React web app. Both connected to the server over WebSocket and worked fine for desktop use. But the whole reason I started this project was wanting to use my agent on the go — so pretty quickly the focus shifted to building a native iOS app.

The iOS client is pure SwiftUI with an MVVM architecture. Large view models are split across extension files to keep things manageable — `ChatViewModel+Connection.swift` handles WebSocket management, `ChatViewModel+Events.swift` handles event subscriptions, `ChatViewModel+Messaging.swift` handles sending messages, and so on. It streams responses in real-time, maintains a local event database for offline access, and supports push notifications via APNS so the agent can ping my phone when a long-running task finishes.

The transition from web to native was the right call. The app feels *responsive* in a way that a web client wrapped in a mobile browser never could — proper keyboard handling, native gestures, smooth streaming text. I can start a session on my laptop, walk away, and pick it up on my phone without missing a beat.

---

## The Hard Parts

### Context Management

This was probably the most underestimated challenge. LLMs have finite context windows, and when you're deep into a coding session — reading files, running commands, iterating on changes — you blow through tokens fast. I needed a system that could intelligently compact old conversation turns while preserving the important stuff.

Tron's context compaction tracks token usage against the model's limit and, when it hits a threshold, uses the LLM itself to summarize older turns into a compressed form. It preserves the most recent turns in full for recency, extracts structured facts and decisions from the summary, and records the whole operation as a compaction event. There's also a `PreCompact` hook so I can inject custom logic before compaction runs — useful for ensuring certain context never gets dropped.

On top of that, there's a four-level memory hierarchy: the system prompt sets the agent's baseline behavior, skills inject domain-specific knowledge, path-scoped rules files (like `AGENTS.md`) provide directory-level context, and session memory carries forward within a conversation. Getting the interplay between these layers right took a lot of iteration.

### Event Sourcing in Practice

The theory of event sourcing is clean. The practice is full of edge cases. What happens when a tool call times out — do you record the timeout as an event? (Yes.) What if the server crashes mid-tool-execution? (The event tree is append-only, so you just pick up from the last recorded event.) How do you handle forking when the forked branch has compacted context? (You reconstruct from the compaction event's summary plus subsequent events.)

The schema itself is straightforward — events table with `id`, `session_id`, `parent_id`, `sequence`, `depth`, `type`, `timestamp`, `payload`. Sessions point to a head event and root event. But the reconstruction logic, the fork/rewind operations, and making sure everything stays consistent under concurrent access — that's where the real work was.

### Streaming Across the Stack

Getting real-time streaming to feel right across three different LLM providers, a WebSocket transport layer, and a native iOS client required careful attention. Each provider has its own SSE format and quirks. The server normalizes everything into a unified event stream. The iOS app renders streaming text incrementally with proper SwiftUI state management so it doesn't jank. Small details like handling thinking blocks, tool-use deltas, and partial JSON in tool calls all needed individual attention.

---

## What Tron Can Do

Some of the things I've built into Tron that I haven't seen in other agent tools:

### Self-Deployment

The `Adapt` tool lets the agent deploy new versions of *itself*. It runs the build, runs the test suite, and if everything passes, hot-swaps the running binary via a detached process. The server restarts, clients reconnect, and the agent can verify the deployment succeeded. If something breaks, there's a rollback command. The agent improving its own code and shipping it to production is genuinely useful — and a little surreal.

### Sub-Agents with Tool Controls

Tron has a sub-agent system where the primary agent can spawn child agents for parallel task execution. The interesting part is the tool denial configuration — you can give a sub-agent access to all tools, restrict specific ones, or create a text-only sub-agent with no tool access at all. You can even deny specific *patterns* within a tool, like blocking `rm -rf` in Bash while allowing everything else. Sub-agents can run in-process (blocking, for quick tasks) or in a Tmux session (fire-and-forget, for long-running work).

### Hook System

Every tool call passes through a hook pipeline. `PreToolUse` hooks can block or modify calls before they execute — I use this for guardrails like preventing destructive shell commands. `PostToolUse` hooks run after execution for logging and integrations. There are hooks for session lifecycle, context compaction, user input validation, and sub-agent completion. All priority-ordered, with blocking hooks that must complete before the operation continues and background hooks that fail open.

### Native iOS Integration

The agent can push rich notifications to my phone, render custom SwiftUI interfaces for specific tool results (like showing a chip UI for deployment status), and accept voice input. The iOS app isn't just a chat window — it has session management, workspace switching, model selection, and the ability to browse the full event history of any session.

---

## Demos

Here are a few quick demos I recorded showing Tron in action:

<!-- TODO: Replace these placeholder URLs with your actual YouTube video URLs -->

<div class="video-demos">

### Starting a coding session from my phone
<iframe width="100%" height="315" src="https://www.youtube.com/embed/VIDEO_ID_1" frameborder="0" allowfullscreen></iframe>

### Agent self-deploying via the Adapt tool
<iframe width="100%" height="315" src="https://www.youtube.com/embed/VIDEO_ID_2" frameborder="0" allowfullscreen></iframe>

### Sub-agent parallel task execution
<iframe width="100%" height="315" src="https://www.youtube.com/embed/VIDEO_ID_3" frameborder="0" allowfullscreen></iframe>

</div>

---

## What's Next

The sub-agent system is the thing I'm most excited about. Right now it's a proof of concept — one primary agent spawning child agents for isolated tasks. But the foundation is there for real multi-agent workflows: agents that can coordinate, share context selectively, and divide complex projects into parallel workstreams.

I want to build a planning layer where a lead agent breaks down a task, delegates sub-tasks to specialized agents (one for implementation, one for testing, one for documentation), and synthesizes the results. The tool denial system already supports this — you can create agents with different capability profiles. The event sourcing means every agent's work is fully auditable and forkable. The pieces are all there, they just need to be composed.

Beyond multi-agent, I'm working on better memory persistence across sessions — so the agent builds up project-specific knowledge over time rather than starting cold every conversation. And there's more to do on the iOS side: better artifact rendering, collaborative editing views, and tighter integration with Xcode workflows.

The core is solid. I use it every day. But the interesting work is just getting started.

---

Code's on [GitHub](https://github.com/mhismail3/tron) if you want to take a look.
