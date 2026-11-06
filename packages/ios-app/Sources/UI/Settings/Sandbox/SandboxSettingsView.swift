import QuartzCore
import SwiftUI

/// Settings → Setup → Sandbox: a playground for custom components. Every
/// experiment shows fake data and performs no Gateway read or action.
struct SandboxSettingsView: View {
    @State private var showsCustomSheetStage = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            TronSettingsSections(alignment: .leading, spacing: 20, hidesLoneHeading: true) {
                TronSettingsGroup("Experiments", accent: .tronPrimary) {
                    Button { showsCustomSheetStage = true } label: {
                        TronSettingsRow(icon: "rectangle.bottomhalf.inset.filled", title: "Custom sheet · Manage Home",
                                        subtitle: "Content-sized sheet on one interruptible spring, beside the stock sheet")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sandbox-experiment-custom-sheet")
                }
                .tronSettingsCaption("Playground for custom components. Fake data only: nothing here reads or changes your Macs.")
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Sandbox")
        .fullScreenCover(isPresented: $showsCustomSheetStage) {
            SandboxCustomSheetStage()
                .tronPresentation()
        }
    }
}

/// The custom sheet experiment's stage: a fake chat backdrop, the fluid sheet,
/// the stock sheet with the same content as a baseline, and a frame meter.
struct SandboxCustomSheetStage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var demo = SandboxManageHomeDemo()
    @State private var meter = SandboxFrameMeter()
    @State private var showsCustom = false
    @State private var showsStock = false
    @State private var slowMotion = false

    var body: some View {
        ZStack {
            TronBackdrop().ignoresSafeArea()
            VStack(spacing: 14) {
                topBar
                SandboxFrameMeterView(meter: meter)
                fakeChat
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .tronFluidSheet(isPresented: $showsCustom, slowMotion: slowMotion ? 4 : 1) {
            SandboxManageHomeHeader(demo: demo)
        } content: {
            SandboxManageHomeContent(demo: demo)
        } footer: {
            SandboxPlaygroundBar(demo: demo)
        }
        .sheet(isPresented: $showsStock) {
            SandboxStockSheet(demo: demo)
        }
        .onDisappear { meter.stop() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronTextSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Close playground")
            .accessibilityIdentifier("sandbox-stage-close")
            Spacer()
            TronSheetTitle(title: "Custom sheet · Manage Home")
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    /// Something for the glass to refract and the dim to cover.
    private var fakeChat: some View {
        VStack(alignment: .leading, spacing: 10) {
            bubble("What changed in the Gateway overnight?", mine: true)
            bubble("Two workers finished: the docs sweep landed and the audit is waiting for your review. Memory is current through chapter 18.", mine: false)
            bubble("Open Manage Home.", mine: true)
        }
        .accessibilityHidden(true)
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(TronTypography.body)
            .foregroundStyle(mine ? Color.white : Color.tronTextPrimary)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(mine ? Color.tronPrimary : Color.tronSurfaceElevated))
            .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $slowMotion) {
                Text("Slow motion (4×)").font(TronTypography.buttonSM).foregroundStyle(Color.tronTextPrimary)
            }
            .tint(.tronPrimary)
            .accessibilityIdentifier("sandbox-slow-motion")
            HStack(spacing: 10) {
                Button {
                    meter.reset("Stock sheet")
                    showsStock = true
                } label: {
                    Text("Stock sheet").font(TronTypography.buttonSM).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("sandbox-present-stock")
                Button {
                    meter.reset("Custom sheet")
                    showsCustom = true
                } label: {
                    Text("Custom sheet").font(TronTypography.buttonSM).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(.tronPrimary)
                .accessibilityIdentifier("sandbox-present-custom")
            }
        }
    }
}

/// The baseline: the same content in the standard sheet Manage Home uses today.
private struct SandboxStockSheet: View {
    let demo: SandboxManageHomeDemo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SandboxManageHomeHeader(demo: demo, showsDone: false)
                .overlay(alignment: .trailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronPrimary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .padding(.trailing, 14)
                    .accessibilityLabel("Done")
                    .accessibilityIdentifier("sandbox-stock-done")
                }
            ScrollView { SandboxManageHomeContent(demo: demo) }
            SandboxPlaygroundBar(demo: demo)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

/// Counts display frames the main thread missed in a fixed window after a sheet
/// is presented. It is a main-thread proxy: render-server hitches do not reach
/// it. Its display link runs only inside the window, and its text is published
/// at most four times a second, so measuring neither drives the UI nor keeps
/// the app from idling between measurements.
@Observable @MainActor
final class SandboxFrameMeter {
    static let window: CFTimeInterval = 4
    private(set) var summary = "Present a sheet to measure the next 4 s"
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var label = ""
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var hitches = 0
    @ObservationIgnored private var missed = 0
    @ObservationIgnored private var worstMS = 0.0
    @ObservationIgnored private var hitchMS = 0.0
    @ObservationIgnored private var started: CFTimeInterval = 0
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var lastDuration: CFTimeInterval = 0
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0
    @ObservationIgnored private var maximumRate = 0

    func reset(_ label: String) {
        stop()
        self.label = label
        frames = 0; hitches = 0; missed = 0; worstMS = 0; hitchMS = 0; maximumRate = 0
        started = CACurrentMediaTime()
        lastTimestamp = 0
        let link = CADisplayLink(target: SandboxFrameMeterTarget(meter: self), selector: #selector(SandboxFrameMeterTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        publish(final: false)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let expected = link.targetTimestamp - link.timestamp
        maximumRate = max(maximumRate, Int((1 / max(expected, 0.001)).rounded()))
        if lastTimestamp > 0, lastDuration > 0 {
            frames += 1
            let interval = link.timestamp - lastTimestamp
            worstMS = max(worstMS, interval * 1000)
            // A frame more than half a frame late is a hitch; its extra time is
            // what Apple's hitch-time ratio sums.
            if interval > lastDuration * 1.5 {
                hitches += 1
                missed += Int((interval / lastDuration).rounded()) - 1
                hitchMS += (interval - lastDuration) * 1000
            }
        }
        lastTimestamp = link.timestamp
        lastDuration = expected
        if link.timestamp - started >= Self.window {
            stop()
            publish(final: true)
        } else if link.timestamp - lastPublish > 0.25 {
            lastPublish = link.timestamp
            publish(final: false)
        }
    }

    private func publish(final: Bool) {
        let seconds = max(min(CACurrentMediaTime() - started, Self.window), 0.001)
        summary = "\(label)\(final ? "" : " (measuring)"): \(frames) frames · \(hitches) hitches · \(missed) missed · worst \(String(format: "%.1f", worstMS)) ms · \(String(format: "%.1f", hitchMS / seconds)) ms/s · \(maximumRate) Hz"
    }
}

/// CADisplayLink retains its target; this keeps the meter itself unretained.
private final class SandboxFrameMeterTarget: NSObject {
    private weak var meter: SandboxFrameMeter?
    init(meter: SandboxFrameMeter) { self.meter = meter }

    @MainActor @objc func tick(_ link: CADisplayLink) { meter?.tick(link) }
}

private struct SandboxFrameMeterView: View {
    let meter: SandboxFrameMeter

    var body: some View {
        Text(meter.summary)
            .font(TronTypography.code(size: TronTypography.sizeBody2))
            .foregroundStyle(Color.tronTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.tronSurfaceElevated.opacity(0.7)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Frame meter")
            .accessibilityValue(meter.summary)
            .accessibilityIdentifier("sandbox-frame-meter")
    }
}
