import Foundation

/// Explicit local-storage inputs for the application composition root.
/// Production resolves the same standard defaults/Documents/database paths as
/// before; tests must provide fixture-owned values.
struct DependencyContainerStorage {
    let defaults: UserDefaults
    let documentsURL: URL
    let eventDatabase: EventDatabase

    @MainActor
    static func production(
        defaults: () -> UserDefaults = { .standard },
        documentsURL: () -> URL? = {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        },
        eventDatabase: () -> EventDatabase? = { EventDatabase() }
    ) -> Self {
        guard let documentsURL = documentsURL() else {
            preconditionFailure("Documents directory unavailable; cannot initialize iOS local projection stores")
        }
        guard let eventDatabase = eventDatabase() else {
            preconditionFailure("Documents directory unavailable; cannot initialize EventDatabase")
        }
        return Self(
            defaults: defaults(),
            documentsURL: documentsURL,
            eventDatabase: eventDatabase
        )
    }
}
