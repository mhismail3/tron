import Testing
import Foundation

extension SourceGuardTests {

    @Test("Prompt transport has one attachment plane")
    func testPromptTransportHasOneAttachmentPlane() throws {
        let iosRoot = iosAppRoot()
        let checkedFiles = [
            "Sources/Engine/Protocol/Agent/EngineProtocolTypes+Agent.swift",
            "Sources/Engine/Transport/Clients/AgentClient.swift",
            "Sources/Engine/Transport/Clients/AgentClientProtocol.swift",
            "Sources/Engine/Transport/Clients/Repositories/Defaults/Protocols/AgentRepository.swift",
            "Sources/Engine/Transport/Clients/Repositories/Defaults/DefaultAgentRepository.swift",
            "Sources/Session/Chat/ViewModel/ChatViewModel+Messaging.swift",
            "Tests/Engine/Transport/Clients/AgentClientTests.swift",
            "Tests/Engine/Transport/Clients/Repositories/DefaultAgentRepositoryTests.swift",
            "Tests/Engine/Protocol/EngineProtocolTypesTests.swift",
        ]
        let forbiddenNeedles: [(String, String)] = [
            ("Image" + "Attachment", "legacy image-only prompt DTO"),
            ("last" + "Images", "legacy image-only mock state"),
            ("last" + "Send" + "Prompt" + "Images", "legacy image-only repository mock state"),
            ("images:", "legacy image-only prompt argument"),
            (#""images""#, "legacy image-only encoded prompt field"),
        ]

        for relativePath in checkedFiles {
            let url = iosRoot.appendingPathComponent(relativePath)
            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(
                content.contains("attachments") || content.contains("FileAttachment"),
                "\(relativePath) should route prompt media through unified attachments"
            )
            for (needle, reason) in forbiddenNeedles {
                #expect(
                    !content.contains(needle),
                    "\(relativePath) contains \(reason): `\(needle)`"
                )
            }
        }
    }


