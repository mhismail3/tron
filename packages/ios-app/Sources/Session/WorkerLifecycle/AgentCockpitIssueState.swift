extension AgentCockpitOverview {
    var issueCount: Int {
        discovery.missingSchemaCount
            + discovery.degradedFunctionCount
            + discovery.catalogDecodeIssueCount
            + classificationIssueCount
            + degradedWorkerIssueCount
            + moduleActivityIssueCount
            + failedClosedRouteIssueCount
            + projectionCompletenessIssueCount
            + verificationIssueCount
            + (refreshFailed ? 1 : 0)
    }

    var issueDetail: String {
        if refreshFailed {
            return status.detail
        }
        if degradedWorkerIssueCount > 0 {
            return "\(degradedWorkerIssueCount) worker\(degradedWorkerIssueCount == 1 ? "" : "s") reported degraded health."
        }
        if moduleActivityIssueCount > 0, let moduleActivity {
            return moduleActivity.summary.detail.isEmpty
                ? "Module activity contains blocked or degraded work."
                : moduleActivity.summary.detail
        }
        if failedClosedRouteIssueCount > 0 {
            return "\(failedClosedRouteIssueCount) operation\(failedClosedRouteIssueCount == 1 ? "" : "s") recorded failed-closed replacement routing."
        }
        if projectionCompletenessIssueCount > 0 {
            return "Dashboard operation or supporting-evidence results were bounded before the full projection was returned."
        }
        if classificationIssueCount > 0 {
            return "\(classificationIssueCount) operation\(classificationIssueCount == 1 ? " is" : "s are") missing capability-pool classification."
        }
        if verificationIssueCount > 0 {
            return AgentCockpitPresentation.verificationDetail(for: discovery)
        }
        return discovery.detail
    }

    private var classificationIssueCount: Int {
        modularityOperations.filter { $0.capabilitySurface == "unknown" }.count
    }

    private var degradedWorkerIssueCount: Int {
        workers.filter { AgentCockpitProjection.normalized($0.lifecycle) == "degraded" }.count
    }

    private var moduleActivityIssueCount: Int {
        guard let moduleActivity else { return 0 }
        let issueStatuses: Set<String> = ["blocked", "degraded", "failed", "quarantined"]
        var representedIssueIds = Set(
            moduleActivity.timeline.filter { item in
                issueStatuses.contains(AgentCockpitProjection.normalized(item.status))
                    || item.rollbackStatus.blocked
                    || item.quarantineStatus.blocked
                    || item.runtimeAuthorizationStatus.blocked
            }.map(\.id)
        )
        representedIssueIds.formUnion(moduleActivity.blocked.map(\.id))
        let summaryLowerBound = max(
            moduleActivity.summary.blocked,
            moduleActivity.summary.degraded ?? 0
        )
        return max(representedIssueIds.count, summaryLowerBound)
    }

    private var failedClosedRouteIssueCount: Int {
        let returnedOperations = modularityOperations.filter { $0.routeFailedClosed > 0 }.count
        let summaryLowerBound = (capabilityVisibility?.summary.failedClosedRoutes ?? 0) > 0 ? 1 : 0
        return max(returnedOperations, summaryLowerBound)
    }

    private var projectionCompletenessIssueCount: Int {
        guard let capabilityVisibility else { return 0 }
        let operationListIncomplete = !capabilityVisibility.operationList.complete
            || capabilityVisibility.operationList.truncated
        let resourceScanIncomplete = !capabilityVisibility.resourceScan.complete
            || capabilityVisibility.resourceScan.truncated
        return (operationListIncomplete ? 1 : 0) + (resourceScanIncomplete ? 1 : 0)
    }

    private var verificationIssueCount: Int {
        guard let lifecycle = discovery.latestReport?.lifecycle else { return 0 }
        return ["failed", "quarantined"].contains(AgentCockpitProjection.normalized(lifecycle)) ? 1 : 0
    }
}
