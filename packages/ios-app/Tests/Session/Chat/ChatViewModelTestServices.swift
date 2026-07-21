import Foundation
@testable import TronMobile

@MainActor
extension ChatViewModel {
    convenience init(
        engineClient: EngineClient,
        sessionId: String,
        eventStoreManager: EventStoreManager? = nil,
        photoPickerDataLoader: PhotoPickerDataLoader = .live
    ) {
        self.init(
            services: ChatSessionServices(
                connection: DefaultAppConnectionRepository(client: engineClient),
                events: DefaultSessionEventRepository(client: engineClient),
                sessions: DefaultSessionRepository(sessionClient: engineClient.session),
                agent: engineClient.agent,
                models: DefaultModelRepository(modelClient: engineClient.model),
                messages: DefaultMessageRepository(messageClient: engineClient.message),
                workerKernel: DefaultWorkerKernelRepository(client: engineClient.workerKernel)
            ),
            sessionId: sessionId,
            eventStoreManager: eventStoreManager,
            photoPickerDataLoader: photoPickerDataLoader
        )
    }
}
