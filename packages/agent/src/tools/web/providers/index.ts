/**
 * @fileoverview Search Providers Module
 *
 * Exports unified provider interface and implementations.
 */

// Types
export type {
  ProviderName,
  ContentType,
  Freshness,
  ProviderCapabilities,
  ProviderSearchParams,
  UnifiedResult,
  SearchProvider,
} from './types.js';

export {
  BRAVE_CAPABILITIES,
  EXA_CAPABILITIES,
  freshnessToBrave,
  freshnessToExaDate,
  contentTypeToBraveEndpoint,
  contentTypeToExaCategory,
} from './types.js';

// Provider implementations
export { BraveProvider, type BraveProviderConfig } from './brave-provider.js';
export { ExaProvider, type ExaProviderConfig } from './exa-provider.js';
