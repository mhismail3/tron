// app-attest must load first: it installs the Reflect polyfill that @peculiar/x509 needs.
import { AttestationRejected, verifyAttestation, verifyAttestationAgainstTrustedRoot, type AttestationVerificationInput } from "../src/app-attest";
import * as x509 from "@peculiar/x509";
import { encode } from "cbor-x";
import { describe, expect, test } from "vitest";
import { base64Url, concatBytes, ownedBuffer, sha256, utf8 } from "../src/crypto";

const algorithm = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as const;
const notBefore = new Date("2026-01-01T00:00:00Z");
const notAfter = new Date("2027-01-01T00:00:00Z");
const now = new Date("2026-06-01T00:00:00Z");
const APP_ID = "TEAM123456.com.example.app";

interface Authority { certificate: x509.X509Certificate; keys: CryptoKeyPair }

async function keyPair(): Promise<CryptoKeyPair> {
  return await crypto.subtle.generateKey(algorithm, true, ["sign", "verify"]) as CryptoKeyPair;
}

async function authority(name: string, issuer?: Authority): Promise<Authority> {
  x509.cryptoProvider.set(crypto);
  const keys = await keyPair();
  const extensions = [
    new x509.BasicConstraintsExtension(true, issuer ? 0 : undefined, true),
    new x509.KeyUsagesExtension(x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign, true),
  ];
  const certificate = issuer
    ? await x509.X509CertificateGenerator.create({
      serialNumber: "02", subject: `CN=${name}`, issuer: issuer.certificate.subject, notBefore, notAfter,
      signingAlgorithm: algorithm, publicKey: keys.publicKey, signingKey: issuer.keys.privateKey, extensions,
    })
    : await x509.X509CertificateGenerator.createSelfSigned({
      serialNumber: "01", name: `CN=${name}`, notBefore, notAfter, signingAlgorithm: algorithm, keys, extensions,
    });
  return { certificate, keys };
}

/** A development App Attest attestation whose chain ends at a generated root. */
async function attestation() {
  const root = await authority("Test App Attest Root");
  const intermediate = await authority("Test App Attest Intermediate", root);
  const leafKeys = await keyPair();
  const rawPublicKey = new Uint8Array(await crypto.subtle.exportKey("raw", leafKeys.publicKey));
  const keyId = await sha256(rawPublicKey);
  const credentialPublicKey = new Uint8Array(encode(new Map<number, unknown>([
    [1, 2], [3, -7], [-1, 1], [-2, rawPublicKey.slice(1, 33)], [-3, rawPublicKey.slice(33, 65)],
  ])));
  const authData = concatBytes(
    await sha256(utf8(APP_ID)), new Uint8Array([0x40]), new Uint8Array(4), utf8("appattestdevelop"),
    new Uint8Array([0, keyId.byteLength]), keyId, credentialPublicKey,
  );
  const clientDataHash = await sha256(utf8("client data"));
  const nonce = await sha256(concatBytes(authData, clientDataHash));
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "03", subject: "CN=Test App Attest Leaf", issuer: intermediate.certificate.subject, notBefore, notAfter,
    signingAlgorithm: algorithm, publicKey: leafKeys.publicKey, signingKey: intermediate.keys.privateKey,
    extensions: [
      new x509.BasicConstraintsExtension(false, undefined, true),
      new x509.KeyUsagesExtension(x509.KeyUsageFlags.digitalSignature, true),
      new x509.Extension("1.2.840.113635.100.8.2", false, ownedBuffer(concatBytes(new Uint8Array([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]), nonce))),
    ],
  });
  const chain = [new Uint8Array(leaf.rawData), new Uint8Array(intermediate.certificate.rawData)];
  const input = (x5c: Uint8Array[] = chain): AttestationVerificationInput => ({
    attestationObject: base64Url(new Uint8Array(encode({ fmt: "apple-appattest", attStmt: { x5c, receipt: new Uint8Array(16) }, authData }))),
    keyId: base64Url(keyId),
    clientDataHash,
    appId: APP_ID,
    environment: "development",
    now,
  });
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", leafKeys.publicKey));
  return { rootPem: root.certificate.toString("pem"), chain, input, spki };
}

describe("App Attest certificate chain", () => {
  test("accepts a chain to the trusted root and returns the leaf key", async () => {
    const { rootPem, input, spki } = await attestation();
    await expect(verifyAttestationAgainstTrustedRoot(input(), rootPem)).resolves.toEqual({ publicKeySpki: base64Url(spki), counter: 0 });
  });

  test("rejects a chain to another root, including the pinned Apple root", async () => {
    const { input } = await attestation();
    const other = await authority("Other Root");
    await expect(verifyAttestationAgainstTrustedRoot(input(), other.certificate.toString("pem")))
      .rejects.toEqual(new AttestationRejected("untrusted_attestation_root"));
    await expect(verifyAttestation(input())).rejects.toEqual(new AttestationRejected("untrusted_attestation_root"));
  });

  test("rejects a leaf certificate with bytes after its DER encoding", async () => {
    const { rootPem, chain, input } = await attestation();
    const rejection = verifyAttestationAgainstTrustedRoot(input([concatBytes(chain[0], new Uint8Array([0, 0])), chain[1]]), rootPem);
    await expect(rejection).rejects.toBeInstanceOf(AttestationRejected);
  });
});