    @Test("Primitive shell has no fixed tree projection")
    func testPrimitiveShellHasNoFixedTreeProjection() throws {
        let iosRoot = iosAppRoot()
        let deletedPaths = [
            "Sources/UI/" + "Session" + "Tree",
            "Sources/Engine/Database/Repositories/TreeRepository.swift",
            "Sources/Engine/EventStore/EventTreeBuilder.swift",
            "Tests/Infrastructure/TreeRepositoryTests.swift",
            "Tests/Views/ForkButtonTests.swift",
            "Tests/Views/EventIconProviderTests.swift",
        ]
        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]
        let forbiddenNeedles: [(String, String)] = [
            ("Event" + "Tree" + "Node", "fixed event-tree projection DTO"),
            ("Event" + "Tree" + "Builder", "fixed event-tree projection builder"),
            ("Tree" + "Repository", "fixed event-tree repository"),
            ("Fork" + "Point" + "Indicator", "fixed fork visualization"),
            ("Fork" + "Button" + "State", "fixed fork-row state"),
            ("Event" + "Icon" + "Provider", "fixed session-tree icon catalog"),
            ("get" + "Tree" + "Visualization", "fixed tree query entry point"),
            ("database" + "." + "tree", "fixed tree repository access"),
            ("eventDB" + "." + "tree", "fixed tree repository access"),
            ("is" + "Branch" + "Point", "fixed branch projection field"),
        ]

        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) is a deleted fixed session-tree projection"
            )
        }

        for root in sourceRoots {
            for url in try swiftFiles(in: root) {
                if isSourceGuardFile(url) { continue }
                let content = try String(contentsOf: url, encoding: .utf8)
                for (needle, reason) in forbiddenNeedles {
                    #expect(
                        !content.contains(needle),
                        "\(url.path) contains \(reason): `\(needle)`"
                    )
                }
            }
        }
    }


    @Test("Primitive shell has no fixed product update surface")
    func testPrimitiveShellHasNoFixedProductUpdateSurface() throws {
        let iosRoot = iosAppRoot()
        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]
        let forbiddenNeedles: [(String, String)] = [
            ("System" + "Check" + "For" + "Updates" + "Result", "fixed update-check response DTO"),
            ("System" + "Update" + "Status" + "Result", "fixed update-status response DTO"),
            ("check" + "For" + "Updates", "fixed update-check client call"),
            ("get" + "Update" + "Status", "fixed update-status client call"),
            ("Update" + "Channel", "fixed update channel setting enum"),
            ("Update" + "Frequency", "fixed update frequency setting enum"),
            ("Update" + "Action", "fixed update action setting enum"),
            ("Server" + "Update" + "Settings" + "Item", "fixed update settings UI section"),
            ("updates" + "Section", "fixed update settings section"),
            ("Check" + " for " + "updates", "fixed user-facing update command"),
        ]

        for root in sourceRoots {
            for url in try swiftFiles(in: root) {
                if isSourceGuardFile(url) { continue }
                let content = try String(contentsOf: url, encoding: .utf8)
                for (needle, reason) in forbiddenNeedles {
                    #expect(
                        !content.contains(needle),
                        "\(url.path) contains \(reason): `\(needle)`"
                    )
                }
            }
        }
    }

    @Test("Runtime cockpit has no fixed legacy product panels")
    func testRuntimeCockpitHasNoFixedLegacyProductPanels() throws {
        let iosRoot = iosAppRoot()
        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]
        let forbiddenNeedles: [(String, String)] = [
            ("Source" + "Control" + "Panel", "fixed old source-control panel"),
            ("Memory" + "Panel", "fixed old memory panel"),
            ("Process" + "Panel", "fixed old process panel"),
            ("Approval" + "Panel", "fixed old approval panel"),
            ("Work" + "Panel", "fixed old work panel"),
            ("Work" + "Dash" + "board", "fixed old work status board"),
            ("Subagent" + "Panel", "fixed old subagent panel"),
            ("Notification" + "Panel", "fixed old notification panel"),
            ("Skill" + "Panel", "fixed old skill panel"),
            ("Catalog and lifecycle changes will appear here", "client-fabricated activity empty state"),
            ("worker package proposal", "client-fabricated package activity label"),
        ]

        for root in sourceRoots {
            for url in try swiftFiles(in: root) {
                if isSourceGuardFile(url) { continue }
                let content = try String(contentsOf: url, encoding: .utf8)
                for (needle, reason) in forbiddenNeedles {
                    #expect(
                        !content.contains(needle),
                        "\(url.path) contains \(reason): `\(needle)`"
                    )
                }
            }
        }
    }

    @Test("Protocol surfaces have no broad product DTO resurrection")
    func testProtocolSurfacesHaveNoBroadProductDTOResurrection() throws {
        let iosRoot = iosAppRoot()
        let deletedProtocolPaths = [
            "Sources/Engine/Protocol/Product",
            "Sources/Engine/Protocol/ProductSurfaces",
            "Sources/Engine/Protocol/ProductDTOs.swift",
            "Sources/Engine/Protocol/ProductTables.swift",
            "Sources/Engine/Protocol/RuntimeProductDTOs.swift",
            "Sources/Engine/Protocol/LegacyProductDTOs.swift",
            "Sources/Engine/Protocol/BroadProductDTOs.swift",
            "Sources/Engine/Protocol/DTOs.swift",
            "Sources/Engine/Events/Payloads/ProductEvents.swift",
            "Sources/Engine/Persistence/Models/ProductTables.swift",
        ]
        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]
        let forbiddenNeedles: [(String, String)] = [
            ("Product" + "DTO", "broad product DTO namespace"),
            ("Product" + "Surface" + "DTO", "broad product surface DTO"),
            ("Product" + "Table", "product-owned table model"),
            ("Product" + "Event", "product event catalog expansion"),
            ("Legacy" + "Product", "legacy product compatibility shim"),
            ("Runtime" + "Product", "runtime product DTO bucket"),
            ("Broad" + "Product", "broad product DTO bucket"),
            ("product" + "_dto", "product DTO table or payload name"),
            ("product" + "_surface", "product surface table or payload name"),
            ("product" + "_event", "product event table or payload name"),
            ("product" + "_table", "product table name"),
            ("product" + "_tables", "product tables name"),
            ("product" + "." + "tables", "product table namespace"),
            ("engine" + "." + "product", "public protocol product namespace"),
            ("Engine" + "Product" + "Client", "public protocol product client"),
        ]

        for relativePath in deletedProtocolPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) would resurrect a broad product DTO/protocol surface"
            )
        }

        for root in sourceRoots {
            for url in try swiftFiles(in: root) {
                if isSourceGuardFile(url) { continue }
                let content = try String(contentsOf: url, encoding: .utf8)
                for (needle, reason) in forbiddenNeedles {
                    #expect(
                        !content.contains(needle),
                        "\(url.path) contains \(reason): `\(needle)`"
                    )
                }
            }
        }
    }
}
