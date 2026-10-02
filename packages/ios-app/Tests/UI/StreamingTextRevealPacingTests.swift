import Foundation
import Testing
@testable import TronMobile

/// Deterministic checks of the streaming reveal pacing and tokenization.
/// Failure modes guarded here:
/// - reveal speed depends on how often stream frames arrive (a frame restarts
///   the reveal task), so a slower Gateway cadence slows the reveal until the
///   backlog trips the catch-up and words appear with no fade;
/// - pacing cannot keep up with realistic model speeds (10–80 words/s), so
///   words start long after they arrived or pop via the safety valve;
/// - the low-backlog rhythm (one word per 55 ms) changes;
/// - the tokenizer duplicates or drops text, so the rendered transcript
///   differs from the authoritative source.
struct StreamingTextRevealPacingTests {
    // MARK: Pacing

    @Test("pacing keeps up without a catch-up at every realistic speed and cadence")
    func pacingKeepsUpAtRealisticSpeeds() {
        for cadence in RevealCadence.allCases {
            for wordsPerSecond in [10.0, 25, 40, 60, 80] {
                let arrivals = cadence.arrivals(wordsPerSecond: wordsPerSecond, durationMilliseconds: 20_000)
                let result = RevealSimulation.current(arrivals: arrivals)
                let label = "\(cadence) at \(Int(wordsPerSecond)) words/s"
                #expect(result.poppedWords == 0, "\(label): \(result.poppedWords) words skipped the fade")
                #expect(result.starts.count == arrivals.count, "\(label): every word starts")
                #expect(result.maximumStartLatency <= 350, "\(label): latency \(result.maximumStartLatency) ms")
            }
        }
    }

    @Test("a low word rate keeps the 55 ms rhythm")
    func lowRateKeepsFiftyFiveMillisecondRhythm() {
        for cadence in [RevealCadence.gateway150, .gateway75] {
            let arrivals = cadence.arrivals(wordsPerSecond: 10, durationMilliseconds: 20_000)
            let result = RevealSimulation.current(arrivals: arrivals)
            var backloggedGaps = 0
            for index in result.starts.indices.dropFirst() {
                let gap = result.starts[index] - result.starts[index - 1]
                #expect(gap >= 55 - 1e-6, "\(cadence): gap \(gap) ms")
                // A word already waiting when its predecessor started follows
                // it by exactly the low-backlog interval.
                if arrivals[index] <= result.starts[index - 1] {
                    #expect(abs(gap - 55) < 1e-6, "\(cadence): backlogged gap \(gap) ms")
                    backloggedGaps += 1
                }
            }
            if cadence == .gateway150 { #expect(backloggedGaps > 0) }
        }
        for backlog in 1...3 {
            let interval = ChatStreamingTextRevealPolicy.wordInterval(
                now: 0,
                pendingArrivals: Array(repeating: 0, count: backlog)[...]
            )
            #expect(interval == 55, "backlog \(backlog)")
        }
    }

    @Test("a stall beyond the safety valve shows the backlog at once")
    func stallTripsSafetyValve() {
        let policy = ChatStreamingTextRevealPolicy.self
        let oversized = Array(repeating: 0.0, count: policy.maximumAnimatedBacklog + 1)
        #expect(policy.admission(now: 0, clock: nil, pendingArrivals: oversized).catchUp)
        #expect(policy.admission(now: 1_001, clock: 0, pendingArrivals: [0]).catchUp)
        #expect(!policy.admission(now: 999, clock: 0, pendingArrivals: [0]).catchUp)
    }

    /// The pre-fix rule granted a word on every task restart and paced the
    /// rest at 55 ms, so a 150 ms frame cadence at 25 words/s tripped the
    /// catch-up. The same checker must see it.
    @Test("the restart-driven rule pops words at 25 words/s with 150 ms frames")
    func restartDrivenRulePopsWords() {
        let arrivals = RevealCadence.gateway150.arrivals(wordsPerSecond: 25, durationMilliseconds: 20_000)
        let previous = RevealSimulation.restartDriven(arrivals: arrivals)
        #expect(previous.poppedWords > arrivals.count / 10, "popped \(previous.poppedWords) of \(arrivals.count)")
        #expect(RevealSimulation.current(arrivals: arrivals).poppedWords == 0)
    }

    // MARK: Tokenization

    @Test("tokens reproduce the source exactly", arguments: [
        "Hello world",
        "Hello world ",
        "Hello world\n",
        "Hello world   ",
        "Hello world \n\n",
        "  Hello  world",
        "   ",
        "\n",
        "",
        "one",
        "one\ttwo\n\nthree ",
    ])
    func tokensReproduceSource(source: String) {
        let tokens = ChatStreamingInlineText.tokens(in: AttributedString(source), identity: "t")
        let rendered = tokens.reduce(into: "") { $0 += String($1.value.characters) }
        #expect(rendered == source)
        let wordCount = source.split(whereSeparator: \.isWhitespace).count
        #expect(tokens.filter(\.isWord).count == wordCount)
        #expect(Set(tokens.map(\.id)).count == tokens.count)
    }
}

enum RevealCadence: CaseIterable, CustomStringConvertible {
    case gateway150
    case gateway75
    /// Irregular frames between 45 and 330 ms apart, deterministic.
    case bursty

