import SwiftUI

@main
struct TronMobileApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var eventDatabase = EventDatabase()
    @Environment(\.scenePhase) private var scenePhase

    // EventStoreManager is created lazily since it needs appState.rpcClient
    @State private var eventStoreManager: EventStoreManager?

    init() {
        TronFontLoader.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if #available(iOS 26.0, *) {
                    if let manager = eventStoreManager {
                        ContentView()
                            .environmentObject(appState)
                            .environmentObject(manager)
                            .environmentObject(eventDatabase)
                    } else {
                        // Loading state while initializing
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .tronEmerald))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // Fallback for older iOS versions
                    Text("This app requires iOS 26 or later")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .preferredColorScheme(.dark)
            .task {
                // Initialize event database and store manager on app launch
                do {
                    try await eventDatabase.initialize()

                    // Create EventStoreManager with dependencies
                    let manager = EventStoreManager(
                        eventDB: eventDatabase,
                        rpcClient: appState.rpcClient
                    )
                    manager.initialize()

                    // Repair any duplicate events from previous sessions
                    // This fixes the race condition between local caching and server sync
                    manager.repairDuplicates()

                    await MainActor.run {
                        eventStoreManager = manager
                    }

                    logger.info("Event store initialized with \(manager.sessions.count) sessions", category: .session)
                } catch {
                    logger.error("Failed to initialize event store: \(error)", category: .session)
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                let isBackground = newPhase != .active
                appState.rpcClient.setBackgroundState(isBackground)
                eventStoreManager?.setBackgroundState(isBackground)
                logger.info("Scene phase changed: \(oldPhase) -> \(newPhase), background=\(isBackground)", category: .session)
            }
        }
    }
}
