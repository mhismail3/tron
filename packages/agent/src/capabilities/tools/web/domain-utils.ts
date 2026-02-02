/**
 * @fileoverview Domain Utilities
 *
 * Shared utilities for URL domain extraction and matching.
 * Used by web search tools for domain filtering.
 */

/**
 * Extract domain (hostname) from a URL.
 *
 * @param url - URL string to extract domain from
 * @returns Lowercase hostname or undefined if URL is invalid
 *
 * @example
 * extractDomain('https://api.example.com/path') // 'api.example.com'
 * extractDomain('invalid') // undefined
 */
export function extractDomain(url: string): string | undefined {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return undefined;
  }
}

/**
 * Check if a hostname matches a domain pattern (including subdomains).
 *
 * @param hostname - The full hostname to check (e.g., 'api.example.com')
 * @param domain - The domain pattern to match (e.g., 'example.com')
 * @returns True if hostname matches domain exactly or is a subdomain
 *
 * @example
 * domainMatches('example.com', 'example.com') // true
 * domainMatches('api.example.com', 'example.com') // true
 * domainMatches('other.com', 'example.com') // false
 * domainMatches('notexample.com', 'example.com') // false
 */
export function domainMatches(hostname: string, domain: string): boolean {
  const h = hostname.toLowerCase();
  const d = domain.toLowerCase();
  return h === d || h.endsWith(`.${d}`);
}
