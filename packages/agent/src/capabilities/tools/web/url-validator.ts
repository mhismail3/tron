/**
 * @fileoverview URL Validator
 *
 * Validates URLs for WebFetch tool with security checks and domain filtering.
 */

import type {
  UrlValidationResult,
  UrlValidatorConfig,
} from './types.js';

const DEFAULT_MAX_LENGTH = 2000;

/**
 * Private IP address patterns
 */
const INTERNAL_PATTERNS = {
  localhost: /^localhost$/i,
  loopbackIPv4: /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/,
  zeroAddress: /^0\.0\.0\.0$/,
  privateClassA: /^10\.\d{1,3}\.\d{1,3}\.\d{1,3}$/,
  privateClassB: /^172\.(1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3}$/,
  privateClassC: /^192\.168\.\d{1,3}\.\d{1,3}$/,
  loopbackIPv6: /^\[?::1\]?$/,
  localDomain: /\.local$/i,
  internalDomain: /\.internal$/i,
};

/**
 * Allowed URL protocols
 */
const ALLOWED_PROTOCOLS = new Set(['http:', 'https:']);

/**
 * Validate a URL and return the result
 *
 * @param url - URL string to validate
 * @param config - Optional validation configuration
 * @returns Validation result with normalized URL or error
 */
export function validateUrl(
  url: string,
  config: UrlValidatorConfig = {}
): UrlValidationResult {
  const {
    maxLength = DEFAULT_MAX_LENGTH,
    allowedDomains = [],
    blockedDomains = [],
    allowInternal = false,
  } = config;

  // Trim and check for empty
  const trimmedUrl = url?.trim() ?? '';
  if (!trimmedUrl) {
    return {
      valid: false,
      error: {
        code: 'INVALID_FORMAT',
        message: 'URL cannot be empty',
      },
    };
  }

  // Check length before processing
  if (trimmedUrl.length > maxLength) {
    return {
      valid: false,
      error: {
        code: 'URL_TOO_LONG',
        message: `URL exceeds maximum length of ${maxLength} characters`,
        details: { length: trimmedUrl.length, maxLength },
      },
    };
  }

  // Add protocol if missing
  let urlWithProtocol = trimmedUrl;
  if (!trimmedUrl.includes('://')) {
    urlWithProtocol = `https://${trimmedUrl}`;
  }

  // Parse URL
  let parsedUrl: URL;
  try {
    parsedUrl = new URL(urlWithProtocol);
  } catch {
    return {
      valid: false,
      error: {
        code: 'INVALID_FORMAT',
        message: 'Invalid URL format',
        details: { url: trimmedUrl },
      },
    };
  }

  // Check protocol
  const protocol = parsedUrl.protocol.toLowerCase();
  if (!ALLOWED_PROTOCOLS.has(protocol)) {
    return {
      valid: false,
      error: {
        code: 'INVALID_PROTOCOL',
        message: `Invalid protocol: ${protocol}. Only HTTP and HTTPS are allowed`,
        details: { protocol },
      },
    };
  }

  // Check for credentials in URL
  if (parsedUrl.username || parsedUrl.password) {
    return {
      valid: false,
      error: {
        code: 'CREDENTIALS_IN_URL',
        message: 'URLs with embedded credentials are not allowed',
      },
    };
  }

  // Get hostname for further checks
  const hostname = parsedUrl.hostname.toLowerCase();

  // Check for internal addresses (unless explicitly allowed)
  if (!allowInternal) {
    const internalCheck = isInternalAddress(hostname);
    if (internalCheck) {
      return {
        valid: false,
        error: {
          code: 'INTERNAL_ADDRESS',
          message: `Internal addresses are not allowed: ${hostname}`,
          details: { hostname, pattern: internalCheck },
        },
      };
    }
  }

  // Check blocked domains first (takes precedence)
  if (blockedDomains.length > 0) {
    for (const blockedDomain of blockedDomains) {
      if (domainMatches(hostname, blockedDomain.toLowerCase())) {
        return {
          valid: false,
          error: {
            code: 'DOMAIN_BLOCKED',
            message: `Domain is blocked: ${hostname}`,
            details: { hostname, blockedDomain },
          },
        };
      }
    }
  }

  // Check allowed domains (if specified)
  if (allowedDomains.length > 0) {
    const isAllowed = allowedDomains.some((allowedDomain) =>
      domainMatches(hostname, allowedDomain.toLowerCase())
    );
    if (!isAllowed) {
      return {
        valid: false,
        error: {
          code: 'DOMAIN_NOT_ALLOWED',
          message: `Domain is not in the allowed list: ${hostname}`,
          details: { hostname, allowedDomains },
        },
      };
    }
  }

  // Upgrade to HTTPS if HTTP
  if (protocol === 'http:') {
    parsedUrl.protocol = 'https:';
  }

  // Final length check after normalization
  const normalizedUrl = parsedUrl.href;
  if (normalizedUrl.length > maxLength) {
    return {
      valid: false,
      error: {
        code: 'URL_TOO_LONG',
        message: `Normalized URL exceeds maximum length of ${maxLength} characters`,
        details: { length: normalizedUrl.length, maxLength },
      },
    };
  }

  return {
    valid: true,
    url: normalizedUrl,
  };
}

/**
 * Check if a hostname is an internal/private address
 *
 * @param hostname - Hostname to check
 * @returns The matching pattern name if internal, null otherwise
 */
function isInternalAddress(hostname: string): string | null {
  for (const [name, pattern] of Object.entries(INTERNAL_PATTERNS)) {
    if (pattern.test(hostname)) {
      return name;
    }
  }
  return null;
}

/**
 * Check if a hostname matches a domain pattern (including subdomains)
 *
 * @param hostname - Full hostname to check
 * @param domain - Domain pattern to match against
 * @returns True if the hostname matches or is a subdomain
 */
export function domainMatches(hostname: string, domain: string): boolean {
  // Exact match
  if (hostname === domain) {
    return true;
  }
  // Subdomain match (hostname ends with .domain)
  if (hostname.endsWith(`.${domain}`)) {
    return true;
  }
  return false;
}

/**
 * URL Validator class for reusable validation with configuration
 */
export class UrlValidator {
  private config: UrlValidatorConfig;

  constructor(config: UrlValidatorConfig = {}) {
    this.config = config;
  }

  /**
   * Validate a URL using the configured settings
   */
  validate(url: string): UrlValidationResult {
    return validateUrl(url, this.config);
  }

  /**
   * Extract the domain (hostname) from a URL
   */
  extractDomain(url: string): string | null {
    try {
      const parsed = new URL(url);
      return parsed.hostname.toLowerCase();
    } catch {
      return null;
    }
  }

  /**
   * Check if a hostname matches a domain pattern
   */
  domainMatches(hostname: string, domain: string): boolean {
    return domainMatches(hostname, domain);
  }

  /**
   * Update configuration
   */
  updateConfig(config: Partial<UrlValidatorConfig>): void {
    this.config = { ...this.config, ...config };
  }

  /**
   * Get current configuration
   */
  getConfig(): UrlValidatorConfig {
    return { ...this.config };
  }
}
