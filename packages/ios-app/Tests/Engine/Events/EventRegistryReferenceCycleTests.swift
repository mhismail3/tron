import Testing
import Foundation
@testable import TronMobile

/// L13: guard test for the "no strong-reference-cycle" invariant on
/// `EventRegistry`. The shared production registry is process-lifetime, and its
/// plugin map must NEVER hold a reference-typed value that could
/// transitively own a ViewModel. If it did, the ViewModel would outlive
/// its SwiftUI scope and its state would never be reclaimed on session
/// switch.
///
/// The shape that guarantees this:
///   - plugin boxes are `struct`s, not classes
///   - plugin types themselves are stateless (enums or static-only)
///   - the dispatch context is passed per-call, not stored
///
/// These tests lock that shape in. Adding a reference-typed field to
/// a plugin box or storing a context reference in the registry breaks
/// these tests, which is exactly the wake-up moment we want.
@Suite("EventRegistry reference-cycle invariant")
struct EventRegistryReferenceCycleTests {

    // MARK: - Box shape

    @Test("EventPluginBoxImpl is a value type (struct)")
    func eventPluginBoxImplIsValueType() {
        // A reference type (class) would survive assignment into the
        // registry's `[String: any EventPluginBox]` and could hold a
        // strong reference to anything it captured at construction.
        // Keeping the box a struct means the registry stores a
        // bit-copy with no reference semantics.
        let mirror = Mirror(reflecting: EventPluginBoxImpl<TextDeltaPlugin>())
        #expect(mirror.displayStyle == .struct)
    }

    @Test("DispatchablePluginBoxImpl is a value type (struct)")
    func dispatchablePluginBoxImplIsValueType() {
        let mirror = Mirror(reflecting: DispatchablePluginBoxImpl<TextDeltaPlugin>())
        #expect(mirror.displayStyle == .struct)
    }

    @Test("EventPluginBoxImpl has no stored properties that could retain a reference")
    func eventPluginBoxImplHasNoStoredProperties() {
        // The box carries only static metadata about its plugin type
        // via generic parameter P. If a future change adds a stored
        // property (especially an `AnyObject` / class / closure with a
        // captured reference), this count goes up and the test fails
        // so the author can reason about the consequences.
        let mirror = Mirror(reflecting: EventPluginBoxImpl<TextDeltaPlugin>())
        #expect(mirror.children.count == 0,
                "EventPluginBoxImpl must carry no stored properties — otherwise the shared production registry could retain a reference")
    }

    @Test("DispatchablePluginBoxImpl has no stored properties either")
    func dispatchablePluginBoxImplHasNoStoredProperties() {
        let mirror = Mirror(reflecting: DispatchablePluginBoxImpl<TextDeltaPlugin>())
        #expect(mirror.children.count == 0)
    }

    @Test("EventRegistry does not retain its per-call dispatch context")
    @MainActor
    func registryDoesNotRetainDispatchContext() {
        let registry = EventRegistry()
        registry.register(TextDeltaPlugin.self)
        let result = TextDeltaPlugin.Result(delta: "lifetime probe", messageIndex: nil)

        var context: MockEventDispatchContext? = MockEventDispatchContext()
        weak let weakContext = context
        registry.dispatch(
            type: TextDeltaPlugin.eventType,
            transform: { result },
            context: context!
        )

        #expect(context?.handleTextDeltaCalledWith == "lifetime probe")
        context = nil
        #expect(weakContext == nil)
    }

}
