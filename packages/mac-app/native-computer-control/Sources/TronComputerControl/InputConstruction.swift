import CoreGraphics
import Foundation

/// Physical keyboard identities are deliberately closed: a caller cannot turn
/// an arbitrary string or virtual-key guess into an input event.
public enum PhysicalKey: String, CaseIterable, Hashable, Sendable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero, one, two, three, four, five, six, seven, eight, nine
    case `return`, tab, space, delete, escape
    case leftArrow, rightArrow, downArrow, upArrow
    case minus, equal, leftBracket, rightBracket, backslash, semicolon, quote, comma, period, slash, grave
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    public var keyCode: CGKeyCode {
        switch self {
        case .a: return 0
        case .s: return 1
        case .d: return 2
        case .f: return 3
        case .h: return 4
        case .g: return 5
        case .z: return 6
        case .x: return 7
        case .c: return 8
        case .v: return 9
        case .b: return 11
        case .q: return 12
        case .w: return 13
        case .e: return 14
        case .r: return 15
        case .y: return 16
        case .t: return 17
        case .one: return 18
        case .two: return 19
        case .three: return 20
        case .four: return 21
        case .six: return 22
        case .five: return 23
        case .equal: return 24
        case .nine: return 25
        case .seven: return 26
        case .minus: return 27
        case .eight: return 28
        case .zero: return 29
        case .rightBracket: return 30
        case .o: return 31
        case .u: return 32
        case .leftBracket: return 33
        case .i: return 34
        case .p: return 35
        case .return: return 36
        case .l: return 37
        case .j: return 38
        case .quote: return 39
        case .k: return 40
        case .semicolon: return 41
        case .backslash: return 42
        case .comma: return 43
        case .slash: return 44
        case .n: return 45
        case .m: return 46
        case .period: return 47
        case .tab: return 48
        case .space: return 49
        case .grave: return 50
        case .delete: return 51
        case .escape: return 53
        case .rightArrow: return 124
        case .leftArrow: return 123
        case .downArrow: return 125
        case .upArrow: return 126
        case .f1: return 122
        case .f2: return 120
        case .f3: return 99
        case .f4: return 118
        case .f5: return 96
        case .f6: return 97
        case .f7: return 98
        case .f8: return 100
        case .f9: return 101
        case .f10: return 109
        case .f11: return 103
        case .f12: return 111
        }
    }
}

public enum Modifier: String, CaseIterable, Hashable, Sendable {
    // Caps Lock is a persistent latch, not an operation-owned held modifier.
    case shift, control, option, command, function

    var keyCode: CGKeyCode {
        switch self {
        case .shift: 56
        case .control: 59
        case .option: 58
        case .command: 55
        case .function: 63
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .shift: .maskShift
        case .control: .maskControl
        case .option: .maskAlternate
        case .command: .maskCommand
        case .function: .maskSecondaryFn
        }
    }
}

public struct LogicalScreenPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct LogicalScreenBounds: Equatable, Sendable {
    public let origin: LogicalScreenPoint
    public let width: Double
    public let height: Double

    public init(origin: LogicalScreenPoint, width: Double, height: Double) {
        self.origin = origin; self.width = width; self.height = height
    }
}

public struct KeyAction: Equatable, Sendable {
    public let key: PhysicalKey
    /// Order is retained so duplicate modifier identities can be rejected.
    public let modifiers: [Modifier]

    public init(_ key: PhysicalKey, modifiers: [Modifier] = []) {
        self.key = key; self.modifiers = modifiers
    }
}

public struct MouseClick: Equatable, Sendable {
    public let point: LogicalScreenPoint
    public let button: CGMouseButton
    public let clickCount: UInt8
    public let holdMilliseconds: UInt32
    public let interClickDelayMilliseconds: UInt32

    public init(point: LogicalScreenPoint, button: CGMouseButton = .left, clickCount: UInt8 = 1,
                holdMilliseconds: UInt32 = 28, interClickDelayMilliseconds: UInt32 = 80) {
        self.point = point; self.button = button; self.clickCount = clickCount
        self.holdMilliseconds = holdMilliseconds
        self.interClickDelayMilliseconds = interClickDelayMilliseconds
    }
}

