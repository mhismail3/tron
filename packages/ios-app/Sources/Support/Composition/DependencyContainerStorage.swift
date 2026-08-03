import Foundation

/// Explicit local-storage inputs for the application composition root.
/// Production resolves the same standard defaults/Documents/database paths as
/// before; tests must provide fixture-owned values.
struct DependencyContainerStorage {
    let defaults: UserDefaults
    let documentsURL: URL
    let eventDatabase: EventDatabase
    let notificationStoreURL: URL

    init(
        defaults: UserDefaults,
        documentsURL: URL,
        eventDatabase: EventDatabase,
        notificationStoreURL: URL? = nil
    ) {
        self.defaults = defaults
        self.documentsURL = documentsURL
        self.eventDatabase = eventDatabase
        self.notificationStoreURL = notificationStoreURL
            ?? documentsURL
                .appendingPathComponent(
                    "ApplicationState",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "native-notifications-v2.json"
                )
    }

    @MainActor
    static func production(
        defaults: () -> UserDefaults = { .standard },
        documentsURL: () -> URL? = {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        },
        eventDatabase: () -> EventDatabase? = { EventDatabase() },
        notificationStoreURL: () -> URL? = {
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
                .appendingPathComponent("Tron", isDirectory: true)
                .appendingPathComponent(
                    "Notifications",
                    isDirectory: true
                )
                .appendingPathComponent("state-v2.json")
        }
    ) -> Self {
        guard let documentsURL = documentsURL() else {
            preconditionFailure("Documents directory unavailable; cannot initialize iOS local projection stores")
        }
        guard let eventDatabase = eventDatabase() else {
            preconditionFailure("Documents directory unavailable; cannot initialize EventDatabase")
        }
        guard let notificationStoreURL = notificationStoreURL() else {
            preconditionFailure(
                "Application Support unavailable for notification state"
            )
        }
        return Self(
            defaults: defaults(),
            documentsURL: documentsURL,
            eventDatabase: eventDatabase,
            notificationStoreURL: notificationStoreURL
        )
    }
}
