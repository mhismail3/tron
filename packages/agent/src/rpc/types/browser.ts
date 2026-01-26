/**
 * @fileoverview Browser RPC Types
 *
 * Types for browser automation methods.
 */

// =============================================================================
// Browser Methods
// =============================================================================

/** Start browser stream for a session */
export interface BrowserStartStreamParams {
  /** Session ID that has an active browser */
  sessionId: string;
  /** Stream quality (JPEG quality 1-100, default: 60) */
  quality?: number;
  /** Maximum frame width (default: 1280) */
  maxWidth?: number;
  /** Maximum frame height (default: 800) */
  maxHeight?: number;
  /** Stream format (default: 'jpeg') */
  format?: 'jpeg' | 'png';
  /** Frame rate control - emit every Nth frame (default: 1) */
  everyNthFrame?: number;
}

export interface BrowserStartStreamResult {
  /** Whether streaming started successfully */
  success: boolean;
  /** Error message if failed */
  error?: string;
}

/** Stop browser stream for a session */
export interface BrowserStopStreamParams {
  /** Session ID to stop streaming for */
  sessionId: string;
}

export interface BrowserStopStreamResult {
  /** Whether streaming stopped successfully */
  success: boolean;
  /** Error message if failed */
  error?: string;
}

/** Get browser status for a session */
export interface BrowserGetStatusParams {
  /** Session ID to check */
  sessionId: string;
}

export interface BrowserGetStatusResult {
  /** Whether the session has an active browser */
  hasBrowser: boolean;
  /** Whether the browser is currently streaming frames */
  isStreaming: boolean;
  /** Current URL if browser is active */
  currentUrl?: string;
}

/**
 * Event data for browser frame streaming
 * Sent from server to client when browser frames are captured
 */
export interface BrowserFrameEvent {
  /** Session ID the frame belongs to */
  sessionId: string;
  /** Base64-encoded frame data (JPEG or PNG) */
  data: string;
  /** Frame sequence number (from CDP sessionId) */
  frameId: number;
  /** Timestamp when frame was captured */
  timestamp: number;
  /** Optional frame metadata from CDP */
  metadata?: {
    /** Offset from top of viewport */
    offsetTop?: number;
    /** Page scale factor */
    pageScaleFactor?: number;
    /** Device width */
    deviceWidth?: number;
    /** Device height */
    deviceHeight?: number;
    /** Horizontal scroll offset */
    scrollOffsetX?: number;
    /** Vertical scroll offset */
    scrollOffsetY?: number;
  };
}
