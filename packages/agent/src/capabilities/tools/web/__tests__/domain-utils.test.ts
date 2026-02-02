/**
 * @fileoverview Domain Utilities Tests
 */

import { describe, it, expect } from 'vitest';
import { extractDomain, domainMatches } from '../domain-utils.js';

describe('extractDomain', () => {
  it('should extract domain from https URL', () => {
    expect(extractDomain('https://example.com/path')).toBe('example.com');
  });

  it('should extract domain from http URL', () => {
    expect(extractDomain('http://example.com/path')).toBe('example.com');
  });

  it('should extract domain with subdomain', () => {
    expect(extractDomain('https://api.example.com/v1/users')).toBe('api.example.com');
  });

  it('should extract domain with port', () => {
    expect(extractDomain('https://example.com:8080/path')).toBe('example.com');
  });

  it('should normalize domain to lowercase', () => {
    expect(extractDomain('https://EXAMPLE.COM/path')).toBe('example.com');
    expect(extractDomain('https://Api.Example.COM/path')).toBe('api.example.com');
  });

  it('should handle URL with query string', () => {
    expect(extractDomain('https://example.com/path?query=value')).toBe('example.com');
  });

  it('should handle URL with fragment', () => {
    expect(extractDomain('https://example.com/path#section')).toBe('example.com');
  });

  it('should return undefined for invalid URL', () => {
    expect(extractDomain('not-a-url')).toBeUndefined();
    expect(extractDomain('')).toBeUndefined();
    expect(extractDomain('://missing-protocol.com')).toBeUndefined();
  });

  it('should handle IP addresses', () => {
    expect(extractDomain('http://192.168.1.1/path')).toBe('192.168.1.1');
    expect(extractDomain('http://127.0.0.1:3000/')).toBe('127.0.0.1');
  });

  it('should handle localhost', () => {
    expect(extractDomain('http://localhost:3000/')).toBe('localhost');
  });
});

describe('domainMatches', () => {
  it('should match exact domain', () => {
    expect(domainMatches('example.com', 'example.com')).toBe(true);
  });

  it('should match subdomain', () => {
    expect(domainMatches('api.example.com', 'example.com')).toBe(true);
    expect(domainMatches('www.example.com', 'example.com')).toBe(true);
    expect(domainMatches('deep.nested.example.com', 'example.com')).toBe(true);
  });

  it('should not match different domain', () => {
    expect(domainMatches('other.com', 'example.com')).toBe(false);
  });

  it('should not match domain suffix collision', () => {
    // 'notexample.com' should NOT match 'example.com'
    expect(domainMatches('notexample.com', 'example.com')).toBe(false);
    expect(domainMatches('fakeexample.com', 'example.com')).toBe(false);
  });

  it('should be case-insensitive', () => {
    expect(domainMatches('EXAMPLE.COM', 'example.com')).toBe(true);
    expect(domainMatches('example.com', 'EXAMPLE.COM')).toBe(true);
    expect(domainMatches('Api.Example.COM', 'example.com')).toBe(true);
  });

  it('should match subdomain of parent domain', () => {
    expect(domainMatches('sub.example.com', 'sub.example.com')).toBe(true);
    expect(domainMatches('deep.sub.example.com', 'sub.example.com')).toBe(true);
    expect(domainMatches('other.example.com', 'sub.example.com')).toBe(false);
  });

  it('should handle edge cases', () => {
    expect(domainMatches('', '')).toBe(true);
    expect(domainMatches('a', 'a')).toBe(true);
    expect(domainMatches('.example.com', 'example.com')).toBe(true); // Leading dot = subdomain
  });
});
