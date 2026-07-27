import Testing

@testable import TronMobile

@Suite("Native notification policy")
struct NativeNotificationPolicyTests {
    @Test("permission waits for authentication and is attempted once per launch")
    func permissionTiming() {
        #expect(!NativeNotificationPermissionPolicy.shouldRequest(
            hasAuthenticatedConnection: false,
            attemptedThisLaunch: false,
            status: .notDetermined
        ))
        #expect(NativeNotificationPermissionPolicy.shouldRequest(
            hasAuthenticatedConnection: true,
            attemptedThisLaunch: false,
            status: .notDetermined
        ))
        #expect(!NativeNotificationPermissionPolicy.shouldRequest(
            hasAuthenticatedConnection: true,
            attemptedThisLaunch: true,
            status: .notDetermined
        ))
        #expect(!NativeNotificationPermissionPolicy.shouldRequest(
            hasAuthenticatedConnection: true,
            attemptedThisLaunch: false,
            status: .denied
        ))
    }

    @Test("only Apple-authorized states register for remote notifications")
    func registrationReadiness() {
        #expect(NativeNotificationPermissionPolicy.permitsRemoteRegistration(.authorized))
        #expect(NativeNotificationPermissionPolicy.permitsRemoteRegistration(.provisional))
        #expect(NativeNotificationPermissionPolicy.permitsRemoteRegistration(.ephemeral))
        #expect(!NativeNotificationPermissionPolicy.permitsRemoteRegistration(.denied))
        #expect(!NativeNotificationPermissionPolicy.permitsRemoteRegistration(.notDetermined))
    }

    @Test("an already-authorized launch does not depend on engine connectivity")
    func authorizedLaunchRegistration() {
        #expect(NativeNotificationPermissionPolicy.permitsRemoteRegistration(.authorized))
        #expect(!NativeNotificationPermissionPolicy.shouldRequest(
            hasAuthenticatedConnection: false,
            attemptedThisLaunch: false,
            status: .authorized
        ))
    }

    @Test("the signed build route selects its matching APNs provider")
    func configuredAPNSEnvironment() {
        #expect(NativeNotificationCoordinator.apnsEnvironment(
            configuredValue: "sandbox"
        ) == .sandbox)
        #expect(NativeNotificationCoordinator.apnsEnvironment(
            configuredValue: "production"
        ) == .production)
    }

    @Test("notification lifecycle evidence hashes route and omits content")
    func notificationEvidenceIsSanitized() {
        let payload: [AnyHashable: Any] = [
            "tron": [
                "serverId": "server-secret",
                "deliveryId": "delivery-secret",
            ],
            "aps": ["alert": ["body": "private reminder body"]],
        ]
        let route = NotificationLifecycleBridge.evidenceRoute(payload)

        #expect(route.count == 12)
        #expect(!route.contains("server-secret"))
        #expect(!route.contains("delivery-secret"))
        #expect(!route.contains("private reminder body"))
        #expect(NativeNotificationCoordinator.quietRefreshWaitBudget <= .seconds(8))
    }
}
