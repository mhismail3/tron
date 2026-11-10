import Foundation

enum StableGatewayProvenance {
    static func launchArguments(payloadRoot: String, runtime: String, host: String, port: Int) -> [String] {
        [
            "\(payloadRoot)/runtime/\(runtime)", "--max-old-space-size=4096", "\(payloadRoot)/app/dist/index.js",
            "--host", host, "--port", String(port),
        ]
    }

    static func validates(_ runtime: LaunchAgentRuntimeInfo, payload: GatewayPayloadValidationResult,
                          expectedHelperPath: String,
                          fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        runtime.pid != nil && runtime.parentBundleIdentifier == "com.tron.mac"
            && runtime.gatewaySupervisionMarker == "1" && runtime.gatewayChannelMarker == "stable"
            && helperProvenance(runtime, expectedHelperPath: expectedHelperPath, fileExists: fileExists)
            && payload.manifest.channel == "stable"
            && processCommand(runtime.processCommand, owns: payload.root, expectedHost: "tailscale", profile: .stable)
    }

    static func helperProvenance(
        _ runtimeInfo: LaunchAgentRuntimeInfo,
        expectedHelperPath: String,
        fileExists: (String) -> Bool
    ) -> Bool {
        let expected = URL(fileURLWithPath: expectedHelperPath).standardizedFileURL.path
        guard fileExists(expected) else { return false }
        if let executable = runtimeInfo.executablePath, !executable.isEmpty {
            return URL(fileURLWithPath: executable).standardizedFileURL.path == expected
        }
        guard let bundleProgram = runtimeInfo.bundleProgram,
              let contents = expected.range(of: "Contents/") else { return false }
        return bundleProgram == String(expected[contents.lowerBound...])
    }

    static func processCommand(
        _ command: String?,
        owns root: URL,
        expectedHost: String,
        profile: TronGatewayProfile
    ) -> Bool {
        guard let command else { return false }
        let fields = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let payloadRoot = root.standardizedFileURL.path
        let normalizedHost = expectedHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (profile == TronGatewayProfile.stable && normalizedHost == "tailscale")
            || (profile == TronGatewayProfile.debug && (normalizedHost == "tailscale" || normalizedHost == "127.0.0.1")) else { return false }
        return ["node-arm64", "node-x64"].contains { runtime in
            fields == launchArguments(payloadRoot: payloadRoot, runtime: runtime, host: normalizedHost, port: profile.port)
        }
    }

}
