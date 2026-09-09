import Darwin
import SwiftUI
import XCTest
@testable import TronMobile

/// Diagnostic benchmark of the real rendering surface, not a device/GPU frame
/// budget assertion. Keep its duration fixed when comparing implementations.
@MainActor
final class ContextWindowSliderMotionTests: XCTestCase {
    func testRepeatedMorphRenderingCost() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let driver = SliderMotionDriver()
        let appeared = expectation(description: "Motion fixture appeared")
        let host = SliderMotionHost(rootView: SliderMotionFixture(driver: driver).tronPresentation())
        host.safeAreaRegions = []
        host.onAppear = { appeared.fulfill() }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let recorder = SliderFrameDeliveryRecorder()
        defer {
            recorder.stop()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [appeared], timeout: 2)
        print("CONTEXT_SURFACE_PROFILE_PID=\(getpid())")
        var results: [[String: Double]] = []
        for cycle in 0..<8 {
            let initialContentBuilds = driver.contentBuilds
            let initialLabelBuilds = driver.labelBuilds
            recorder.start()
            let startCPU = cpuSeconds()
            let startWall = CACurrentMediaTime()
            for target in [CGFloat(1), 0] {
                let finished = expectation(description: "Morph settled")
                withAnimation(.spring(duration: 0.42, bounce: 0.12), completionCriteria: .logicallyComplete) {
                    driver.fraction = target
                } completion: { finished.fulfill() }
                await fulfillment(of: [finished], timeout: 2)
            }
            let cpu = cpuSeconds() - startCPU
            let wall = CACurrentMediaTime() - startWall
            recorder.stop()
            XCTAssertEqual(driver.fraction, 0)
            XCTAssertGreaterThan(recorder.intervals.count, 10, "The benchmark must exercise mounted animation delivery")
            let contentBuilds = driver.contentBuilds - initialContentBuilds
            let labelBuilds = driver.labelBuilds - initialLabelBuilds
            if cycle >= 2 {
                let intervals = recorder.intervals.sorted()
                let maximum = try XCTUnwrap(intervals.last)
                results.append([
                    "contentBuilds": Double(contentBuilds), "labelBuilds": Double(labelBuilds),
                    "cpuSeconds": cpu, "wallSeconds": wall,
                    "frames": Double(intervals.count),
                    "p95DeliveryMs": intervals[Int(Double(intervals.count - 1) * 0.95)] * 1_000,
                    "maxDeliveryMs": maximum * 1_000,
                    "missedDeliveryEstimate": Double(recorder.missedFrames),
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        print("CONTEXT_SURFACE_SAMPLES=\(json)")
        let attachment = XCTAttachment(string: json)
        attachment.name = "context-slider-motion-simulator-samples"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Assert after timing all cycles so a known-bad control's failure
        // reporting cannot contaminate its subsequent CPU samples.
        for sample in results {
            // Allow framework setup passes, not display-cadence reconstruction.
            // Input changes must still refresh both payloads.
            for key in ["contentBuilds", "labelBuilds"] {
                let count = try XCTUnwrap(sample[key])
                XCTAssertGreaterThan(count, 0)
                XCTAssertLessThan(count, 8)
            }
        }
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

@MainActor @Observable
private final class SliderMotionDriver {
    var fraction: CGFloat = 0
    @ObservationIgnored var contentBuilds = 0
    @ObservationIgnored var labelBuilds = 0
}

private struct SliderMotionFixture: View {
    let driver: SliderMotionDriver
    var body: some View {
        ZStack {
            VStack(spacing: 18) {
                Text("Manage Session").font(TronTypography.headline)
                ForEach(0..<3) { _ in
                    VStack(spacing: 0) {
                        TronSettingsRow(icon: "brain", title: "Thinking", subtitle: "Extra High", accent: .tronPurple)
                        TronSettingsDivider(accent: .tronPurple)
                        TronSettingsRow(icon: "gauge.with.dots.needle.50percent", title: "Context Window", subtitle: "272,000", accent: .tronPurple)
                    }
                    .tronGlassSurface(accent: .tronPurple)
                }
            }
            .padding(18)
            ConfigurationSliderSurface(
                source: CGRect(x: 322, y: 356, width: 100, height: 28),
                target: CGRect(x: 18, y: 285, width: 404, height: 170),
                fraction: driver.fraction, reduceMotion: false, accent: .tronPurple
            ) {
                let _ = driver.contentBuilds += 1
                VStack(spacing: 12) {
                    HStack {
                        Text("Context Window")
                        Spacer()
                        Text("272,000")
                    }.font(TronTypography.buttonSM)
                    Capsule().fill(Color.tronPurple.opacity(0.2))
                        .frame(height: 42)
                        .overlay(alignment: .leading) {
                            Circle().fill(Color.tronPurple.opacity(0.16))
                                .glassEffect(.regular.tint(Color.tronPurple.opacity(0.16)).interactive(), in: .circle)
                                .frame(width: 38, height: 38).offset(x: 80)
                        }
                    ContextWindowSliderLabelsLayout(defaultProgress: 0.232) {
                        Text("37,408")
                        Text("Default")
                        Text("1,050,000")
                    }.font(TronTypography.secondaryCodeDescription)
                }.padding(20)
            } label: {
                let _ = driver.labelBuilds += 1
                Text("272,000").font(TronTypography.sans(size: 12, weight: .semibold))
            }
        }
    }
}

@MainActor
private final class SliderMotionHost<Content: View>: UIHostingController<Content> {
    var onAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let completion = onAppear
        onAppear = nil
        completion?()
    }
}

@MainActor
private final class SliderFrameDeliveryRecorder: NSObject {
    var intervals: [Double] = []
    var missedFrames = 0
    private var previous: CFTimeInterval?
    private var displayLink: CADisplayLink?

    func start() {
        intervals = []
        missedFrames = 0
        previous = nil
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() { displayLink?.invalidate(); displayLink = nil }

    @objc private func frame(_ link: CADisplayLink) {
        if let previous {
            let interval = link.timestamp - previous
            intervals.append(interval)
            missedFrames += max(0, Int((interval / max(link.duration, 1.0 / 120)).rounded()) - 1)
        }
        previous = link.timestamp
    }
}
