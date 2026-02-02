/**
 * @fileoverview Branded Types for Type Safety
 *
 * Branded types provide compile-time type safety for string identifiers.
 */

// =============================================================================
// Branded Types
// =============================================================================

/** Globally unique event identifier (UUID v7 for time-ordering) */
export type EventId = string & { readonly __brand: 'EventId' };

/** Session identifier - groups related events */
export type SessionId = string & { readonly __brand: 'SessionId' };

/** Workspace identifier - project/directory scope */
export type WorkspaceId = string & { readonly __brand: 'WorkspaceId' };

/** Branch identifier for named branches */
export type BranchId = string & { readonly __brand: 'BranchId' };

// Type constructors
export const EventId = (id: string): EventId => id as EventId;
export const SessionId = (id: string): SessionId => id as SessionId;
export const WorkspaceId = (id: string): WorkspaceId => id as WorkspaceId;
export const BranchId = (id: string): BranchId => id as BranchId;
