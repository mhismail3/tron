import CryptoKit
import Foundation
import Security

enum GatewayLanPin {
    static func pin(forCertificateDER certificateDER: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let publicKey = SecCertificateCopyKey(certificate),
              let exported = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { return nil }
        return Data(SHA256.hash(data: exported)).base64EncodedString()
    }

    static func admitsServerTrust(_ trust: SecTrust, pin: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let served = GatewayLanPin.pin(forCertificateDER: SecCertificateCopyData(leaf) as Data) else { return false }
        return served == pin
    }

    static func answerServerTrustChallenge(
        _ challenge: URLAuthenticationChallenge,
        pin: String?,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let pin,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard admitsServerTrust(trust, pin: pin) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func admit(_ advertised: String) -> String? {
        guard let decoded = Data(base64Encoded: advertised), decoded.count == 32 else { return nil }
        return advertised
    }
}
