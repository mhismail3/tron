import Testing
@testable import TronMobile

@Suite("New session configuration ownership")
struct NewSessionConfigurationOwnerTests {
    @Test("workspace changes close creation until the matching loads finish")
    func workspaceSwitchAdmission() {
        var owner = NewSessionConfigurationOwner()
        owner.begin(workspace: "/workspace/a")
        #expect(!owner.permitsCreation(workspace: "/workspace/a", requiresTrust: false))

        let admittedA = owner.admit(workspace: "/workspace/a", settingsReady: true, trustReady: true)
        #expect(admittedA)
        #expect(owner.permitsCreation(workspace: "/workspace/a", requiresTrust: false))
        #expect(!owner.permitsCreation(workspace: "/workspace/a", requiresTrust: true))

        owner.begin(workspace: "/workspace/b")
        #expect(!owner.permitsCreation(workspace: "/workspace/b", requiresTrust: false))
        let admittedStaleA = owner.admit(workspace: "/workspace/a", settingsReady: true, trustReady: true)
        #expect(!admittedStaleA)
        #expect(!owner.permitsCreation(workspace: "/workspace/b", requiresTrust: false))

        let admittedWithoutTrust = owner.admit(workspace: "/workspace/b", settingsReady: true, trustReady: false)
        #expect(!admittedWithoutTrust)
        #expect(!owner.permitsCreation(workspace: "/workspace/b", requiresTrust: false))
        let admittedB = owner.admit(workspace: "/workspace/b", settingsReady: true, trustReady: true)
        #expect(admittedB)
        #expect(owner.permitsCreation(workspace: "/workspace/b", requiresTrust: false))
    }
}
