import Foundation
import os

// MARK: - Input History Store

@MainActor
class InputHistoryStore: ObservableObject {
    private let logger = Logger(subsystem: "com.tron.mobile", category: "InputHistoryStore")
    private let storageKey = "tron.inputHistory"
    private let maxHistorySize = 100

    @Published private(set) var history: [String] = []
    @Published private(set) var currentIndex: Int = -1

    private var tempInput: String = ""

    init() {
        loadHistory()
    }

    // MARK: - Persistence

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            history = decoded
            logger.debug("Loaded \(decoded.count) history items")
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - History Management

    func addToHistory(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Don't add duplicates at the top
        if history.first == trimmed { return }

        // Remove any existing occurrence
        history.removeAll { $0 == trimmed }

        // Add to front
        history.insert(trimmed, at: 0)

        // Trim to max size
        if history.count > maxHistorySize {
            history = Array(history.prefix(maxHistorySize))
        }

        // Reset navigation
        currentIndex = -1
        tempInput = ""

        saveHistory()
    }

    func navigateUp(currentInput: String) -> String? {
        guard !history.isEmpty else { return nil }

        // Save current input if starting navigation
        if currentIndex == -1 {
            tempInput = currentInput
        }

        // Move up in history
        let newIndex = currentIndex + 1
        guard newIndex < history.count else { return nil }

        currentIndex = newIndex
        return history[currentIndex]
    }

    func navigateDown() -> String? {
        guard currentIndex >= 0 else { return nil }

        // Move down in history
        let newIndex = currentIndex - 1

        if newIndex < 0 {
            // Return to the temp input
            currentIndex = -1
            return tempInput
        }

        currentIndex = newIndex
        return history[currentIndex]
    }

    func resetNavigation() {
        currentIndex = -1
        tempInput = ""
    }

    var isNavigating: Bool {
        currentIndex >= 0
    }

    var navigationPosition: String? {
        guard isNavigating else { return nil }
        return "\(currentIndex + 1)/\(history.count)"
    }

    func clearHistory() {
        history = []
        currentIndex = -1
        tempInput = ""
        saveHistory()
    }
}
