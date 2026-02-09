import Foundation

/// Generic mention detector parameterized by trigger character.
/// Replaces duplicated SkillMentionDetector and SpellMentionDetector.
struct MentionDetector {
    let trigger: Character

    /// Static instances for the two mention types
    static let skill = MentionDetector(trigger: "@")
    static let spell = MentionDetector(trigger: "%")

    /// Detect an in-progress mention in text.
    /// Returns the query string after the trigger if in mention mode, nil otherwise.
    func detectMention(in text: String) -> String? {
        guard let triggerIndex = text.lastIndex(of: trigger) else { return nil }

        // Trigger must be at start or preceded by whitespace
        if triggerIndex != text.startIndex {
            let prevChar = text[text.index(before: triggerIndex)]
            guard prevChar.isWhitespace || prevChar.isNewline else { return nil }
        }

        // Check if trigger is inside backticks (code)
        let beforeTrigger = text[..<triggerIndex]
        let backtickCount = beforeTrigger.filter { $0 == "`" }.count
        if backtickCount % 2 != 0 { return nil }

        // Extract query after trigger
        let afterTrigger = text[text.index(after: triggerIndex)...]

        // If there's a space/newline after the query, mention is complete (not in-progress)
        if afterTrigger.contains(" ") || afterTrigger.contains("\n") { return nil }

        return String(afterTrigger)
    }

    /// Detect a completed mention (trigger + skillname + space/end-of-string).
    /// Returns the matched skill if found and not already selected.
    func detectCompletedMention(in text: String, skills: [Skill], alreadySelected: [Skill]) -> Skill? {
        let triggerString = String(trigger)
        let pattern = "\(NSRegularExpression.escapedPattern(for: triggerString))([a-zA-Z0-9][a-zA-Z0-9-]*)(?:\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let nameRange = match.range(at: 1)
            let name = nsText.substring(with: nameRange)
            guard !name.isEmpty else { continue }

            // Check trigger is preceded by whitespace or at start
            let triggerIdx = match.range.location
            if triggerIdx > 0 {
                let prevChar = nsText.character(at: triggerIdx - 1)
                guard let scalar = Unicode.Scalar(prevChar),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            }

            // Check not inside backticks
            let beforeTrigger = nsText.substring(to: triggerIdx)
            let backtickCount = beforeTrigger.filter { $0 == "`" }.count
            if backtickCount % 2 != 0 { continue }

            // Match against skills
            if let skill = skills.first(where: { $0.name.lowercased() == name.lowercased() }) {
                if !alreadySelected.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                    return skill
                }
            }
        }
        return nil
    }

    /// Filter and sort skills by query. Shared by both skill and spell popups.
    static func filterSkills(_ skills: [Skill], query: String) -> [Skill] {
        guard !query.isEmpty else { return skills }

        let q = query.lowercased()
        return skills.filter { skill in
            skill.name.lowercased().contains(q) ||
            skill.description.lowercased().contains(q) ||
            (skill.tags?.contains { $0.lowercased().contains(q) } ?? false)
        }.sorted { lhs, rhs in
            let lhsPrefix = lhs.name.lowercased().hasPrefix(q)
            let rhsPrefix = rhs.name.lowercased().hasPrefix(q)
            if lhsPrefix != rhsPrefix { return lhsPrefix }
            return lhs.name.count < rhs.name.count
        }
    }
}