    var description: String {
        switch self {
        case .gateway150: "150 ms frames"
        case .gateway75: "75 ms frames"
        case .bursty: "bursty frames"
        }
    }

    /// Arrival time (ms) of each word, in order; words in one frame share it.
    func arrivals(wordsPerSecond: Double, durationMilliseconds: Double) -> [Double] {
        var generator = UInt64(0x9E37_79B9_7F4A_7C15)
        var time = 0.0
        var result: [Double] = []
        while time < durationMilliseconds {
            switch self {
            case .gateway150: time += 150
            case .gateway75: time += 75
            case .bursty:
                generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Double(generator >> 11) / Double(1 << 53)
                time += 150 * (0.3 + 1.9 * unit)
            }
            let due = Int(wordsPerSecond * time / 1_000) - result.count
            result += Array(repeating: time, count: max(0, due))
        }
        return result
    }
}

/// Replays the reveal task's control flow in virtual time: each frame arrival
/// restarts the task, which admits words and then ticks until nothing is
/// pending or fading.
struct RevealSimulation {
    var starts: [Double] = []
    var poppedWords = 0
    var maximumStartLatency = 0.0

    private static let fade = Double(ChatStreamingTextRevealPolicy.fadeMilliseconds)

    static func current(arrivals: [Double], tickDelay: Double = 0) -> RevealSimulation {
        let policy = ChatStreamingTextRevealPolicy.self
        var result = RevealSimulation()
        var clock: Double?
        var admitted = 0
        var wake: Double?
        let frames = frameTimes(arrivals)
        var frameIndex = 0
        while true {
            let frame = frameIndex < frames.count ? frames[frameIndex] : .infinity
            let now = min(frame, wake ?? .infinity)
            guard now.isFinite else { break }
            if frame <= now {
                frameIndex += 1
                while admitted < arrivals.count, arrivals[admitted] <= now { admitted += 1 }
            }
            let started = result.starts.count + result.poppedWords
            let admission = policy.admission(
                now: now,
                clock: clock,
                pendingArrivals: Array(arrivals[started..<admitted])
            )
            if admission.catchUp {
                result.poppedWords += admitted - started
                clock = nil
                wake = nil
                continue
            }
            clock = admission.clock
            for start in admission.startTimes {
                result.maximumStartLatency = max(
                    result.maximumStartLatency,
                    start - arrivals[result.starts.count + result.poppedWords]
                )
                result.starts.append(start)
            }
            let fading = (result.starts.last ?? -.infinity) + fade > now
            wake = admission.nextStart != nil || fading
                ? now + policy.tickMilliseconds(now: now, nextStart: admission.nextStart) + tickDelay
                : nil
        }
        return result
    }

    /// The pre-fix loop: a restart caught up past 18 pending words, otherwise
    /// started one word at once and one more every 55 ms.
    static func restartDriven(arrivals: [Double]) -> RevealSimulation {
        var result = RevealSimulation()
        var admitted = 0
        var wake: Double?
        let frames = frameTimes(arrivals)
        var frameIndex = 0
        while true {
            let frame = frameIndex < frames.count ? frames[frameIndex] : .infinity
            let now = min(frame, wake ?? .infinity)
            guard now.isFinite else { break }
            let restarted = frame <= now
            if restarted {
                frameIndex += 1
                while admitted < arrivals.count, arrivals[admitted] <= now { admitted += 1 }
            }
            let started = result.starts.count + result.poppedWords
            if restarted, admitted - started > 18 {
                result.poppedWords += admitted - started
                wake = nil
                continue
            }
            if started < admitted {
                result.maximumStartLatency = max(result.maximumStartLatency, now - arrivals[started])
                result.starts.append(now)
                wake = now + 55
            } else {
                wake = (result.starts.last ?? -.infinity) + fade > now ? now + 33 : nil
            }
        }
        return result
    }

    private static func frameTimes(_ arrivals: [Double]) -> [Double] {
        var frames: [Double] = []
        for arrival in arrivals where frames.last != arrival { frames.append(arrival) }
        return frames
    }
}
