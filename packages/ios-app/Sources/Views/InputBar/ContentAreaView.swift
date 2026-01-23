import SwiftUI

// MARK: - Content Area View (Attachments + Skills)

/// Main content area showing skills, spells, attachments (with wrapping), and status pills
/// All items in one wrapping container - skills and spells at bottom, attachments wrap above
@available(iOS 26.0, *)
struct ContentAreaView: View {
    let selectedSkills: [Skill]
    let selectedSpells: [Skill]
    let attachments: [Attachment]
    let onSkillRemove: ((Skill) -> Void)?
    let onSkillDetailTap: ((Skill) -> Void)?
    let onSpellRemove: ((Skill) -> Void)?
    let onSpellDetailTap: ((Skill) -> Void)?
    let onRemoveAttachment: (Attachment) -> Void

    var body: some View {
        WrappingHStack(spacing: 8, lineSpacing: 8) {
            // Skills first (will appear on bottom rows)
            ForEach(selectedSkills, id: \.name) { skill in
                SkillChip(
                    skill: skill,
                    showRemoveButton: true,
                    onRemove: { onSkillRemove?(skill) },
                    onTap: { onSkillDetailTap?(skill) }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8).combined(with: .opacity),
                    removal: .scale(scale: 0.6).combined(with: .opacity)
                ))
            }

            // Spells (ephemeral skills) with pink styling
            ForEach(selectedSpells, id: \.name) { skill in
                SkillChip(
                    skill: skill,
                    mode: .spell,
                    showRemoveButton: true,
                    onRemove: { onSpellRemove?(skill) },
                    onTap: { onSpellDetailTap?(skill) }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8).combined(with: .opacity),
                    removal: .scale(scale: 0.6).combined(with: .opacity)
                ))
            }

            // Line break to ensure attachments always start on new row above skills/spells
            if (!selectedSkills.isEmpty || !selectedSpells.isEmpty) && !attachments.isEmpty {
                LineBreak()
            }

            // Attachments after (will wrap to rows above skills/spells)
            ForEach(attachments) { attachment in
                AttachmentBubble(attachment: attachment) {
                    onRemoveAttachment(attachment)
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8).combined(with: .opacity),
                    removal: .scale(scale: 0.6).combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedSkills.count)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedSpells.count)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: attachments.count)
    }
}

// MARK: - Skill Chips Row (Inline)

/// Skills chips displayed inline in a horizontal scroll view
@available(iOS 26.0, *)
struct SkillChipsRowInline: View {
    let skills: [Skill]
    let onRemove: (Skill) -> Void
    let onTap: ((Skill) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(skills, id: \.name) { skill in
                    SkillChip(
                        skill: skill,
                        showRemoveButton: true,
                        onRemove: { onRemove(skill) },
                        onTap: { onTap?(skill) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Attachments Row (Inline)

/// Attachments displayed inline in a horizontal scroll view
struct AttachmentsRowInline: View {
    let attachments: [Attachment]
    let onRemove: (Attachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentBubble(attachment: attachment) {
                        onRemove(attachment)
                    }
                }
            }
        }
        .frame(height: 60)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Unified Attachments Row (with padding)

struct AttachmentsRow: View {
    let attachments: [Attachment]
    let onRemove: (Attachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentBubble(attachment: attachment) {
                        onRemove(attachment)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 60)
    }
}

// MARK: - Skill Mention Helpers

extension String {
    /// Find completed @skillname mentions in text and return matching skills
    func findCompletedSkillMentions(skills: [Skill], excludeSelected: [Skill]) -> [Skill] {
        let pattern = "@([a-zA-Z0-9][a-zA-Z0-9-]*)(?:\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let nsText = self as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: self, options: [], range: range)

        var foundSkills: [Skill] = []

        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let skillNameRange = match.range(at: 1)
            let skillName = nsText.substring(with: skillNameRange)

            guard !skillName.isEmpty else { continue }

            // Check if this @ is at start or preceded by whitespace
            let atIndex = match.range.location
            if atIndex > 0 {
                let prevChar = nsText.character(at: atIndex - 1)
                let prevCharScalar = Unicode.Scalar(prevChar)!
                let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(prevCharScalar)
                guard isWhitespace else { continue }
            }

            // Check if @ is inside backticks
            let beforeAt = nsText.substring(to: atIndex)
            let backtickCount = beforeAt.filter { $0 == "`" }.count
            if backtickCount % 2 != 0 { continue }

            // Check if this matches an actual skill
            if let skill = skills.first(where: { $0.name.lowercased() == skillName.lowercased() }) {
                if !excludeSelected.contains(where: { $0.name.lowercased() == skillName.lowercased() }) {
                    foundSkills.append(skill)
                }
            }
        }

        return foundSkills
    }
}
