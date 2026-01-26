/**
 * @fileoverview APNS Service
 *
 * Apple Push Notification Service client using HTTP/2 and JWT authentication.
 * Handles token generation, caching, and notification delivery.
 */

import { createLogger, categorizeError } from '../../logging/index.js';
import * as http2 from 'http2';
import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';
import type {
  APNSConfig,
  APNSNotification,
  APNSSendResult,
  APNSPayload,
} from './types.js';

const logger = createLogger('apns-service');

// APNS endpoints
const APNS_HOST_PRODUCTION = 'api.push.apple.com';
const APNS_HOST_SANDBOX = 'api.sandbox.push.apple.com';
const APNS_PORT = 443;

// JWT token validity (Apple allows 1 hour, we refresh at 55 mins)
const TOKEN_EXPIRY_MS = 55 * 60 * 1000;

/**
 * APNS Service for sending push notifications to iOS devices.
 *
 * Features:
 * - HTTP/2 persistent connection to Apple's servers
 * - JWT-based authentication with ES256 signing
 * - Automatic token refresh before expiry
 * - Concurrent notification sending
 */
export class APNSService {
  private config: APNSConfig;
  private privateKey: string;
  private jwtToken: string | null = null;
  private tokenExpiresAt: number = 0;
  private client: http2.ClientHttp2Session | null = null;
  private connecting: boolean = false;

