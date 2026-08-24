import { decode } from "cbor-x";
import { BasicConstraintsExtension, X509Certificate, cryptoProvider } from "@peculiar/x509";
import { APPLE_APP_ATTESTATION_ROOT_PEM } from "./apple-app-attestation-root";
import type { AttestationEnvironment } from "./contracts";
import {
  concatBytes,
  constantTimeEqual,
  decodeBase64Url,
  ownedBuffer,
  sha256,
  utf8,
} from "./crypto";

const APP_ATTEST_NONCE_OID = "1.2.840.113635.100.8.2";
const DEVELOPMENT_AAGUID = utf8("appattestdevelop");
const PRODUCTION_AAGUID = concatBytes(utf8("appattest"), new Uint8Array(7));

export interface VerifiedAttestation {
  publicKeySpki: string;
  counter: number;
}

interface DecodedAuthenticatorData {
  rpIdHash: Uint8Array;
  counter: number;
  aaguid?: Uint8Array;
  credentialId?: Uint8Array;
  credentialPublicKey?: Uint8Array;
}

export async function verifyAttestation(input: {
  attestationObject: string;
  keyId: string;
  clientDataHash: Uint8Array;
  appId: string;
  environment: AttestationEnvironment;
  now?: Date;
}): Promise<VerifiedAttestation> {
  cryptoProvider.set(crypto);
  const object = cborObject(decode(decodeBase64Url(input.attestationObject)));
  if (object.fmt !== "apple-appattest") throw new Error("invalid_attestation_format");
  const authData = bytes(object.authData);
  const statement = cborObject(object.attStmt);
  const chainValues = Array.isArray(statement.x5c) ? statement.x5c.map(bytes) : [];
  if (chainValues.length < 2 || chainValues.length > 3) throw new Error("invalid_attestation_chain");

  const certificates = chainValues.map((value) => new X509Certificate(ownedBuffer(value)));
  const root = new X509Certificate(APPLE_APP_ATTESTATION_ROOT_PEM);
  const now = input.now ?? new Date();
  for (const certificate of [...certificates, root]) {
    if (now < certificate.notBefore || now > certificate.notAfter) throw new Error("expired_attestation_certificate");
  }
  const leafConstraints = certificates[0].getExtension(BasicConstraintsExtension);
  if (leafConstraints?.ca === true) throw new Error("invalid_attestation_leaf");
  for (let index = 0; index < certificates.length - 1; index += 1) {
    const issuerConstraints = certificates[index + 1].getExtension(BasicConstraintsExtension);
    if (!issuerConstraints?.ca) throw new Error("invalid_attestation_issuer");
    if (!(await certificates[index].verify({ publicKey: certificates[index + 1].publicKey }, crypto))) {
      throw new Error("invalid_attestation_chain");
    }
  }
  const last = certificates.at(-1)!;
  const lastIsRoot = constantTimeEqual(new Uint8Array(last.rawData), new Uint8Array(root.rawData));
  if (!lastIsRoot && !(await last.verify({ publicKey: root.publicKey }, crypto))) {
    throw new Error("untrusted_attestation_root");
  }

  const leaf = certificates[0];
  const extension = leaf.extensions.find((candidate) => candidate.type === APP_ATTEST_NONCE_OID);
  if (!extension) throw new Error("missing_attestation_nonce");
  const expectedNonce = await sha256(concatBytes(authData, input.clientDataHash));
  const certificateNonce = findNonce(new Uint8Array(extension.value));
  if (!certificateNonce || !constantTimeEqual(certificateNonce, expectedNonce)) {
    throw new Error("invalid_attestation_nonce");
  }

  const parsed = decodeAuthenticatorData(authData, true);
  const expectedRpId = await sha256(utf8(input.appId));
  if (!constantTimeEqual(parsed.rpIdHash, expectedRpId)) throw new Error("invalid_relying_party");
  if (parsed.counter !== 0) throw new Error("invalid_attestation_counter");
  const expectedAaguid = input.environment === "development" ? DEVELOPMENT_AAGUID : PRODUCTION_AAGUID;
  if (!parsed.aaguid || !constantTimeEqual(parsed.aaguid, expectedAaguid)) throw new Error("invalid_attestation_environment");

  const keyId = decodeBase64Url(input.keyId);
  if (!parsed.credentialId || !constantTimeEqual(parsed.credentialId, keyId)) throw new Error("credential_id_mismatch");
  const cryptoKey = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"], crypto);
  const rawPublicKey = new Uint8Array(await crypto.subtle.exportKey("raw", cryptoKey));
  if (!constantTimeEqual(await sha256(rawPublicKey), keyId)) throw new Error("public_key_mismatch");
  if (!parsed.credentialPublicKey || !constantTimeEqual(parsed.credentialPublicKey, rawPublicKey)) {
    throw new Error("credential_public_key_mismatch");
  }

  return {
    publicKeySpki: toBase64Url(new Uint8Array(leaf.publicKey.rawData)),
    counter: 0,
  };
}

