import Testing
@testable import TronMobile

@Suite("Package catalog admission")
struct PackageCatalogPolicyTests {
    private var emptyResources: JSONValue {
        .object([
            "extensions": .array([]),
            "skills": .array([]),
            "prompts": .array([]),
            "themes": .array([]),
        ])
    }

    @Test("admits unique bounded inventory and updates")
    func admitsBoundedCatalogs() throws {
        let inventory = PackageInventory(
            packages: [PackageSummary(
                source: "package",
                scope: .user,
                filtered: false,
                installedPath: "/package"
            )],
            resources: emptyResources
        )
        #expect(try PackageCatalogPolicy.admit(inventory) == inventory)

        let additiveResources = JSONValue.object([
            "extensions": .array([]),
            "skills": .array([]),
            "prompts": .array([]),
            "themes": .array([]),
            "futureCategory": .array([.object(["path": .string("/future")])]),
        ])
        #expect(try PackageCatalogPolicy.admit(PackageInventory(packages: [], resources: additiveResources)).resources == additiveResources)

        let updates = [PackageUpdate(
            source: "package",
            displayName: "Package",
            type: "git",
            scope: .user
        )]
        #expect(try PackageCatalogPolicy.admit(updates) == updates)
    }

    @Test("rejects duplicate and oversized typed identities or resources")
    func rejectsInvalidCatalogs() {
        let duplicate = PackageSummary(
            source: "same",
            scope: .user,
            filtered: false,
            installedPath: nil
        )
        #expect(throws: GatewayFailure.self) {
            _ = try PackageCatalogPolicy.admit(PackageInventory(
                packages: [duplicate, duplicate],
                resources: emptyResources
            ))
        }
        #expect(throws: GatewayFailure.self) {
            _ = try PackageCatalogPolicy.admit([
                PackageUpdate(source: "same", displayName: "First", type: "git", scope: .user),
                PackageUpdate(source: "same", displayName: "Second", type: "npm", scope: .user),
            ])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try PackageCatalogPolicy.admit(PackageInventory(
                packages: Array(repeating: duplicate, count: PackageCatalogPolicy.maximumPackages + 1),
                resources: emptyResources
            ))
        }
        #expect(throws: GatewayFailure.self) {
            _ = try PackageCatalogPolicy.admit(PackageInventory(
                packages: [PackageSummary(
                    source: String(repeating: "x", count: PackageCatalogPolicy.maximumStringBytes - 1),
                    scope: .project,
                    filtered: false,
                    installedPath: nil
                )],
                resources: emptyResources
            ))
        }
        #expect(throws: GatewayFailure.self) {
            _ = try PackageCatalogPolicy.admit((0..<PackageCatalogPolicy.maximumUpdates).map { index in
                PackageUpdate(
                    source: "package-\(index)",
                    displayName: String(repeating: "n", count: 4_000),
                    type: "git",
                    scope: .user
                )
            })
        }

        let resource: JSONValue = .object([
            "path": .string("/same"),
            "enabled": .bool(true),
            "metadata": .object([
                "source": .string("package"),
                "scope": .string("user"),
                "origin": .string("package"),
            ]),
        ])
        #expect(throws: GatewayFailure.self) {
            _ = try PackageCatalogPolicy.admit(PackageInventory(
                packages: [],
                resources: .object([
                    "extensions": .array([]),
                    "skills": .array([]),
                    "prompts": .array([resource, resource]),
                    "themes": .array([]),
                ])
            ))
        }
    }
}