  constructor(config: APNSConfig) {
    this.config = config;

    // Load private key
    const keyPath = config.keyPath.startsWith('~')
      ? path.join(process.env.HOME || '', config.keyPath.slice(1))
      : config.keyPath;

    try {
      this.privateKey = fs.readFileSync(keyPath, 'utf8');
      logger.info('APNS private key loaded', { keyPath });
    } catch (error) {
      const structuredError = categorizeError(error, { operation: 'loadPrivateKey', keyPath });
      logger.error('Failed to load APNS private key', {
        keyPath,
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
      throw new Error(`Failed to load APNS private key from ${keyPath}`);
    }
  }

  /**
   * Get the APNS host based on environment
   */
  private get host(): string {
    return this.config.environment === 'production'
      ? APNS_HOST_PRODUCTION
      : APNS_HOST_SANDBOX;
  }

  /**
   * Generate a JWT token for APNS authentication.
   * Uses ES256 (ECDSA with P-256 curve and SHA-256).
   */
  private generateToken(): string {
    const now = Math.floor(Date.now() / 1000);

    // JWT Header
    const header = {
      alg: 'ES256',
      kid: this.config.keyId,
    };

    // JWT Claims
    const claims = {
      iss: this.config.teamId,
      iat: now,
    };

    // Base64URL encode
    const base64url = (data: object): string => {
      return Buffer.from(JSON.stringify(data))
        .toString('base64')
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '');
    };

    const headerEncoded = base64url(header);
    const claimsEncoded = base64url(claims);
    const signatureInput = `${headerEncoded}.${claimsEncoded}`;

    // Sign with ES256
    const sign = crypto.createSign('SHA256');
    sign.update(signatureInput);
    const signature = sign.sign(this.privateKey);

    // Convert DER signature to raw R||S format for JWT
    const rawSignature = this.derToRaw(signature);
    const signatureEncoded = rawSignature
      .toString('base64')
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');

    return `${signatureInput}.${signatureEncoded}`;
  }

  /**
   * Convert DER-encoded ECDSA signature to raw R||S format.
   * Node.js crypto returns DER format, but JWT expects raw format.
   */
  private derToRaw(der: Buffer): Buffer {
    // DER structure: 0x30 [length] 0x02 [r-length] [r] 0x02 [s-length] [s]
    let offset = 2; // Skip 0x30 and length byte

    // Extract R
    if (der[offset] !== 0x02) throw new Error('Invalid DER signature');
    offset++;
    const rLength = der[offset]!;
    offset++;
    let r = der.subarray(offset, offset + rLength);
    offset += rLength;

    // Extract S
    if (der[offset] !== 0x02) throw new Error('Invalid DER signature');
    offset++;
    const sLength = der[offset]!;
    offset++;
    let s = der.subarray(offset, offset + sLength);

    // Remove leading zeros if present (DER uses signed integers)
    if (r.length === 33 && r[0] === 0) r = r.subarray(1);
    if (s.length === 33 && s[0] === 0) s = s.subarray(1);

    // Pad to 32 bytes if needed
    const rPadded = Buffer.alloc(32);
    const sPadded = Buffer.alloc(32);
    r.copy(rPadded, 32 - r.length);
    s.copy(sPadded, 32 - s.length);

    return Buffer.concat([rPadded, sPadded]);
  }

  /**
   * Get a valid JWT token, refreshing if needed
   */
  private getToken(): string {
    const now = Date.now();

    if (!this.jwtToken || now >= this.tokenExpiresAt) {
      this.jwtToken = this.generateToken();
      this.tokenExpiresAt = now + TOKEN_EXPIRY_MS;
      logger.debug('Generated new APNS JWT token');
    }

    return this.jwtToken;
  }

  /**
   * Ensure HTTP/2 connection to APNS is established
   */
  private async ensureConnection(): Promise<http2.ClientHttp2Session> {
    if (this.client && !this.client.destroyed) {
      return this.client;
    }

    if (this.connecting) {
      // Wait for existing connection attempt
      await new Promise<void>((resolve) => {
        const check = () => {
          if (!this.connecting) {
            resolve();
          } else {
            setTimeout(check, 50);
          }
        };
        check();
      });
      if (this.client && !this.client.destroyed) {
        return this.client;
      }
    }

    this.connecting = true;

    return new Promise((resolve, reject) => {
      const client = http2.connect(`https://${this.host}:${APNS_PORT}`, {
        // Ping interval to keep connection alive
        peerMaxConcurrentStreams: 500,
      });

      client.on('connect', () => {
        logger.info('Connected to APNS', { host: this.host });
        this.client = client;
        this.connecting = false;
        resolve(client);
      });

      client.on('error', (err) => {
        const structuredError = categorizeError(err, { operation: 'ensureConnection', host: this.host });
        logger.error('APNS connection error', {
          host: this.host,
          code: structuredError.code,
          category: structuredError.category,
          error: structuredError.message,
          retryable: structuredError.retryable,
        });
        this.connecting = false;
        reject(err);
      });

      client.on('close', () => {
        logger.info('APNS connection closed');
        if (this.client === client) {
          this.client = null;
        }
      });

      client.on('goaway', () => {
        logger.info('APNS sent GOAWAY, reconnecting on next request');
        if (this.client === client) {
          this.client = null;
        }
      });
    });
  }

  /**
   * Send a notification to a single device
   */
  async send(
    deviceToken: string,
    notification: APNSNotification
  ): Promise<APNSSendResult> {
    try {
      const client = await this.ensureConnection();
      const token = this.getToken();

      // Build APNS payload
      const payload: APNSPayload = {
        aps: {
          alert: {
            title: notification.title,
            body: notification.body,
          },
          sound: notification.sound || 'default',
        },
      };

      if (notification.badge !== undefined) {
        payload.aps.badge = notification.badge;
      }

      if (notification.threadId) {
        payload.aps['thread-id'] = notification.threadId;
      }

      // Add custom data
      if (notification.data) {
        for (const [key, value] of Object.entries(notification.data)) {
          payload[key] = value;
        }
      }

      const payloadJson = JSON.stringify(payload);

      // Send HTTP/2 request
      const result = await new Promise<APNSSendResult>((resolve) => {
        const req = client.request({
          ':method': 'POST',
          ':path': `/3/device/${deviceToken}`,
          ':scheme': 'https',
          authorization: `bearer ${token}`,
          'apns-topic': this.config.bundleId,
          'apns-push-type': 'alert',
          'apns-priority': notification.priority === 'high' ? '10' : '5',
          'apns-expiration': '0', // Send immediately or discard
        });

        let responseData = '';
        let statusCode: number | undefined;
        let apnsId: string | undefined;

        req.on('response', (headers) => {
          statusCode = headers[':status'] as number;
          apnsId = headers['apns-id'] as string;
        });

        req.on('data', (chunk) => {
          responseData += chunk;
        });

        req.on('end', () => {
          if (statusCode === 200) {
            resolve({
              success: true,
              deviceToken,
              apnsId,
              statusCode,
            });
          } else {
            let reason: string | undefined;
            try {
              const errorBody = JSON.parse(responseData);
              reason = errorBody.reason;
            } catch {
              reason = responseData || undefined;
            }

            logger.warn('APNS send failed', {
              deviceToken: deviceToken.substring(0, 8) + '...',
              statusCode,
              reason,
            });

            resolve({
              success: false,
              deviceToken,
              statusCode,
              reason,
              error: `APNS error: ${reason || statusCode}`,
            });
          }
        });

        req.on('error', (err) => {
          const structuredError = categorizeError(err, { operation: 'sendRequest', deviceToken: deviceToken.substring(0, 8) + '...' });
          logger.error('APNS request error', {
            deviceToken: deviceToken.substring(0, 8) + '...',
            code: structuredError.code,
            category: structuredError.category,
            error: structuredError.message,
            retryable: structuredError.retryable,
          });
          resolve({
            success: false,
            deviceToken,
            error: err.message,
          });
        });

        req.end(payloadJson);
      });

      return result;
    } catch (error) {
      const structuredError = categorizeError(error, { operation: 'send', deviceToken: deviceToken.substring(0, 8) + '...' });
      logger.error('APNS send error', {
        deviceToken: deviceToken.substring(0, 8) + '...',
        code: structuredError.code,
        category: structuredError.category,
        error: structuredError.message,
        retryable: structuredError.retryable,
      });
      return {
        success: false,
        deviceToken,
        error: structuredError.message,
      };
    }
  }

  /**
   * Send notifications to multiple devices in parallel
   */
  async sendToMany(
    deviceTokens: string[],
    notification: APNSNotification
  ): Promise<APNSSendResult[]> {
    if (deviceTokens.length === 0) {
      return [];
    }

    logger.info('Sending APNS notification to multiple devices', {
      count: deviceTokens.length,
      title: notification.title,
    });

    // Send in parallel (APNS supports high concurrency)
    const results = await Promise.all(
      deviceTokens.map((token) => this.send(token, notification))
    );

    const successful = results.filter((r) => r.success).length;
    const failed = results.filter((r) => !r.success).length;

    logger.info('APNS batch send complete', { successful, failed });

    return results;
  }

  /**
   * Close the APNS connection
   */
  close(): void {
    if (this.client) {
      this.client.close();
      this.client = null;
    }
  }
}

/**
 * Load APNS configuration from ~/.tron/mods/apns/config.json
 */
export function loadAPNSConfig(): APNSConfig | null {
  const configPath = path.join(
    process.env.HOME || '',
    '.tron',
    'mods',
    'apns',
    'config.json'
  );

  try {
    if (!fs.existsSync(configPath)) {
      logger.debug('APNS config not found, push notifications disabled', { configPath });
      return null;
    }

    const configData = fs.readFileSync(configPath, 'utf8');
    const config = JSON.parse(configData) as Partial<APNSConfig>;

    // Validate required fields
    if (!config.keyId || !config.teamId || !config.bundleId) {
      logger.warn('APNS config missing required fields', {
        hasKeyId: !!config.keyId,
        hasTeamId: !!config.teamId,
        hasBundleId: !!config.bundleId,
      });
      return null;
    }

    // Default key path if not specified
    const keyPath = config.keyPath || path.join(
      process.env.HOME || '',
      '.tron',
      'mods',
      'apns',
      `AuthKey_${config.keyId}.p8`
    );

    // Expand ~ in key path
    const expandedKeyPath = keyPath.startsWith('~')
      ? path.join(process.env.HOME || '', keyPath.slice(1))
      : keyPath;

    if (!fs.existsSync(expandedKeyPath)) {
      logger.warn('APNS key file not found', { keyPath: expandedKeyPath });
      return null;
    }

    return {
      keyPath: expandedKeyPath,
      keyId: config.keyId,
      teamId: config.teamId,
      bundleId: config.bundleId,
      environment: config.environment || 'sandbox',
    };
  } catch (error) {
    const structuredError = categorizeError(error, { operation: 'loadAPNSConfig', configPath });
    logger.error('Failed to load APNS config', {
      configPath,
      code: structuredError.code,
      category: structuredError.category,
      error: structuredError.message,
      retryable: structuredError.retryable,
    });
    return null;
  }
}

/**
 * Create an APNS service instance, or null if not configured
 */
export function createAPNSService(): APNSService | null {
  const config = loadAPNSConfig();
  if (!config) {
    return null;
  }

  try {
    return new APNSService(config);
  } catch (error) {
    const structuredError = categorizeError(error, { operation: 'createAPNSService' });
    logger.error('Failed to create APNS service', {
      code: structuredError.code,
      category: structuredError.category,
      error: structuredError.message,
      retryable: structuredError.retryable,
    });
    return null;
  }
}