export async function verifyAssertion(input: {
  assertionObject: string;
  publicKeySpki: string;
  clientDataHash: Uint8Array;
  appId: string;
  previousCounter: number;
}): Promise<number> {
  const object = cborObject(decode(decodeBase64Url(input.assertionObject)));
  const authenticatorData = bytes(object.authenticatorData);
  const signature = bytes(object.signature);
  const parsed = decodeAuthenticatorData(authenticatorData, false);
  const expectedRpId = await sha256(utf8(input.appId));
  if (!constantTimeEqual(parsed.rpIdHash, expectedRpId)) throw new Error("invalid_relying_party");
  if (parsed.counter <= input.previousCounter) throw new Error("assertion_replay");

  const publicKey = await crypto.subtle.importKey(
    "spki",
    decodeBase64Url(input.publicKeySpki).buffer as ArrayBuffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    ownedBuffer(derEcdsaToRaw(signature)),
    ownedBuffer(concatBytes(authenticatorData, input.clientDataHash)),
  );
  if (!valid) throw new Error("invalid_assertion_signature");
  return parsed.counter;
}

function decodeAuthenticatorData(value: Uint8Array, requireAttestation: boolean): DecodedAuthenticatorData {
  if (value.byteLength < 37) throw new Error("invalid_authenticator_data");
  const flags = value[32];
  const counter = new DataView(value.buffer, value.byteOffset + 33, 4).getUint32(0, false);
  const result: DecodedAuthenticatorData = { rpIdHash: value.slice(0, 32), counter };
  if (!requireAttestation) {
    if (value.byteLength !== 37 || (flags & 0x40) !== 0) throw new Error("invalid_assertion_authenticator_data");
    return result;
  }
  if ((flags & 0x40) === 0 || (flags & 0x80) !== 0 || value.byteLength < 55) throw new Error("missing_attested_credential_data");
  const credentialLength = new DataView(value.buffer, value.byteOffset + 53, 2).getUint16(0, false);
  const coseOffset = 55 + credentialLength;
  if (credentialLength < 1 || coseOffset >= value.byteLength) throw new Error("invalid_credential_id");
  result.aaguid = value.slice(37, 53);
  result.credentialId = value.slice(55, coseOffset);
  const coseValue = decode(value.slice(coseOffset));
  const cose = coseValue instanceof Map ? coseValue : undefined;
  const x = cose ? bytes(cose.get(-2)) : undefined;
  const y = cose ? bytes(cose.get(-3)) : undefined;
  if (!x || !y || x.byteLength !== 32 || y.byteLength !== 32) throw new Error("invalid_credential_public_key");
  result.credentialPublicKey = concatBytes(new Uint8Array([4]), x, y);
  return result;
}

function findNonce(der: Uint8Array): Uint8Array | undefined {
  function visit(start: number, end: number): Uint8Array | undefined {
    let offset = start;
    while (offset < end) {
      const tag = der[offset++];
      if (offset >= end) return undefined;
      const firstLength = der[offset++];
      let length = firstLength;
      if ((firstLength & 0x80) !== 0) {
        const count = firstLength & 0x7f;
        if (count < 1 || count > 3 || offset + count > end) return undefined;
        length = 0;
        for (let index = 0; index < count; index += 1) length = (length << 8) | der[offset++];
      }
      const contentEnd = offset + length;
      if (contentEnd > end) return undefined;
      if (tag === 0x04 && length === 32) return der.slice(offset, contentEnd);
      if ((tag & 0x20) !== 0 || (tag & 0xc0) === 0x80) {
        const nested = visit(offset, contentEnd);
        if (nested) return nested;
      }
      offset = contentEnd;
    }
    return undefined;
  }
  return visit(0, der.byteLength);
}

function derEcdsaToRaw(der: Uint8Array): Uint8Array {
  if (der.byteLength === 64) return der;
  if (der[0] !== 0x30 || der.byteLength < 8) throw new Error("invalid_ecdsa_signature");
  let offset = 1;
  const sequence = readLength(der, offset); offset = sequence.offset;
  if (offset + sequence.length !== der.byteLength || der[offset++] !== 0x02) throw new Error("invalid_ecdsa_signature");
  const rLength = readLength(der, offset); offset = rLength.offset;
  const r = der.slice(offset, offset + rLength.length); offset += rLength.length;
  if (der[offset++] !== 0x02) throw new Error("invalid_ecdsa_signature");
  const sLength = readLength(der, offset); offset = sLength.offset;
  const s = der.slice(offset, offset + sLength.length); offset += sLength.length;
  if (offset !== der.byteLength) throw new Error("invalid_ecdsa_signature");
  return concatBytes(integerTo32(r), integerTo32(s));
}

function readLength(value: Uint8Array, offset: number): { length: number; offset: number } {
  const first = value[offset++];
  if (first === undefined) throw new Error("invalid_der_length");
  if ((first & 0x80) === 0) return { length: first, offset };
  const count = first & 0x7f;
  if (count < 1 || count > 2 || offset + count > value.byteLength) throw new Error("invalid_der_length");
  let length = 0;
  for (let index = 0; index < count; index += 1) length = (length << 8) | value[offset++];
  return { length, offset };
}

function integerTo32(value: Uint8Array): Uint8Array {
  let start = 0;
  while (start < value.byteLength - 1 && value[start] === 0) start += 1;
  const significant = value.slice(start);
  if (significant.byteLength > 32) throw new Error("invalid_ecdsa_integer");
  const result = new Uint8Array(32);
  result.set(significant, 32 - significant.byteLength);
  return result;
}

function cborObject(value: unknown): Record<string, unknown> {
  if (value instanceof Map) return Object.fromEntries(value) as Record<string, unknown>;
  if (typeof value === "object" && value !== null && !Array.isArray(value)) return value as Record<string, unknown>;
  throw new Error("invalid_cbor_object");
}

function bytes(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  throw new Error("invalid_cbor_bytes");
}

function toBase64Url(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
