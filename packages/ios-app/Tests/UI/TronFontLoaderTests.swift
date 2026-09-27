import CoreText
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import TronMobile

/// `TronFontLoader` reuses created fonts by key. The parity gates render one
/// fixed font state, so these guard the failure modes they cannot see:
/// - a font-setting change (text or code family, weight axis, Recursive casual
///   axis) returns a font built for the previous setting because the key omits
///   that input;
/// - requests differing only in mono, size (Source Serif optical size) or an
///   explicit family/casual override share one entry;
/// - a cache hit skips the `FontSettings` reads, so a view that builds its font
///   in `body` stops observing font settings and keeps the old typography.
@Suite("Tron font loader")
@MainActor
struct TronFontLoaderTests {
    private static let wght: UInt32 = 0x77676874
    private static let casl: UInt32 = 0x4341534C
    private static let mono: UInt32 = 0x4D4F4E4F
    private static let opsz: UInt32 = 0x6F70737A

    @Test("each font reflects the font settings and inputs at the moment it is created")
    func fontsFollowSettingsAndInputs() throws {
        let (settings, cleanup) = try isolatedSettings()
        defer { cleanup() }
        settings.selectedFamily = .recursive
        settings.selectedMonoFamily = .recursive

        let initial = TronFontLoader.createUIFont(size: 14, settings: settings)
        #expect(initial.familyName.contains("Recursive"))
        #expect(axis(Self.casl, of: initial) == 0.5)
        #expect(axis(Self.mono, of: initial) == 0)
        #expect(axis(Self.wght, of: initial) == 400)

        settings.setAxisValue(for: .recursive, axis: .casual, value: 1)
        #expect(axis(Self.casl, of: TronFontLoader.createUIFont(size: 14, settings: settings)) == 1)

        settings.setAxisValue(for: .recursive, axis: .weight, value: 700)
        let heavier = TronFontLoader.createUIFont(size: 14, settings: settings)
        #expect(axis(Self.wght, of: heavier) == 700)
        #expect(axis(Self.wght, of: TronFontLoader.createUIFont(size: 14, weight: .semibold, settings: settings)) == 900)

        let code = TronFontLoader.createUIFont(size: 14, mono: true, settings: settings)
        #expect(axis(Self.mono, of: code) == 1)
        #expect(axis(Self.mono, of: TronFontLoader.createUIFont(size: 14, settings: settings)) == 0)

        let overriddenCasual = TronFontLoader.createUIFont(size: 14, casual: 0.25, settings: settings)
        #expect(axis(Self.casl, of: overriddenCasual) == 0.25)

        let explicitFamily = TronFontLoader.createUIFont(size: 14, family: .lora, settings: settings)
        #expect(explicitFamily.familyName.contains("Lora"))

        settings.selectedFamily = .sourceSerif4
        let serifSmall = TronFontLoader.createUIFont(size: 14, settings: settings)
        let serifLarge = TronFontLoader.createUIFont(size: 30, settings: settings)
        #expect(serifSmall.familyName.contains("Source Serif"))
        #expect(axis(Self.opsz, of: serifSmall) == 14)
        #expect(axis(Self.opsz, of: serifLarge) == 30)
        #expect(serifLarge.pointSize == 30)

        settings.selectedMonoFamily = .jetBrainsMono
        #expect(TronFontLoader.createUIFont(size: 14, mono: true, settings: settings).familyName.contains("JetBrains"))

        settings.selectedFamily = .ibmPlexSerif
        #expect(TronFontLoader.createUIFont(size: 14, weight: .bold, settings: settings).fontName == "IBMPlexSerif-Bold")
        let swiftUIFont = TronFontLoader.createFont(size: 14, weight: .bold, settings: settings)
        #expect(swiftUIFont == .custom("IBMPlexSerif-Bold", size: 14, relativeTo: .body))
    }

    @Test("a reused font still makes its reader observe font settings")
    func reusedFontKeepsSettingsObservation() throws {
        let (settings, cleanup) = try isolatedSettings()
        defer { cleanup() }
        settings.selectedFamily = .recursive
        _ = TronFontLoader.createFont(size: 14, settings: settings)

        let familyChanged = Mutex(false)
        withObservationTracking {
            _ = TronFontLoader.createFont(size: 14, settings: settings)
        } onChange: {
            familyChanged.withLock { $0 = true }
        }
        settings.selectedFamily = .lora
        #expect(familyChanged.withLock { $0 })

        _ = TronFontLoader.createUIFont(size: 14, settings: settings)
        let axisChanged = Mutex(false)
        withObservationTracking {
            _ = TronFontLoader.createUIFont(size: 14, settings: settings)
        } onChange: {
            axisChanged.withLock { $0 = true }
        }
        settings.setAxisValue(for: .lora, axis: .weight, value: 600)
        #expect(axisChanged.withLock { $0 })
    }

    private func isolatedSettings() throws -> (FontSettings, () -> Void) {
        let suite = "TronFontLoaderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (FontSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    /// The applied variation value, rounded past Core Text's fixed-point storage.
    private func axis(_ tag: UInt32, of font: UIFont) -> Double? {
        let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]
        return variation?[NSNumber(value: tag)].map { ($0.doubleValue * 100).rounded() / 100 }
    }
}
