import CryptoKit
import Foundation
import Security

/// The LAN endpoint's certificate pin (E-3b).
///
/// The Gateway advertises this value with the LAN endpoints a phone may race
/// (`lanEndpoints`/`lanPin` on the pairing response and every hello). The LAN
/// leg's TLS evaluation admits the served certificate only when its public key
/// hashes to the pinned value, so a substituted certificate or a redirect never
/// reaches a credential, and the phone keeps its pinned value across the
/// Gateway's own address changes.
///
/// The pinned bytes are the public key as the platform exports it — for the
/// P-256 key the LAN endpoint always generates, the raw uncompressed X9.63
/// point (`0x04 || X || Y`) from `SecKeyCopyExternalRepresentation` — hashed
/// with SHA-256 and standard-base64 encoded. The Gateway derives the same bytes
/// from the same key, and
/// `packages/protocol-fixtures/lan-endpoint-pin.json` freezes the value for one
/// certificate so both sides catch a change of encoding instead of silently
/// failing every LAN handshake.
enum GatewayLanPin {
    /// The pin for a certificate the LAN leg served, or nil when the platform
    /// cannot export that certificate's public key. No pin means no trusted LAN
    /// leg: the caller fails the leg closed rather than admitting it.
    static func pin(forCertificateDER certificateDER: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let publicKey = SecCertificateCopyKey(certificate),
              let exported = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { return nil }
        return Data(SHA256.hash(data: exported)).base64EncodedString()
    }

    /// An advertised pin in the only shape this phone compares: standard base64
    /// of a 32-byte digest. Anything else is dropped, so a malformed
    /// advertisement leaves the profile without a pin instead of one no
    /// certificate can match.
    static func admit(_ advertised: String) -> String? {
        guard let decoded = Data(base64Encoded: advertised), decoded.count == 32 else { return nil }
        return advertised
    }
}