public struct MouseDrag: Equatable, Sendable {
    public let path: [LogicalScreenPoint]
    public let button: CGMouseButton
    public let durationMilliseconds: UInt32

    public init(path: [LogicalScreenPoint], button: CGMouseButton = .left,
                durationMilliseconds: UInt32) {
        self.path = path; self.button = button; self.durationMilliseconds = durationMilliseconds
    }
}

public struct MouseScroll: Equatable, Sendable {
    public let point: LogicalScreenPoint
    public let vertical: Int32
    public let horizontal: Int32
    public let unit: CGScrollEventUnit

    public init(point: LogicalScreenPoint, vertical: Int32, horizontal: Int32 = 0,
                unit: CGScrollEventUnit = .line) {
        self.point = point; self.vertical = vertical; self.horizontal = horizontal; self.unit = unit
    }
}

public enum MouseAction: Equatable, Sendable {
    case move(LogicalScreenPoint)
    case click(MouseClick)
    case drag(MouseDrag)
    case scroll(MouseScroll)
}

public enum InputAction: Equatable, Sendable {
    case key(KeyAction)
    case text(String)
    case mouse(MouseAction)
    case delay(milliseconds: UInt32)
}

public struct InputPlan: Equatable, Sendable {
    public let actions: [InputAction]
    /// The caller owns this logical-screen contract; this package never resolves it.
    public let targetBounds: LogicalScreenBounds?

    public init(actions: [InputAction], targetBounds: LogicalScreenBounds? = nil) {
        self.actions = actions; self.targetBounds = targetBounds
    }
}

public struct InputConstructionLimits: Equatable, Sendable {
    public let maxUTF8Bytes: Int
    public let maxUTF16Units: Int
    public let maxUTF16UnitsPerEvent: Int
    public let maxEventCount: Int
    public let maxDragPathPoints: Int
    public let maxDelayMilliseconds: UInt32
    public let maxClickHoldMilliseconds: UInt32
    public let maxClickIntervalMilliseconds: UInt32
    public let maxDragDurationMilliseconds: UInt32
    public let maxScrollMagnitude: Int64

    public init(maxUTF8Bytes: Int = 64 * 1024, maxUTF16Units: Int = 32 * 1024,
                maxUTF16UnitsPerEvent: Int = 20, maxEventCount: Int = 512,
                maxDragPathPoints: Int = 128, maxDelayMilliseconds: UInt32 = 30_000,
                maxClickHoldMilliseconds: UInt32 = 2_000,
                maxClickIntervalMilliseconds: UInt32 = 2_000,
                maxDragDurationMilliseconds: UInt32 = 30_000,
                maxScrollMagnitude: Int64 = 100_000) {
        self.maxUTF8Bytes = maxUTF8Bytes; self.maxUTF16Units = maxUTF16Units
        self.maxUTF16UnitsPerEvent = maxUTF16UnitsPerEvent; self.maxEventCount = maxEventCount
        self.maxDragPathPoints = maxDragPathPoints; self.maxDelayMilliseconds = maxDelayMilliseconds
        self.maxClickHoldMilliseconds = maxClickHoldMilliseconds
        self.maxClickIntervalMilliseconds = maxClickIntervalMilliseconds
        self.maxDragDurationMilliseconds = maxDragDurationMilliseconds
        self.maxScrollMagnitude = maxScrollMagnitude
    }
}

public enum InputConstructionError: Error, Equatable, CustomStringConvertible {
    case emptyPlan
    case invalidGeometry(String)
    case invalidAction(String)
    case duplicateModifier(Modifier)
    case textLimit(String)
    case eventLimit
    case eventConstructionFailed(String)

    public var description: String {
        switch self {
        case .emptyPlan: "input plan is empty"
        case let .invalidGeometry(value): "invalid geometry: \(value)"
        case let .invalidAction(value): "invalid action: \(value)"
        case let .duplicateModifier(value): "duplicate modifier: \(value.rawValue)"
        case let .textLimit(value): "text limit: \(value)"
        case .eventLimit: "expanded event limit exceeded"
        case let .eventConstructionFailed(value): "CGEvent construction failed: \(value)"
        }
    }
}

