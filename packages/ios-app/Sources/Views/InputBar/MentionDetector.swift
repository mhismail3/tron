import Foundation

/// Detector for `@skill` mentions in the input bar. The trigger is
/// hardcoded — when other mention types existed (`%spell`) we generalised
/// over the trigger character; the post-Spells codebase only mentions
/// skills via `@`, so the abstraction is collapsed to a free-function
/// namespace. Tests cover detection, completion, and filtering.
enum SkillMentions {
    /// Trigger character used for skill mentions.
    static let trigger: Character = "@"

    /// Detect an in-progress mention in `text`. Returns the query string
    /// after the `@` if the user is currently typing a mention, `nil`
    /// otherwise (no `@`, `@` followed by a space, `@` inside a code
    /// span, …).
    static func detectMention(in text: String) -> String? {
        guard let triggerIndex = text.lastIndex(of: trigger) else { return nil }

        // Trigger must be at start or preceded by whitespace
        if triggerIndex != text.startIndex {
            let prevChar = text[text.index(before: triggerIndex)]
            guard prevChar.isWhitespace || prevChar.isNewline else { return nil }
        }

        // Trigger inside an open code span — skip
        let beforeTrigger = text[..<triggerIndex]
        let backtickCount = beforeTrigger.filter { $0 == "`" }.count
        if backtickCount % 2 != 0 { return nil }

        let afterTrigger = text[text.index(after: triggerIndex)...]

        // Whitespace after the query means the mention is finished, not in-progress.
        if afterTrigger.contains(" ") || afterTrigger.contains("\n") { return nil }

        return String(afterTrigger)
    }

    /// Detect a completed mention (`@skill-name` followed by whitespace
    /// or end-of-string). Returns the matched skill if it exists in
    /// `skills` and isn't already in `alreadySelected`.
    static func detectCompletedMention(
        in text: String,
        skills: [Skill],
        alreadySelected: [Skill]
    ) -> Skill? {
        // `@` is not a regex metachar, so no escape needed.
        let pattern = "@([a-zA-Z0-9][a-zA-Z0-9-]*)(?:\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let nameRange = match.range(at: 1)
            let name = nsText.substring(with: nameRange)
            guard !name.isEmpty else { continue }

            // Trigger must be at start or preceded by whitespace.
            let triggerIdx = match.range.location
            if triggerIdx > 0 {
                let prevChar = nsText.character(at: triggerIdx - 1)
                guard let scalar = Unicode.Scalar(prevChar),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            }

            // Skip if inside an open code span.
            let beforeTrigger = nsText.substring(to: triggerIdx)
            let backtickCount = beforeTrigger.filter { $0 == "`" }.count
            if backtickCount % 2 != 0 { continue }

            if let skill = skills.first(where: { $0.name.lowercased() == name.lowercased() }) {
                if !alreadySelected.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                    return skill
                }
            }
        }
        return nil
    }

    /// Filter and sort skills against `query`. Empty query returns the
    /// list verbatim; non-empty matches name / description / tag and
    /// sorts prefix matches first then by ascending name length.
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
