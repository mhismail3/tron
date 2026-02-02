/**
 * @fileoverview Tests for URL Validator
 *
 * TDD: Tests for URL validation including format, security, and domain filtering.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { validateUrl, UrlValidator } from '../url-validator.js';
import type { UrlValidatorConfig } from '../types.js';

describe('URL Validator', () => {
  describe('validateUrl function', () => {
    describe('valid URLs', () => {
      it('should accept HTTPS URLs', () => {
        const result = validateUrl('https://example.com');
        expect(result.valid).toBe(true);
        expect(result.url).toBe('https://example.com/');
      });

      it('should auto-upgrade HTTP to HTTPS', () => {
        const result = validateUrl('http://example.com');
        expect(result.valid).toBe(true);
        expect(result.url).toBe('https://example.com/');
      });

      it('should accept URLs with paths', () => {
        const result = validateUrl('https://example.com/path/to/page');
        expect(result.valid).toBe(true);
        expect(result.url).toBe('https://example.com/path/to/page');
      });

      it('should accept URLs with query parameters', () => {
        const result = validateUrl('https://example.com/search?q=test&page=1');
        expect(result.valid).toBe(true);
        expect(result.url).toContain('q=test');
      });

      it('should accept URLs with fragments', () => {
        const result = validateUrl('https://example.com/page#section');
        expect(result.valid).toBe(true);
        expect(result.url).toContain('#section');
      });

      it('should accept URLs with ports', () => {
        const result = validateUrl('https://example.com:8080/path');
        expect(result.valid).toBe(true);
        expect(result.url).toContain(':8080');
      });

      it('should accept URLs with subdomains', () => {
        const result = validateUrl('https://api.v2.example.com/endpoint');
        expect(result.valid).toBe(true);
        expect(result.url).toContain('api.v2.example.com');
      });

      it('should accept internationalized domain names', () => {
        const result = validateUrl('https://münchen.example.com');
        expect(result.valid).toBe(true);
      });

      it('should handle URLs without protocol by adding HTTPS', () => {
        const result = validateUrl('example.com/path');
        expect(result.valid).toBe(true);
        expect(result.url).toBe('https://example.com/path');
      });

      it('should accept www prefix', () => {
        const result = validateUrl('https://www.example.com');
        expect(result.valid).toBe(true);
      });
    });

    describe('invalid URLs', () => {
      it('should reject empty strings', () => {
        const result = validateUrl('');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INVALID_FORMAT');
      });

      it('should reject whitespace-only strings', () => {
        const result = validateUrl('   ');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INVALID_FORMAT');
      });

      it('should reject malformed URLs', () => {
        const result = validateUrl('not a url at all');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INVALID_FORMAT');
      });

      it('should reject file:// URLs', () => {
        const result = validateUrl('file:///etc/passwd');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INVALID_PROTOCOL');
      });

      it('should reject javascript: URLs', () => {
        const result = validateUrl('javascript:alert(1)');
        expect(result.valid).toBe(false);
        // May be INVALID_FORMAT or INVALID_PROTOCOL depending on how URL parser handles it
        expect(['INVALID_FORMAT', 'INVALID_PROTOCOL']).toContain(result.error?.code);
      });

      it('should reject data: URLs', () => {
        const result = validateUrl('data:text/html,<script>alert(1)</script>');
        expect(result.valid).toBe(false);
        // May be INVALID_FORMAT or INVALID_PROTOCOL depending on how URL parser handles it
        expect(['INVALID_FORMAT', 'INVALID_PROTOCOL']).toContain(result.error?.code);
      });

      it('should reject URLs with credentials', () => {
        const result = validateUrl('https://user:pass@example.com');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('CREDENTIALS_IN_URL');
      });

      it('should reject URLs with just username', () => {
        const result = validateUrl('https://user@example.com');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('CREDENTIALS_IN_URL');
      });

      it('should reject URLs exceeding max length', () => {
        const longPath = 'a'.repeat(2500);
        const result = validateUrl(`https://example.com/${longPath}`);
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('URL_TOO_LONG');
      });

      it('should reject localhost by default', () => {
        const result = validateUrl('https://localhost/api');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INTERNAL_ADDRESS');
      });

      it('should reject 127.0.0.1', () => {
        const result = validateUrl('https://127.0.0.1/api');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INTERNAL_ADDRESS');
      });

      it('should reject 0.0.0.0', () => {
        const result = validateUrl('https://0.0.0.0/');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INTERNAL_ADDRESS');
      });

      it('should reject private IP ranges (10.x.x.x)', () => {
        const result = validateUrl('https://10.0.0.1/internal');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INTERNAL_ADDRESS');
      });

      it('should reject private IP ranges (172.16-31.x.x)', () => {
        const result = validateUrl('https://172.16.0.1/internal');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INTERNAL_ADDRESS');
      });

      it('should reject private IP ranges (192.168.x.x)', () => {
        const result = validateUrl('https://192.168.1.1/router');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INTERNAL_ADDRESS');
      });

      it('should reject IPv6 localhost', () => {
        const result = validateUrl('https://[::1]/api');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INTERNAL_ADDRESS');
      });

      it('should reject .local domains', () => {
        const result = validateUrl('https://myserver.local/api');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INTERNAL_ADDRESS');
      });

      it('should reject .internal domains', () => {
        const result = validateUrl('https://server.internal/');
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('INTERNAL_ADDRESS');
      });
    });

    describe('domain filtering', () => {
      it('should allow URL when domain is in allowedDomains', () => {
        const result = validateUrl('https://github.com/repo', {
          allowedDomains: ['github.com', 'gitlab.com'],
        });
        expect(result.valid).toBe(true);
      });

      it('should reject URL when domain is not in allowedDomains', () => {
        const result = validateUrl('https://example.com/path', {
          allowedDomains: ['github.com', 'gitlab.com'],
        });
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('DOMAIN_NOT_ALLOWED');
      });

      it('should handle subdomain matching for allowedDomains', () => {
        const result = validateUrl('https://api.github.com/users', {
          allowedDomains: ['github.com'],
        });
        expect(result.valid).toBe(true);
      });

      it('should block URL when domain is in blockedDomains', () => {
        const result = validateUrl('https://malware.com/bad', {
          blockedDomains: ['malware.com', 'phishing.com'],
        });
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('DOMAIN_BLOCKED');
      });

      it('should handle subdomain matching for blockedDomains', () => {
        const result = validateUrl('https://sub.malware.com/bad', {
          blockedDomains: ['malware.com'],
        });
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('DOMAIN_BLOCKED');
      });

      it('should allow URL when domain is not in blockedDomains', () => {
        const result = validateUrl('https://example.com/good', {
          blockedDomains: ['malware.com'],
        });
        expect(result.valid).toBe(true);
      });

      it('should check blockedDomains before allowedDomains', () => {
        const result = validateUrl('https://blocked.com/path', {
          allowedDomains: ['blocked.com'],
          blockedDomains: ['blocked.com'],
        });
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('DOMAIN_BLOCKED');
      });

      it('should handle empty allowedDomains as allow all', () => {
        const result = validateUrl('https://any-domain.com/path', {
          allowedDomains: [],
        });
        expect(result.valid).toBe(true);
      });

      it('should be case-insensitive for domain matching', () => {
        const result = validateUrl('https://GITHUB.COM/repo', {
          allowedDomains: ['github.com'],
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('configuration options', () => {
      it('should allow custom max length', () => {
        const longPath = 'a'.repeat(100);
        const result = validateUrl(`https://example.com/${longPath}`, {
          maxLength: 50,
        });
        expect(result.valid).toBe(false);
        expect(result.error?.code).toBe('URL_TOO_LONG');
      });

      it('should allow internal addresses when configured', () => {
        const result = validateUrl('https://localhost/api', {
          allowInternal: true,
        });
        expect(result.valid).toBe(true);
      });

      it('should allow 127.0.0.1 when internal is allowed', () => {
        const result = validateUrl('https://127.0.0.1:3000/api', {
          allowInternal: true,
        });
        expect(result.valid).toBe(true);
      });
    });
  });

  describe('UrlValidator class', () => {
    let validator: UrlValidator;

    beforeEach(() => {
      validator = new UrlValidator();
    });

    it('should create validator with default config', () => {
      expect(validator).toBeDefined();
    });

    it('should validate URLs using instance method', () => {
      const result = validator.validate('https://example.com');
      expect(result.valid).toBe(true);
    });

    it('should use configured settings', () => {
      validator = new UrlValidator({
        blockedDomains: ['blocked.com'],
      });
      const result = validator.validate('https://blocked.com/path');
      expect(result.valid).toBe(false);
    });

    it('should extract domain from URL', () => {
      const domain = validator.extractDomain('https://api.example.com/path');
      expect(domain).toBe('api.example.com');
    });

    it('should check if domain matches pattern', () => {
      expect(validator.domainMatches('api.github.com', 'github.com')).toBe(true);
      expect(validator.domainMatches('github.com', 'github.com')).toBe(true);
      expect(validator.domainMatches('notgithub.com', 'github.com')).toBe(false);
    });
  });
});
