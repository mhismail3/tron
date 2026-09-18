import SwiftUI
import XCTest
@testable import TronMobile

/// Native captures of the server info sheet and the maintenance action grid.
/// These are layout checks, not physical-device visual acceptance.
@MainActor
final class GatewayServerInfoLayoutTests: XCTestCase {
    func testServerInfoSheetPresentsBothTablesThroughTheSharedComponent() async throws {
        let info = Self.info
        let status = GatewayUpdateStatus(
            state: "ready", channel: "stable",
            currentIdentity: GatewayUpdateIdentity(
                version: "candidate", gatewayVersion: "1", sourceRevision: "fallback-revision",
                runtimeEpoch: "fallback-epoch", payloadFingerprint: "payload-identity"
            ),
            candidateIdentity: nil, candidateAvailable: false, error: nil, updatedAt: nil
        )
        let sheet = GatewayServerInfoSheet(
            metadata: GatewayConnectionDetailPresentation.metadata(info: info),
            identities: GatewayConnectionDetailPresentation.technicalDetails(info: info, updateStatus: status),
            loading: false
        )
        .background(Color.tronBackground)
        .tronPresentation()

        try await withHost(sheet, size: CGSize(width: 402, height: 620)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            // Both tables use TronTechnicalMetadataSection, whose rows read as
            // "label, value" and right-align the value in the code family.
            for expected in ["Machine, Mac", "Gateway, 1", "Agent runtime, 2", "Protocol, 5",
                             "Restart supervision, Managed LaunchAgent",
                             "Source revision, source-revision", "Runtime epoch, runtime-epoch",
                             "Payload identity, payload-identity"] {
                XCTAssertTrue(elements.contains { $0.label == expected }, "Missing metadata row: \(expected)")
            }
            XCTAssertTrue(elements.contains { $0.label == "Done" }, "The sheet keeps the standard Done control")
            Self.attach(host.view, named: "server-info-sheet", to: self)
        }
    }

    func testMaintenanceActionsGridPrecedesTheDestructiveAction() async throws {
        let sheet = GatewayMaintenanceActions(
            lifecycle: [
                GatewayMaintenanceAction(id: "update", title: "Rebuild from Source") {},
                GatewayMaintenanceAction(id: "rollback", title: "Roll Back") {},
                GatewayMaintenanceAction(id: "restart", title: "Restart") {},
                GatewayMaintenanceAction(id: "enabled", title: "Disable") {},
            ],
            destructive: GatewayMaintenanceAction(id: "forget", title: "Forget Server") {}
        )
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.tronBackground)
        .tronPresentation()

        try await withHost(sheet, size: CGSize(width: 402, height: 320)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            func action(_ label: String) throws -> CGRect {
                try XCTUnwrap(elements.first { $0.label == label && $0.traits.contains(.button) }).frame
            }
            let lifecycle = try ["Rebuild from Source", "Roll Back", "Restart", "Disable"].map(action)
            let forget = try action("Forget Server")
            XCTAssertEqual(lifecycle.count, 4, "Every lifecycle action keeps its own labelled target")

            // Two equal columns, two rows, one shared accent width.
            XCTAssertEqual(lifecycle[0].minX, lifecycle[2].minX, accuracy: 1)
            XCTAssertEqual(lifecycle[1].minX, lifecycle[3].minX, accuracy: 1)
            XCTAssertEqual(lifecycle[0].width, lifecycle[1].width, accuracy: 1)
            XCTAssertEqual(lifecycle[0].minY, lifecycle[1].minY, accuracy: 1)
            XCTAssertEqual(lifecycle[2].minY, lifecycle[3].minY, accuracy: 1)
            XCTAssertGreaterThan(lifecycle[2].minY, lifecycle[0].maxY, "The second row sits below the first")

            // The pairing action is full width and last.
            XCTAssertGreaterThan(forget.width, lifecycle[0].width * 1.5)
            XCTAssertGreaterThan(forget.minY, lifecycle[2].maxY)
            Self.attach(host.view, named: "gateway-maintenance-actions", to: self)
        }
    }

    private static let info = GatewayInfo(
        gatewayVersion: "1", piVersion: "2", protocolVersion: 5, minProtocolVersion: 5,
        machineId: "machine", machineName: "Mac", capabilities: ["gateway-update.v1", "restart-supervised.v1"],
        sourceRevision: "source-revision", runtimeEpoch: "runtime-epoch"
    )

    private struct Element {
        let label: String
        let traits: UIAccessibilityTraits
        let frame: CGRect
    }

    /// Walks the whole hosted tree: a scrollable sheet exposes its rows on
    /// nested containers, not only at the root.
    private static func accessibilityElements(in view: UIView) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        var collected: [Element] = []
        func walk(_ view: UIView) {
            for element in view.accessibilityElements ?? [] {
                guard let object = element as? NSObject else { continue }
                if seen.insert(ObjectIdentifier(object)).inserted {
                    collected.append(Element(label: object.accessibilityLabel ?? "", traits: object.accessibilityTraits,
                                             frame: object.accessibilityFrame))
                }
                if let nested = element as? UIAccessibilityElement, let container = nested.accessibilityContainer as? UIView {
                    walk(container)
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(view)
        return collected
    }

    private static func attach(_ view: UIView, named name: String, to testCase: XCTestCase) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    private func withHost<Content: View>(
        _ content: Content, size: CGSize,
        check: (UIHostingController<Content>) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Server info fixture appeared")
        let host = GatewayServerInfoHostingController(rootView: content)
        host.onAppear = { appeared.fulfill() }
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [appeared], timeout: 2)
        host.view.layoutIfNeeded()
        try await check(host)
    }
}

@MainActor
private final class GatewayServerInfoHostingController<Content: View>: UIHostingController<Content> {
    var onAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }
}
