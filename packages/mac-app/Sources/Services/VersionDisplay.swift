import Foundation

enum VersionDisplay {
    static func label(for rawVersion: String) -> String {
        guard let parsed = ParsedVersion(rawVersion) else {
            return rawVersion.hasPrefix("v") ? rawVersion : "v\(rawVersion)"
        }
        return parsed.displayLabel
    }

    private struct ParsedVersion {
        let major: Int
        let minor: Int
        let patch: Int
        let beta: Int?

        init?(_ raw: String) {
            let scoped = raw.split(separator: "v", omittingEmptySubsequences: false).last.map(String.init) ?? raw
            let pieces = scoped.split(separator: "-", maxSplits: 1).map(String.init)
            let base = pieces[0]
            let baseParts = base.split(separator: ".")
            let numbers = baseParts.compactMap { Int($0) }
            guard baseParts.count == 3, numbers.count == 3 else { return nil }

            var beta: Int?
            if pieces.count == 2 {
                let pre = pieces[1]
                guard pre.hasPrefix("beta.") else { return nil }
                let suffix = String(pre.dropFirst("beta.".count))
                guard let parsedBeta = Int(suffix), parsedBeta > 0 else { return nil }
                beta = parsedBeta
            }

            self.major = numbers[0]
            self.minor = numbers[1]
            self.patch = numbers[2]
            self.beta = beta
        }

        var displayLabel: String {
            var label = patch == 0 ? "v\(major).\(minor)" : "v\(major).\(minor).\(patch)"
            if let beta {
                label += " (Beta \(beta))"
            }
            return label
        }
    }
}
