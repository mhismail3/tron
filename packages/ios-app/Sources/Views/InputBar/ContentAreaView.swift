import SwiftUI

// MARK: - Content Area View (Attachments + Skills)

/// Main content area showing skills, attachments (with wrapping), and status pills.
/// All items in one wrapping container - skills at bottom, attachments wrap above.
struct ContentAreaView: View {
    let selectedSkills: [Skill]
    let attachments: [Attachment]
    let attachmentCapability: AttachmentCapability
    let onSkillRemove: ((Skill) -> Void)?
    let onSkillDetailTap: ((Skill) -> Void)?
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

            // Line break to ensure attachments always start on new row above skills
            if !selectedSkills.isEmpty && !attachments.isEmpty {
                LineBreak()
            }

            // Attachments after (will wrap to rows above skills)
            ForEach(attachments) { attachment in
                AttachmentBubble(attachment: attachment, capability: attachmentCapability) {
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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: attachments.count)
    }
}

