/**
 * @fileoverview Plugin type definitions for the dashboard
 */

import type { TronSessionEvent } from '@tron/agent';
import type { DashboardSessionSummary } from '../types/session.js';

/**
 * Props passed to event renderer plugins
 */
export interface EventRendererProps {
  event: TronSessionEvent;
  expanded: boolean;
  onToggle?: () => void;
}

/**
 * Event renderer plugin interface
 */
export interface EventRendererPlugin {
  /** Unique identifier for this plugin */
  id: string;

  /** Human-readable name */
  name: string;

  /** Check if this plugin can render the event */
  canRender(event: TronSessionEvent): boolean;

  /** Priority for rendering (higher = preferred) */
  priority: number;

  /** Render the event */
  render(props: EventRendererProps): React.ReactNode;
}

/**
 * Filter plugin interface
 */
export interface FilterPlugin {
  /** Unique identifier for this plugin */
  id: string;

  /** Human-readable name */
  name: string;

  /** Render the filter control UI */
  renderFilterControl(): React.ReactNode;

  /** Apply the filter to events */
  apply(events: TronSessionEvent[]): TronSessionEvent[];

  /** Get current filter state for serialization */
  getState(): unknown;

  /** Restore filter state */
  setState(state: unknown): void;
}

/**
 * Export format options
 */
export interface ExportOptions {
  /** Include session metadata */
  includeMetadata?: boolean;

  /** Include all events or filtered */
  filtered?: boolean;
}

/**
 * Export plugin interface
 */
export interface ExportPlugin {
  /** Unique identifier for this plugin */
  id: string;

  /** Human-readable name */
  name: string;

  /** File extension for exports */
  extension: string;

  /** MIME type for downloads */
  mimeType: string;

  /** Export session and events to the target format */
  export(
    session: DashboardSessionSummary,
    events: TronSessionEvent[],
    options?: ExportOptions
  ): Promise<Blob | string>;
}

/**
 * Plugin metadata
 */
export interface PluginMetadata {
  id: string;
  name: string;
  version: string;
  description?: string;
}
