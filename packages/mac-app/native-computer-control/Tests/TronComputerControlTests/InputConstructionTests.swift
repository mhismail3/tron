import CoreGraphics
import XCTest
@testable import TronComputerControl

final class InputConstructionTests: XCTestCase {
    private let bounds = LogicalScreenBounds(origin: .init(x: -100, y: 20), width: 200, height: 100)
    private let point = LogicalScreenPoint(x: 40, y: 50)

    func testPhysicalChordHasLiteralNativeCodesTypesFlagsAndPairedReleases() throws {
        let plan = try InputConstructor.construct(.init(actions: [.key(.init(.a, modifiers: [.shift, .command]))]))
        let events = plan.events.compactMap(\.nativeEvent)
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [56, 55, 0, 0, 55, 56])
        XCTAssertEqual(events.map(\.flags), [.maskShift, [.maskShift, .maskCommand], [.maskShift, .maskCommand],
                                            [.maskShift, .maskCommand], .maskShift, []])
        XCTAssertEqual(plan.events.compactMap { $0.release?.pairedInputOrdinal }, [2, 1, 0])
        try assertBalanced(plan)
    }

    func testClosedPhysicalKeyPolicyDoesNotInventAliasesOrToggleCapsLock() throws {
        XCTAssertNil(PhysicalKey(rawValue: "A"))
        XCTAssertNil(PhysicalKey(rawValue: "😀"))
        XCTAssertNil(PhysicalKey(rawValue: "İ"))
        XCTAssertNil(PhysicalKey(rawValue: "virtualA"))
        XCTAssertNil(Modifier(rawValue: "capsLock"))
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.key(.init(.a, modifiers: [.shift, .shift]))])))
        let plan = try InputConstructor.construct(.init(actions: [.key(.init(.c, modifiers: [.control, .option]))]))
        XCTAssertEqual(plan.events.compactMap(\.nativeEvent).map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [59, 58, 8, 8, 58, 59])
        try assertBalanced(plan)
    }

    func testUnicodeHasOneCommitmentDownAndOneEmptyReleasePerChunk() throws {
        let plan = try InputConstructor.construct(.init(actions: [.text("A😀B")]),
            limits: .init(maxUTF8Bytes: 100, maxUTF16Units: 100, maxUTF16UnitsPerEvent: 3, maxEventCount: 30))
        let events = plan.events.compactMap(\.nativeEvent)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp])
        XCTAssertEqual(plan.events.map(\.role), [.unicodeCommitment, .keyUp, .unicodeCommitment, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [0, 0, 0, 0])
        XCTAssertEqual(events.map { unicodeUnits($0) }, [[0x41, 0xD83D, 0xDE00], [], [0x42], []])
        XCTAssertEqual(events.map(\.flags), [[], [], [], []])
        XCTAssertEqual(plan.events.compactMap { $0.release?.pairedInputOrdinal }, [0, 2])
        try assertBalanced(plan)
    }

    func testPhysicalAAndUnicodeShareTheActualKeycodeZeroResourceWithoutOverlap() throws {
        let plan = try InputConstructor.construct(.init(actions: [.key(.init(.a)), .text("é")]))
        XCTAssertEqual(plan.events.compactMap(\.resourceIdentity), [.keyboard(0), .keyboard(0)])
        XCTAssertEqual(plan.events.compactMap { $0.release?.identity }, [.keyboard(0), .keyboard(0)])
        try assertBalanced(plan)
    }

    func testUnicodeBoundariesRejectGiantGraphemesAndKeepSurrogatePairsIntact() throws {
        let oversized = "a" + String(repeating: "\u{301}", count: 20)
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.text(oversized)])))
        let text = String(repeating: "x", count: 19) + "😀"
        let plan = try InputConstructor.construct(.init(actions: [.text(text)]))
        let commits = plan.events.filter { $0.role == .unicodeCommitment }.compactMap(\.nativeEvent)
        XCTAssertEqual(commits.map { unicodeUnits($0).count }, [19, 2])
        XCTAssertEqual(unicodeUnits(commits[1]), [0xD83D, 0xDE00])
        try assertBalanced(plan)
    }

    func testByteUnitAndExpandedEventLimitsAreIndependent() {
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.text("éé")]), limits: .init(maxUTF8Bytes: 3)))
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.text("😀")]), limits: .init(maxUTF16Units: 1)))
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.text("ab")]),
            limits: .init(maxUTF16UnitsPerEvent: 1, maxEventCount: 3)))
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.key(.init(.a))]), limits: .init(maxEventCount: 1)))
        XCTAssertNoThrow(try InputConstructor.construct(.init(actions: [.key(.init(.a))]), limits: .init(maxEventCount: 2)))
    }

    func testCallerCannotWidenAnyHardLimit() {
        let widening: [InputConstructionLimits] = [
            .init(maxUTF8Bytes: .max), .init(maxUTF16Units: .max), .init(maxUTF16UnitsPerEvent: .max),
            .init(maxEventCount: .max), .init(maxDragPathPoints: .max), .init(maxDelayMilliseconds: .max),
            .init(maxClickHoldMilliseconds: .max), .init(maxClickIntervalMilliseconds: .max),
            .init(maxDragDurationMilliseconds: .max), .init(maxScrollMagnitude: .max),
            .init(maxScrollMagnitude: -1), .init(maxUTF16UnitsPerEvent: 0),
        ]
        for limits in widening {
            XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.key(.init(.a))]), limits: limits))
        }
    }

    func testWholePlanCountAndDurationAreBounded() {
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [])))
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: Array(repeating: .delay(milliseconds: 0), count: 65))))
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.delay(milliseconds: 20_000), .delay(milliseconds: 20_000)])))
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.delay(milliseconds: 30_001)])))
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.text("")])))
    }

    func testPointerBoundsAreFiniteAndHalfOpenIncludingNegativeOrigins() throws {
        for point in [LogicalScreenPoint(x: .nan, y: 50), .init(x: .infinity, y: 50),
                      .init(x: 100, y: 50), .init(x: 40, y: 120), .init(x: -101, y: 50)] {
            XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.mouse(.move(point))], targetBounds: bounds)))
        }
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.mouse(.move(point))])))
        let plan = try InputConstructor.construct(.init(actions: [.mouse(.move(.init(x: -100, y: 20)))], targetBounds: bounds))
        let event = try XCTUnwrap(plan.events.first?.nativeEvent)
        XCTAssertEqual(event.location, CGPoint(x: -100, y: 20))
        XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 0)
        XCTAssertEqual(event.flags, [])
        try assertBalanced(plan)
    }

    func testInvalidBoundsAndButtonsRefuse() {
        let badBounds: [LogicalScreenBounds] = [
            .init(origin: .init(x: 0, y: 0), width: .nan, height: 10),
            .init(origin: .init(x: 0, y: 0), width: 0, height: 10),
            .init(origin: .init(x: .greatestFiniteMagnitude, y: 0), width: .greatestFiniteMagnitude, height: 10),
        ]
        for bounds in badBounds {
            XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.key(.init(.a))], targetBounds: bounds)))
        }
        let button = CGMouseButton(rawValue: 31)!
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.mouse(.click(.init(point: point, button: button)))], targetBounds: bounds)))
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.mouse(.drag(.init(path: [point, point], button: button, durationMilliseconds: 1)))], targetBounds: bounds)))
    }

    func testNativeRightDoubleClickFieldsTimingAndEveryReleaseOrdinal() throws {
        let plan = try InputConstructor.construct(.init(actions: [.mouse(.click(.init(point: point, button: .right, clickCount: 2)))], targetBounds: bounds))
        let native = plan.events.compactMap(\.nativeEvent)
        XCTAssertEqual(native.map(\.type), [.rightMouseDown, .rightMouseUp, .rightMouseDown, .rightMouseUp])
        XCTAssertEqual(native.map { $0.getIntegerValueField(.mouseEventButtonNumber) }, [1, 1, 1, 1])
        XCTAssertEqual(native.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1, 2, 2])
        XCTAssertEqual(native.map(\.location), Array(repeating: CGPoint(x: 40, y: 50), count: 4))
        XCTAssertEqual(native.map(\.flags), [[], [], [], []])
        XCTAssertEqual(plan.events.compactMap(\.delayMilliseconds), [28, 80, 28])
        XCTAssertEqual(plan.events.compactMap { $0.release?.pairedInputOrdinal }, [0, 4])
        try assertBalanced(plan)
    }

    func testClickAndDragTimingAndPathLimitsReject() {
        for click in [MouseClick(point: point, clickCount: 0), .init(point: point, clickCount: 4),
                      .init(point: point, holdMilliseconds: 2001), .init(point: point, interClickDelayMilliseconds: 2001)] {
            XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.mouse(.click(click))], targetBounds: bounds)))
        }
        for drag in [MouseDrag(path: [point], durationMilliseconds: 1),
                     .init(path: [point, point], durationMilliseconds: 30_001),
                     .init(path: Array(repeating: point, count: 129), durationMilliseconds: 1)] {
            XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.mouse(.drag(drag))], targetBounds: bounds)))
        }
    }

    func testDragNativeFieldsPathDurationAndExactOpeningOrdinal() throws {
        let drag = MouseDrag(path: [.init(x: 1, y: 22), .init(x: 10, y: 30), .init(x: 90, y: 90)],
                             button: .center, durationMilliseconds: 11)
        let plan = try InputConstructor.construct(.init(actions: [.mouse(.drag(drag))], targetBounds: bounds))
        let native = plan.events.compactMap(\.nativeEvent)
        XCTAssertEqual(native.map(\.type), [.otherMouseDown, .otherMouseDragged, .otherMouseDragged, .otherMouseUp])
        XCTAssertEqual(native.map { $0.getIntegerValueField(.mouseEventButtonNumber) }, [2, 2, 2, 2])
        XCTAssertEqual(native.map(\.location), [CGPoint(x: 1, y: 22), CGPoint(x: 10, y: 30), CGPoint(x: 90, y: 90), CGPoint(x: 90, y: 90)])
        XCTAssertEqual(plan.events.compactMap(\.delayMilliseconds), [6, 5])
        XCTAssertEqual(plan.events.last?.release?.pairedInputOrdinal, 0)
        try assertBalanced(plan)
    }

    func testScrollNativeUnitFieldsAndMagnitude() throws {
        let line = try InputConstructor.construct(.init(actions: [.mouse(.scroll(.init(point: point, vertical: -3, horizontal: 4)))], targetBounds: bounds))
        let event = try XCTUnwrap(line.events.first?.nativeEvent)
        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 4)
        XCTAssertEqual(event.location, CGPoint(x: 40, y: 50))
        XCTAssertEqual(event.flags, [])
        let pixel = try InputConstructor.construct(.init(actions: [.mouse(.scroll(.init(point: point, vertical: -30, horizontal: 40, unit: .pixel)))], targetBounds: bounds))
        let pixelEvent = try XCTUnwrap(pixel.events.first?.nativeEvent)
        XCTAssertEqual(pixelEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -30)
        XCTAssertEqual(pixelEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 40)
        XCTAssertThrowsError(try InputConstructor.construct(.init(actions: [.mouse(.scroll(.init(point: point, vertical: .min, horizontal: .max)))], targetBounds: bounds)))
        try assertBalanced(line)
        try assertBalanced(pixel)
    }

    private func unicodeUnits(_ event: CGEvent) -> [UInt16] {
        var count = 0
        var buffer = [UInt16](repeating: 0, count: 128)
        buffer.withUnsafeMutableBufferPointer { storage in
            event.keyboardGetUnicodeString(maxStringLength: storage.count, actualStringLength: &count,
                                           unicodeString: storage.baseAddress)
        }
        return Array(buffer.prefix(count))
    }

    private func assertBalanced(_ plan: ConstructedInputPlan, file: StaticString = #filePath, line: UInt = #line) throws {
        var outstanding: [HeldInputIdentity: Int] = [:]
        for (index, event) in plan.events.enumerated() {
            XCTAssertEqual(event.ordinal, index, file: file, line: line)
            if let resource = event.resourceIdentity {
                XCTAssertEqual(event.kind, .newInput, file: file, line: line)
                XCTAssertNil(outstanding[resource], "duplicate acquisition", file: file, line: line)
                outstanding[resource] = event.ordinal
                let native = try XCTUnwrap(event.nativeEvent, file: file, line: line)
                switch resource {
                case let .keyboard(code):
                    XCTAssertEqual(native.getIntegerValueField(.keyboardEventKeycode), Int64(code), file: file, line: line)
                case let .mouseButton(button):
                    XCTAssertEqual(native.getIntegerValueField(.mouseEventButtonNumber), Int64(button.rawValue), file: file, line: line)
                }
            }
            if let release = event.release {
                XCTAssertEqual(event.kind, .matchedRelease, file: file, line: line)
                XCTAssertNil(event.resourceIdentity, file: file, line: line)
                XCTAssertEqual(outstanding.removeValue(forKey: release.identity), release.pairedInputOrdinal,
                               "release must consume exactly its own acquisition", file: file, line: line)
            }
            if event.kind == .delay {
                XCTAssertNil(event.nativeEvent, file: file, line: line)
                XCTAssertNotNil(event.delayMilliseconds, file: file, line: line)
            }
        }
        XCTAssertTrue(outstanding.isEmpty, "unpaired native resources", file: file, line: line)
    }
}