public enum InputEventKind: String, Equatable, Sendable { case newInput, matchedRelease, delay }
public enum InputEventRole: String, Equatable, Sendable {
    case keyDown, keyUp, modifierDown, modifierUp, unicodeCommitment
    case mouseMove, mouseDown, mouseUp, mouseDragged, scroll
}

public enum HeldInputIdentity: Hashable, Sendable {
    /// Identity follows the actual native resource, including keycode zero for text.
    /// Semantic aliases must not create two owners of the same physical resource.
    case keyboard(CGKeyCode)
    case mouseButton(CGMouseButton)
}

public struct MatchedRelease: Equatable, Sendable {
    public let identity: HeldInputIdentity
    public let pairedInputOrdinal: Int
}

/// A constructed event is inert. Nothing in this package posts it or resolves a target.
public struct ConstructedInputEvent {
    public let ordinal: Int
    public let kind: InputEventKind
    public let role: InputEventRole?
    public let nativeEvent: CGEvent?
    public let resourceIdentity: HeldInputIdentity?
    public let release: MatchedRelease?
    public let delayMilliseconds: UInt32?
}

public struct ConstructedInputPlan {
    public let events: [ConstructedInputEvent]
    public let limits: InputConstructionLimits
}

public enum InputConstructor {
    public static func construct(_ plan: InputPlan,
                                 limits: InputConstructionLimits = .init()) throws -> ConstructedInputPlan {
        let validated = try validate(plan, limits: limits)
        var events: [ConstructedInputEvent] = []
        events.reserveCapacity(validated.count)
        var ordinal = 0
        var flags: CGEventFlags = []

        func appendInput(_ event: CGEvent, role: InputEventRole, resource: HeldInputIdentity? = nil,
                         release: MatchedRelease? = nil) {
            events.append(ConstructedInputEvent(ordinal: ordinal, kind: release == nil ? .newInput : .matchedRelease,
                                                role: role, nativeEvent: event, resourceIdentity: resource,
                                                release: release, delayMilliseconds: nil))
            ordinal += 1
        }
        func appendDelay(_ milliseconds: UInt32) {
            events.append(ConstructedInputEvent(ordinal: ordinal, kind: .delay, role: nil,
                                                nativeEvent: nil, resourceIdentity: nil, release: nil,
                                                delayMilliseconds: milliseconds))
            ordinal += 1
        }
        func keyboard(_ code: CGKeyCode, down: Bool, role: InputEventRole,
                      resource: HeldInputIdentity? = nil, release: MatchedRelease? = nil,
                      eventFlags: CGEventFlags = flags, unicode: [UInt16]? = nil) throws {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
                throw InputConstructionError.eventConstructionFailed(role.rawValue)
            }
            event.flags = eventFlags
            if role == .modifierDown || role == .modifierUp { event.type = .flagsChanged }
            if let unicode {
                unicode.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
            }
            appendInput(event, role: role, resource: resource, release: release)
        }
        func mouse(_ type: CGEventType, point: LogicalScreenPoint, button: CGMouseButton,
                   clickState: Int64 = 1, role: InputEventRole,
                   resource: HeldInputIdentity? = nil, release: MatchedRelease? = nil) throws {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: CGPoint(x: point.x, y: point.y), mouseButton: button) else {
                throw InputConstructionError.eventConstructionFailed(role.rawValue)
            }
            event.flags = flags
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
            appendInput(event, role: role, resource: resource, release: release)
        }

        for action in validated.actions {
            switch action {
            case let .key(key, modifiers):
                var downOrdinals: [(Modifier, Int)] = []
                for modifier in modifiers {
                    flags.insert(modifier.flag)
                    let identity = HeldInputIdentity.keyboard(modifier.keyCode)
                    try keyboard(modifier.keyCode, down: true, role: .modifierDown,
                                 resource: identity, eventFlags: flags)
                    downOrdinals.append((modifier, events[events.count - 1].ordinal))
                }
                let keyIdentity = HeldInputIdentity.keyboard(key.keyCode)
                try keyboard(key.keyCode, down: true, role: .keyDown, resource: keyIdentity, eventFlags: flags)
                let keyDownOrdinal = events[events.count - 1].ordinal
                try keyboard(key.keyCode, down: false, role: .keyUp,
                             release: MatchedRelease(identity: keyIdentity, pairedInputOrdinal: keyDownOrdinal),
                             eventFlags: flags)
                for (modifier, downOrdinal) in downOrdinals.reversed() {
                    let identity = HeldInputIdentity.keyboard(modifier.keyCode)
                    flags.remove(modifier.flag)
                    try keyboard(modifier.keyCode, down: false, role: .modifierUp,
                                 release: MatchedRelease(identity: identity, pairedInputOrdinal: downOrdinal),
                                 eventFlags: flags)
                }
            case let .text(chunks):
                for chunk in chunks {
                    let identity = HeldInputIdentity.keyboard(0)
                    // The commitment itself acquires keycode zero. An additional bare
                    // down would insert unintended input and duplicate resource ownership.
                    try keyboard(0, down: true, role: .unicodeCommitment,
                                 resource: identity, eventFlags: [], unicode: Array(chunk.utf16))
                    let downOrdinal = events[events.count - 1].ordinal
                    try keyboard(0, down: false, role: .keyUp,
                                 release: MatchedRelease(identity: identity, pairedInputOrdinal: downOrdinal),
                                 eventFlags: [], unicode: [])
                }
            case let .mouse(mouseAction):
                switch mouseAction {
                case let .move(point):
                    try mouse(.mouseMoved, point: point, button: .left, clickState: 0, role: .mouseMove)
                case let .click(click):
                    let identity = HeldInputIdentity.mouseButton(click.button)
                    for number in 1...Int(click.clickCount) {
                        try mouse(mouseDownType(click.button), point: click.point, button: click.button,
                                  clickState: Int64(number), role: .mouseDown, resource: identity)
                        let downOrdinal = events[events.count - 1].ordinal
                        if click.holdMilliseconds > 0 { appendDelay(click.holdMilliseconds) }
                        try mouse(mouseUpType(click.button), point: click.point, button: click.button,
                                  clickState: Int64(number), role: .mouseUp,
                                  release: MatchedRelease(identity: identity, pairedInputOrdinal: downOrdinal))
                        if number < Int(click.clickCount) && click.interClickDelayMilliseconds > 0 {
                            appendDelay(click.interClickDelayMilliseconds)
                        }
                    }
                case let .drag(drag):
                    let identity = HeldInputIdentity.mouseButton(drag.button)
                    try mouse(mouseDownType(drag.button), point: drag.path[0], button: drag.button,
                              role: .mouseDown, resource: identity)
                    let downOrdinal = events[events.count - 1].ordinal
                    let segments = drag.path.count - 1
                    let base = drag.durationMilliseconds / UInt32(segments)
                    let remainder = drag.durationMilliseconds % UInt32(segments)
                    for index in 1..<drag.path.count {
                        let wait = base + (index <= Int(remainder) ? 1 : 0)
                        appendDelay(wait)
                        try mouse(mouseDraggedType(drag.button), point: drag.path[index], button: drag.button,
                                  role: .mouseDragged)
                    }
                    try mouse(mouseUpType(drag.button), point: drag.path[drag.path.count - 1], button: drag.button,
                              role: .mouseUp,
                              release: MatchedRelease(identity: identity, pairedInputOrdinal: downOrdinal))
                case let .scroll(scroll):
                    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: scroll.unit,
                                              wheelCount: 2, wheel1: scroll.vertical, wheel2: scroll.horizontal, wheel3: 0) else {
                        throw InputConstructionError.eventConstructionFailed("scroll")
                    }
                    event.location = CGPoint(x: scroll.point.x, y: scroll.point.y)
                    event.flags = []
                    // Let Core Graphics retain coherent line, point and fixed-point
                    // fields for the selected unit; pixel deltas are not line deltas.
                    appendInput(event, role: .scroll)
                }
            case let .delay(milliseconds): appendDelay(milliseconds)
            }
        }
        guard events.count == validated.count, events.count <= limits.maxEventCount else {
            throw InputConstructionError.eventConstructionFailed("expanded record count differs from validated plan")
        }
        return ConstructedInputPlan(events: events, limits: limits)
    }

    private struct ValidatedPlan {
        enum Action { case key(PhysicalKey, [Modifier]); case text([String]); case mouse(MouseAction); case delay(UInt32) }
        let actions: [Action]
        let count: Int
    }

    private static func validate(_ plan: InputPlan, limits: InputConstructionLimits) throws -> ValidatedPlan {
        guard !plan.actions.isEmpty else { throw InputConstructionError.emptyPlan }
        let maximum = InputConstructionLimits()
        guard plan.actions.count <= 64 else { throw InputConstructionError.eventLimit }
        guard (0...maximum.maxUTF8Bytes).contains(limits.maxUTF8Bytes),
              (0...maximum.maxUTF16Units).contains(limits.maxUTF16Units),
              (1...maximum.maxUTF16UnitsPerEvent).contains(limits.maxUTF16UnitsPerEvent),
              (0...maximum.maxEventCount).contains(limits.maxEventCount),
              (2...maximum.maxDragPathPoints).contains(limits.maxDragPathPoints),
              (0...maximum.maxScrollMagnitude).contains(limits.maxScrollMagnitude),
              limits.maxDelayMilliseconds <= maximum.maxDelayMilliseconds,
              limits.maxClickHoldMilliseconds <= maximum.maxClickHoldMilliseconds,
              limits.maxClickIntervalMilliseconds <= maximum.maxClickIntervalMilliseconds,
              limits.maxDragDurationMilliseconds <= maximum.maxDragDurationMilliseconds else {
            throw InputConstructionError.invalidAction("invalid construction limits")
        }
        if let bounds = plan.targetBounds { try validate(bounds) }
        var utf8 = 0, utf16 = 0, count = 0
        var totalDelay: UInt64 = 0
        func addDelay(_ milliseconds: UInt64) throws {
            totalDelay += milliseconds
            guard totalDelay <= 30_000 else {
                throw InputConstructionError.invalidAction("total plan delay exceeds 30 seconds")
            }
        }
        func button(_ value: CGMouseButton) throws {
            guard value == .left || value == .right || value == .center else {
                throw InputConstructionError.invalidAction("unsupported mouse button")
            }
        }
        var result: [ValidatedPlan.Action] = []
        func addCount(_ amount: Int) throws {
            guard amount >= 0, amount <= limits.maxEventCount,
                  count <= limits.maxEventCount - amount else { throw InputConstructionError.eventLimit }
            count += amount
        }
        func point(_ value: LogicalScreenPoint) throws {
            guard let bounds = plan.targetBounds else { throw InputConstructionError.invalidGeometry("target bounds are required for pointer input") }
            guard value.x.isFinite, value.y.isFinite, value.x >= bounds.origin.x, value.y >= bounds.origin.y,
                  value.x < bounds.origin.x + bounds.width, value.y < bounds.origin.y + bounds.height else {
                throw InputConstructionError.invalidGeometry("point is outside logical target bounds")
            }
        }
        for action in plan.actions {
            switch action {
            case let .key(key):
                var seen = Set<Modifier>()
                for modifier in key.modifiers {
                    guard seen.insert(modifier).inserted else { throw InputConstructionError.duplicateModifier(modifier) }
                }
                try addCount(2 + 2 * key.modifiers.count)
                result.append(.key(key.key, key.modifiers))
            case let .text(text):
                let bytes = text.utf8.count
                let units = text.utf16.count
                guard bytes <= limits.maxUTF8Bytes, utf8 <= limits.maxUTF8Bytes - bytes else {
                    throw InputConstructionError.textLimit("UTF-8 bytes")
                }
                guard units <= limits.maxUTF16Units, utf16 <= limits.maxUTF16Units - units else {
                    throw InputConstructionError.textLimit("UTF-16 units")
                }
                guard !text.isEmpty else { throw InputConstructionError.invalidAction("empty text") }
                utf8 += bytes; utf16 += units
                var chunks: [String] = [], chunk = "", chunkUnits = 0
                for character in text {
                    let piece = String(character), pieceUnits = piece.utf16.count
                    guard pieceUnits <= limits.maxUTF16UnitsPerEvent else {
                        throw InputConstructionError.textLimit("one extended grapheme exceeds per-event UTF-16 limit")
                    }
                    guard chunkUnits <= limits.maxUTF16UnitsPerEvent - pieceUnits else {
                        chunks.append(chunk); chunk = piece; chunkUnits = pieceUnits
                        continue
                    }
                    chunk.append(contentsOf: piece); chunkUnits += pieceUnits
                }
                if !chunk.isEmpty { chunks.append(chunk) }
                try addCount(chunks.count * 2)
                result.append(.text(chunks))
            case let .mouse(mouseAction):
                switch mouseAction {
                case let .move(value): try point(value); try addCount(1)
                case let .click(click):
                    try point(click.point)
                    try button(click.button)
                    guard (1...3).contains(Int(click.clickCount)) else { throw InputConstructionError.invalidAction("click count") }
                    guard click.holdMilliseconds <= limits.maxClickHoldMilliseconds,
                          click.interClickDelayMilliseconds <= limits.maxClickIntervalMilliseconds else {
                        throw InputConstructionError.invalidAction("click timing")
                    }
                    let delays = (click.holdMilliseconds > 0 ? Int(click.clickCount) : 0) +
                        (click.interClickDelayMilliseconds > 0 ? Int(click.clickCount) - 1 : 0)
                    try addCount(Int(click.clickCount) * 2 + delays)
                    try addDelay(UInt64(click.holdMilliseconds) * UInt64(click.clickCount)
                        + UInt64(click.interClickDelayMilliseconds) * UInt64(click.clickCount - 1))
                case let .drag(drag):
                    try button(drag.button)
                    guard drag.path.count >= 2, drag.path.count <= limits.maxDragPathPoints else {
                        throw InputConstructionError.invalidAction("drag path")
                    }
                    guard drag.durationMilliseconds <= limits.maxDragDurationMilliseconds else {
                        throw InputConstructionError.invalidAction("drag timing")
                    }
                    for value in drag.path { try point(value) }
                    try addCount(2 + (drag.path.count - 1) * 2)
                    try addDelay(UInt64(drag.durationMilliseconds))
                case let .scroll(scroll):
                    try point(scroll.point)
                    guard scroll.unit == .line || scroll.unit == .pixel else {
                        throw InputConstructionError.invalidAction("unsupported scroll unit")
                    }
                    let magnitude = abs(Int64(scroll.vertical)) + abs(Int64(scroll.horizontal))
                    guard magnitude <= limits.maxScrollMagnitude else { throw InputConstructionError.invalidAction("scroll magnitude") }
                    try addCount(1)
                }
                result.append(.mouse(mouseAction))
            case let .delay(milliseconds):
                guard milliseconds <= limits.maxDelayMilliseconds else { throw InputConstructionError.invalidAction("delay timing") }
                try addCount(1)
                try addDelay(UInt64(milliseconds))
                result.append(.delay(milliseconds))
            }
        }
        return ValidatedPlan(actions: result, count: count)
    }

    private static func validate(_ bounds: LogicalScreenBounds) throws {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              (bounds.origin.x + bounds.width).isFinite, (bounds.origin.y + bounds.height).isFinite else {
            throw InputConstructionError.invalidGeometry("bounds")
        }
    }
}

private func mouseDownType(_ button: CGMouseButton) -> CGEventType {
    switch button {
    case .left: return .leftMouseDown
    case .right: return .rightMouseDown
    default: return .otherMouseDown
    }
}

private func mouseUpType(_ button: CGMouseButton) -> CGEventType {
    switch button {
    case .left: return .leftMouseUp
    case .right: return .rightMouseUp
    default: return .otherMouseUp
    }
}

private func mouseDraggedType(_ button: CGMouseButton) -> CGEventType {
    switch button {
    case .left: return .leftMouseDragged
    case .right: return .rightMouseDragged
    default: return .otherMouseDragged
    }
}
