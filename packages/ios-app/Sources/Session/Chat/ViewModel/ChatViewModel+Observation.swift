extension ChatViewModel {
    /// Reusable observation loop: watches a value via `withObservationTracking`
    /// and invokes `onChange` each time it changes. Cancelled via the returned task.
    static func observeLoop<T: Equatable>(
        _ read: @escaping @MainActor () -> T,
        onChange: @escaping @MainActor (T) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            var lastValue = read()
            while !Task.isCancelled {
                await waitForObservationChange(read)
                guard !Task.isCancelled else { return }
                let nextValue = read()
                guard nextValue != lastValue else { continue }
                lastValue = nextValue
                onChange(nextValue)
            }
        }
    }

}
