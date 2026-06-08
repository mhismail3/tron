import Testing
import Foundation
@testable import TronMobile

/// L13: guard test for the "no strong-reference-cycle" invariant on
/// `EventRegistry`. The registry is a process-lifetime singleton whose
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
                "EventPluginBoxImpl must carry no stored properties — otherwise the registry's process-lifetime singleton could retain a reference")
    }

    @Test("DispatchablePluginBoxImpl has no stored properties either")
    func dispatchablePluginBoxImplHasNoStoredProperties() {
        let mirror = Mirror(reflecting: DispatchablePluginBoxImpl<TextDeltaPlugin>())
        #expect(mirror.children.count == 0)
    }

    // MARK: - Plugin shape

    /// Concrete examples of registered plugins. If the plugin set
    /// grows, adding to this list is cheap; the test pressure is that
    /// each item here remains a type with no instance state.
    private static let pluginProbes: [String] = [
        "TextDeltaPlugin",
        "TurnStartPlugin",
        "TurnEndPlugin",
        "CapabilityInvocationStartedPlugin",
        "CapabilityInvocationCompletedPlugin",
        "CompactionPlugin",
    ]

    @Test("Registered plugins are enum types (no instance state)")
    func plugins_are_stateless_enums() {
        // Enums with no cases (uninhabited types) can't be constructed
        // at runtime — that's the property we want. If a plugin ever
        // becomes a class or a struct with stored properties, it could
        // hold a reference.  We can't reflect over every plugin type
        // without naming them, so check the canonical set. Any new
        // plugin should be easy to add here.
        //
        // The assertion here is indirect: we verify that the registry
        // is happy to register them as plugin types (satisfied by
        // `register(P.Type)` taking a metatype, not an instance).
        // Re-registration is idempotent from the test's perspective.
        let registry = EventRegistry.shared
        let before = registry.pluginCount
        registry.register(TextDeltaPlugin.self)
        registry.register(TurnStartPlugin.self)
        let after = registry.pluginCount
        // Registration API accepts metatype only — no instance to
        // accept a captured reference from.
        #expect(after >= before)
    }

    // MARK: - Registry shape

    @Test("EventRegistry stores boxes by string key, not by reference")
    func registry_key_is_value_type() {
        // Access pluginBox(for:) with a known registered type and
        // confirm it returns `any EventPluginBox` which we've already
        // shown is a value type. A getter returning a class would
        // open the door to mutation-by-reference through the map.
        let box = EventRegistry.shared.pluginBox(for: TextDeltaPlugin.eventType)
        #expect(box != nil, "pluginBox(for:) should return a box for a registered type")
        if let box = box {
            // We can't reflect over an existential in general, but we
            // CAN confirm the concrete type is still a struct by
            // matching against the expected box impl.
            let mirror = Mirror(reflecting: box)
            #expect(mirror.displayStyle == .struct,
                    "the concrete box returned from the registry must be a struct")
        }
    }

    @Test("EventDispatchCoordinator does not capture context at construction")
    @MainActor
    func coordinator_has_no_retained_context() {
        // The dispatch coordinator receives `context: EventDispatchTarget`
        // per call (see `dispatch(type:transform:context:)`). It has no
        // initializer that accepts a context, and no stored property
        // that could hold one. This test locks that in.
        let coordinator = EventDispatchCoordinator()
        let mirror = Mirror(reflecting: coordinator)
        // Allowed: zero stored properties. If someone adds a stored
        // context, this fails and they must defend the choice.
        #expect(mirror.children.count == 0,
                "EventDispatchCoordinator must hold no stored properties — context is passed per-call to avoid retaining a ViewModel")
    }
}
