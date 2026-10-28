#if HOSTED_TEST
import SwiftUI
import UIKit
import CryptoKit
import TronMobileCore

/// Socket-side data only. Production chat routing, review admission and the
/// receipt-backed install owner remain in the app under test. No disk install.
struct HostedInstallReviewGateway {
    private var installed: InstalledSwiftAppManifest?
    mutating func handle(_ method: String, params: [String: JSONValue], source: Data) -> JSONValue? {
        let reference = SwiftAppDisplayReference(sessionId: "readonly-session", artifactId: "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc40")
        let offer = SwiftAppInstallOffer(reference: reference, version: 1, id: String(repeating: "a", count: 64), appId: "builds", name: "Builds", icon: "shippingbox", sourceSha256: SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(), sourceBytes: source.count, feeds: ["ios-builds"])
        switch method {
        case "apps.review":
            return try! JSONValue.encode(SwiftAppInstallReview(offer: offer, installed: installed, reference: reference))
        case "apps.install":
            guard params["offerId"]?.stringValue == offer.id,
                  params["sessionId"]?.stringValue == reference.sessionId,
                  params["artifactId"]?.stringValue == reference.artifactId,
                  params["commandId"]?.stringValue != nil else { return nil }
            let app = InstalledSwiftAppManifest(version: 2, id: offer.appId, name: offer.name, icon: offer.icon, revision: 1, sourceSha256: offer.sourceSha256, sourceBytes: offer.sourceBytes, updatedAt: "2026-10-28T00:00:00Z", instanceId: "00000000-0000-4000-8000-000000000001", feeds: offer.feeds)
            installed = app
            return try! JSONValue.encode(SwiftAppInstallResult(app: app, created: true))
        case "apps.list": return try! JSONValue.encode(InstalledSwiftAppList(apps: installed.map { [$0] } ?? []))
        default: return nil
        }
    }
}

/// Records mounted document chrome, including a transient title that AX polling
/// after RPC completion would miss. Only active in this explicitly chosen fixture.
@MainActor enum HostedInstallReviewObservation {
    static var titles: [String] = []
    static func install() {
        HostedPresentationProbe.record = { event, title in
            guard event == "document-appear", titles.count < 100 else { return }
            titles.append(title)
        }
    }
}

struct HostedInstallReviewProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}
    final class Probe: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityIdentifier = "fixture.install-review-titles"
            accessibilityLabel = "Mounted sheet titles"
            HostedInstallReviewObservation.install()
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var accessibilityValue: String? {
            get { HostedInstallReviewObservation.titles.joined(separator: "|") }
            set {}
        }
    }
}
#endif
