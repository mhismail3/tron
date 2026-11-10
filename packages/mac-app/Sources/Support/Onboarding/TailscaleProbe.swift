import Darwin
import Foundation

enum TailscaleProbe {
    static func probe() async -> TailscaleStatus {
        await probe(
            tailscaleAppExists: { FileManager.default.fileExists(atPath: $0.path) },
            cliPaths: defaultCLIPaths,
            runProcess: { url in
                await Subprocess.run(
                    executable: url,
                    arguments: ["status", "--peers=false", "--json"],
                    policy: .observation
                )
            }
        )
    }

    static func probe(
        tailscaleAppExists: (URL) -> Bool,
        cliPaths: [URL],
        runProcess: (URL) async -> ProcessResult
    ) async -> TailscaleStatus {
        let appURL = URL(fileURLWithPath: "/Applications/Tailscale.app")
        let appPresent = tailscaleAppExists(appURL)

        var sawExecutableCLI = false
        for candidate in cliPaths where FileManager.default.isExecutableFile(atPath: candidate.path) {
            sawExecutableCLI = true
            guard !Task.isCancelled else { break }
            let result = await runProcess(candidate)
            guard !Task.isCancelled else { break }

            guard result.exitCode == 0 else { continue }

            guard let data = result.stdout.data(using: .utf8),
                  let status = try? JSONDecoder().decode(TailscaleStatusJSON.self, from: data) else {
                continue
            }

            guard status.BackendState == "Running" else {
                continue
            }

            let candidateIPs = status.`Self`?.TailscaleIPs ?? status.TailscaleIPs ?? []
            if let address = selectedAddress(candidateIPs) {
                return .signedIn(address: address)
            }
        }

        return appPresent || sawExecutableCLI ? .installedNotSignedIn : .notInstalled
    }

    static let defaultCLIPaths: [URL] = [
        URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
        URL(fileURLWithPath: "/usr/local/bin/tailscale"),
        URL(fileURLWithPath: "/opt/homebrew/bin/tailscale"),
    ]

    static func selectedAddress(_ candidates: [String]) -> String? {
        candidates.filter(isTailscaleAddress).sorted { left, right in
            let leftIPv4 = isIPv4(left)
            let rightIPv4 = isIPv4(right)
            if leftIPv4 != rightIPv4 { return leftIPv4 }
            if leftIPv4 {
                return ipv4Octets(left).lexicographicallyPrecedes(ipv4Octets(right))
            }
            let normalizedLeft = left.lowercased()
            let normalizedRight = right.lowercased()
            return normalizedLeft == normalizedRight ? left < right : normalizedLeft < normalizedRight
        }.first
    }

    static func isTailscaleAddress(_ candidate: String) -> Bool {
        guard !candidate.contains("%") else { return false }
        if isIPv4(candidate) {
            let octets = ipv4Octets(candidate)
            return octets[0] == 100 && (64...127).contains(octets[1])
        }
        return candidate.lowercased().hasPrefix("fd7a:115c:a1e0:") && isIPv6(candidate)
    }

    static func isIPv4(_ candidate: String) -> Bool {
        ipv4Octets(candidate).count == 4
    }

    private static func ipv4Octets(_ candidate: String) -> [Int] {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return [] }
        let values = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            return value
        }
        return values.count == 4 ? values : []
    }

    static func isIPv6(_ candidate: String) -> Bool {
        var storage = in6_addr()
        return candidate.withCString { inet_pton(AF_INET6, $0, &storage) } == 1
    }
}

private struct TailscaleStatusJSON: Decodable {
    let BackendState: String?
    let TailscaleIPs: [String]?
    let `Self`: SelfStatus?

    struct SelfStatus: Decodable {
        let TailscaleIPs: [String]?
    }
}
