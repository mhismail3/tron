struct PresentationOwnedStore<Owner: Hashable, Value> {
    private var values: [Owner: Value] = [:]

    subscript(owner: Owner) -> Value? {
        get { values[owner] }
        set { values[owner] = newValue }
    }

    mutating func removeValue(for owner: Owner) {
        values[owner] = nil
    }
}
