import Foundation

/// Bounded projections of the Mac app replacement journal (#984). The Mac-side
/// orchestrator owns the journal; the Gateway reads it and these types decode
/// only the fields the progress sheet shows.
package struct MacReplacementStep: Codable, Hashable, Sendable, Identifiable {
    package let name: String
    package let title: String
    package let state: String
    package let detail: String?
    package let durationSeconds: Double?
    package let log: String?

    package var id: String { name }

    package init(name: String, title: String, state: String, detail: String? = nil,
                 durationSeconds: Double? = nil, log: String? = nil) {
        self.name = name
        self.title = title
        self.state = state
        self.detail = detail
        self.durationSeconds = durationSeconds
        self.log = log
    }
}

package struct MacReplacementError: Codable, Hashable, Sendable {
    package let step: String
    package let message: String
    package let log: String

    package init(step: String, message: String, log: String) {
        self.step = step
        self.message = message
        self.log = log
    }
}

package struct MacReplacementRollback: Codable, Hashable, Sendable {
    package let state: String
    package let detail: String?

    package init(state: String, detail: String?) {
        self.state = state
        self.detail = detail
    }
}

package struct MacReplacementOperation: Codable, Hashable, Sendable {
    package let id: String
    package let path: String
    package let reason: String
    package let state: String
    package let attempt: Int
    package let currentStep: String?
    package let steps: [MacReplacementStep]
    package let error: MacReplacementError?
    package let rollback: MacReplacementRollback?
    package let logPath: String?

    package init(id: String, path: String, reason: String, state: String, attempt: Int, currentStep: String?,
                 steps: [MacReplacementStep], error: MacReplacementError? = nil,
                 rollback: MacReplacementRollback? = nil, logPath: String? = nil) {
        self.id = id
        self.path = path
        self.reason = reason
        self.state = state
        self.attempt = attempt
        self.currentStep = currentStep
        self.steps = steps
        self.error = error
        self.rollback = rollback
        self.logPath = logPath
    }

    package var isTerminal: Bool { ["succeeded", "failed", "rolled-back", "rollback-failed"].contains(state) }

    /// While these steps run, the Gateway this iPhone talks to is expected to be down.
    package var swapsGateway: Bool {
        guard !isTerminal, let currentStep else { return false }
        return ["stop-gateway", "swap-app", "start", "rebuild"].contains(currentStep)
    }
}

package struct MacReplacementWorker: Codable, Hashable, Sendable, Identifiable {
    package let taskId: String
    package let sessionId: String
    package let title: String
    /// `resumable`, `resumed`, `stopping` or `unavailable`.
    package let state: String

    package var id: String { taskId }

    package init(taskId: String, sessionId: String, title: String, state: String) {
        self.taskId = taskId
        self.sessionId = sessionId
        self.title = title
        self.state = state
    }
}

package struct MacReplacementStatus: Codable, Hashable, Sendable {
    package let startable: Bool
    package let operation: MacReplacementOperation?
    package let workers: [MacReplacementWorker]

    package init(startable: Bool, operation: MacReplacementOperation?, workers: [MacReplacementWorker]) {
        self.startable = startable
        self.operation = operation
        self.workers = workers
    }
}

package struct MacReplacementPlan: Codable, Hashable, Sendable {
    /// `quick`, `full` or `none`.
    package let path: String
    package let reason: String
    package let revision: String
    package let startable: Bool

    package init(path: String, reason: String, revision: String, startable: Bool) {
        self.path = path
        self.reason = reason
        self.revision = revision
        self.startable = startable
    }
}

package struct MacReplacementStartAcknowledgement: Codable, Hashable, Sendable {
    package let operationId: String
    package let outcome: String
    package let path: String
    package let reason: String
}
