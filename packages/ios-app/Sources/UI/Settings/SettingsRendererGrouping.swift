import SwiftUI
import TronMobileCore

/// How `SettingsRendererView` groups and orders the Gateway's keys: pure functions of the
/// resolution, kept apart from the view's state and actions.
extension SettingsRendererView {
    /// A one-row group whose row carries the group's own title needs no heading.
    static func rowNamesGroup(_ group: DetailGroup) -> Bool {
        group.keys.count == 1 && group.keys[0].presentation?.label == group.title
    }

    struct DetailGroup {
        let title: String
        var detail: String? = nil
        var instanced = false
        var keys: [ResolvedSetting]
        /// One key with more instances than a group should list inline.
        var manyInstances: ResolvedSetting? { instanced && keys.count > SettingsRendererView.inlineInstanceLimit ? keys.first : nil }
    }

    static let inlineInstanceLimit = 8

    static func detailGroups(_ section: SettingsRendererSection, keys: [ResolvedSetting]) -> [DetailGroup] {
        var groups: [DetailGroup] = []
        func add(_ title: String, _ key: ResolvedSetting, detail: String? = nil, instanced: Bool = false) {
            if let index = groups.firstIndex(where: { $0.title == title && $0.instanced == instanced }) { groups[index].keys.append(key) }
            else { groups.append(DetailGroup(title: title, detail: detail, instanced: instanced, keys: [key])) }
        }
        let single = keys.filter { instanceCount($0, in: keys) == 1 }
        // Keep the main group coherent: importance ranks values, not another
        // one-row “Advanced” card. Only multi-row subgroups earn a heading.
        let subgroups = Dictionary(grouping: single.filter { $0.subgroup != nil }, by: { $0.subgroup! })
        for key in single where key.subgroup == nil || key.subgroup == section.title || (subgroups[key.subgroup ?? ""]?.count ?? 0) < 2 {
            add(section.title, key)
        }
        for key in single {
            if let subgroup = key.subgroup, subgroup != section.title, (subgroups[subgroup]?.count ?? 0) >= 2 { add(subgroup, key) }
        }
        for key in keys where instanceCount(key, in: keys) > 1 {
            let many = instanceCount(key, in: keys) > inlineInstanceLimit
            add(key.presentation?.label ?? key.key, key, detail: many ? nil : key.presentation?.help, instanced: true)
        }
        return groups
    }

    static func instanceCount(_ setting: ResolvedSetting, in keys: [ResolvedSetting]) -> Int {
        keys.reduce(0) { $0 + ($1.key == setting.key ? 1 : 0) }
    }

    enum RowTitle {
        static func instance(_ setting: ResolvedSetting) -> String {
            SettingsRendererRow.instanceName(setting) ?? setting.id
        }
    }
    // MARK: Ordering

    /// The Gateway's sections, plus any group a key names that no section declares,
    /// so a value is never hidden.
    static func sections(_ resolution: SettingsResolution) -> [SettingsRendererSection] {
        let declared = resolution.sections.sorted { $0.order < $1.order }
        let known = Set(declared.map(\.id))
        let undeclared = resolution.keys.map(\.group).filter { !known.contains($0) }
        return declared + Array(Set(undeclared)).sorted().map { SettingsRendererSection(id: $0) }
    }

    static func sorted(_ keys: [ResolvedSetting]) -> [ResolvedSetting] {
        keys.sorted { ($0.presentation?.order ?? .max, $0.id) < ($1.presentation?.order ?? .max, $1.id) }
    }
}
