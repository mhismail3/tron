import Foundation
@testable import TronMobile

@MainActor
extension ChatViewModel {
    convenience init(
        engineClient: EngineClient,
        sessionId: String,
        eventStoreManager: EventStoreManager? = nil
    ) {
        self.init(
            services: ChatSessionServices(
                connection: DefaultAppConnectionRepository(client: engineClient),
                events: DefaultSessionEventRepository(client: engineClient),
                sessions: DefaultSessionRepository(sessionClient: engineClient.session),
                agent: DefaultAgentRepository(agentClient: engineClient.agent),
                models: DefaultModelRepository(modelClient: engineClient.model),
                messages: DefaultMessageRepository(messageClient: engineClient.message)
            ),
            sessionId: sessionId,
            eventStoreManager: eventStoreManager
        )
    }
}
