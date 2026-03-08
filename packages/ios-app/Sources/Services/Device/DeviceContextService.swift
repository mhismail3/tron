import AVFoundation
import Foundation
import Network
import UIKit

/// Collects device signals for injection into agent system prompts.
///
/// Battery, network type, audio route, display state, timezone, and locale
/// are collected on demand when the agent sends a prompt. Only signals enabled
/// in integration settings are included.
@MainActor
final class DeviceContextService {
    static let shared = DeviceContextService()

    private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.currentPath = path
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.tron.network-monitor"))
    }

    /// Collect enabled device context signals as a dictionary.
    func collectContext(settings: ServerSettings.IntegrationSettings.DeviceContextSettings) -> [String: Any] {
        guard settings.enabled else { return [:] }

        var ctx: [String: Any] = [:]

        if settings.battery {
            let level = UIDevice.current.batteryLevel
            let state = UIDevice.current.batteryState
            if level >= 0 {
                ctx["batteryLevel"] = Int(level * 100)
                ctx["batteryState"] = batteryStateString(state)
            }
        }

        if settings.network {
            if let path = currentPath {
                if path.usesInterfaceType(.wifi) {
                    ctx["networkType"] = "wifi"
                } else if path.usesInterfaceType(.cellular) {
                    ctx["networkType"] = "cellular"
                } else {
                    ctx["networkType"] = "none"
                }
                ctx["isExpensiveNetwork"] = path.isExpensive
            }
        }

        if settings.audioRoute {
            let route = AVAudioSession.sharedInstance().currentRoute
            if let output = route.outputs.first {
                ctx["audioRoute"] = output.portType.rawValue
            }
        }

        if settings.display {
            ctx["brightness"] = Int(UIScreen.main.brightness * 100)
            ctx["darkMode"] = UITraitCollection.current.userInterfaceStyle == .dark
        }

        // Always include timezone and locale
        ctx["timezone"] = TimeZone.current.identifier
        ctx["locale"] = Locale.current.identifier

        return ctx
    }

    /// Format context as a compact string for system prompt injection.
    func formatContextLine(
        settings: ServerSettings.IntegrationSettings.DeviceContextSettings,
        locationSettings: ServerSettings.IntegrationSettings.LocationSettings? = nil
    ) -> String? {
        let ctx = collectContext(settings: settings)
        guard !ctx.isEmpty else { return nil }

        var parts: [String] = []

        if let level = ctx["batteryLevel"] as? Int, let state = ctx["batteryState"] as? String {
            parts.append("battery \(level)% \(state)")
        }
        if let network = ctx["networkType"] as? String {
            parts.append(network.capitalized)
        }
        if let darkMode = ctx["darkMode"] as? Bool {
            parts.append(darkMode ? "dark mode" : "light mode")
        }
        if let audioRoute = ctx["audioRoute"] as? String {
            parts.append(audioRoute)
        }
        if let tz = ctx["timezone"] as? String {
            parts.append(tz)
        }

        // Append location if enabled
        if let locSettings = locationSettings, locSettings.enabled,
           let locPart = LocationService.shared.formatContextPart(precision: locSettings.precision) {
            parts.append(locPart)
        }

        return "[Device: \(parts.joined(separator: " | "))]"
    }

    // MARK: - Helpers

    private func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}
