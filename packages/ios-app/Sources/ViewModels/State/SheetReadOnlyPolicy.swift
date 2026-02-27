enum SheetReadOnlyPolicy {
    static func isReadOnly(workspaceDeleted: Bool, agentPhase: AgentPhase) -> Bool {
        workspaceDeleted || agentPhase.isActive
    }
}
