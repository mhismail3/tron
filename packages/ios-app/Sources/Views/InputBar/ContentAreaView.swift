import SwiftUI

// MARK: - Content Area View (Attachments + Skills)

enum ContentAreaChipItem: Identifiable, Equatable {
    case skill(Skill)
    case attachment(Attachment)

    var id: String {
        switch self {
        case .skill(let skill):
            return "skill:\(skill.id)"
        case .attachment(let attachment):
            return "attachment:\(attachment.id.uuidString)"
        }
    }

    static func items(selectedSkills: [Skill], attachments: [Attachment]) -> [ContentAreaChipItem] {
        selectedSkills.map(ContentAreaChipItem.skill) + attachments.map(ContentAreaChipItem.attachment)
    }
}

/// Main content area showing skills, attachments (with wrapping), and status pills.
/// Skills and attachments share one wrapping container so mixed chips align row-by-row.
struct ContentAreaView: View {
    let selectedSkills: [Skill]
    let attachments: [Attachment]
    let attachmentCapability: AttachmentCapability
    let onSkillRemove: ((Skill) -> Void)?
    let onSkillDetailTap: ((Skill) -> Void)?
    let onRemoveAttachment: (Attachment) -> Void

    var body: some View {
        WrappingHStack(spacing: 8, lineSpacing: 8) {
            ForEach(ContentAreaChipItem.items(selectedSkills: selectedSkills, attachments: attachments)) { item in
                switch item {
                case .skill(let skill):
                    SkillChip(
                        skill: skill,
                        showRemoveButton: true,
                        onRemove: { onSkillRemove?(skill) },
                        onTap: { onSkillDetailTap?(skill) }
                    )
                    .transition(chipTransition)

                case .attachment(let attachment):
                    AttachmentBubble(attachment: attachment, capability: attachmentCapability) {
                        onRemoveAttachment(attachment)
                    }
                    .transition(chipTransition)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedSkills.count)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: attachments.count)
    }

    private var chipTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.8).combined(with: .opacity),
            removal: .scale(scale: 0.6).combined(with: .opacity)
        )
    }
}
