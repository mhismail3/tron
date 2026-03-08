import Foundation
import HealthKit

/// Handles health data device requests using HealthKit.
///
/// Read-only: queries steps, distance, energy, sleep, heart rate, and workouts.
/// Only reads data types that are enabled in integration settings.
final class HealthService: @unchecked Sendable {
    static let shared = HealthService()

    private let store = HKHealthStore()

    private init() {}

    // MARK: - Authorization

    func requestPermission() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let types: Set<HKObjectType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.flightsClimbed),
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKCategoryType(.sleepAnalysis),
            HKWorkoutType.workoutType(),
        ]
        do {
            try await store.requestAuthorization(toShare: [], read: types)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Request Routing

    func handle(action: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw DeviceRequestError.serviceUnavailable("HealthKit")
        }

        switch action {
        case "today":
            return try await todaySummary()
        case "query":
            return try await queryData(params: params)
        case "workouts":
            return try await recentWorkouts(params: params)
        default:
            throw DeviceRequestError.unknownMethod("health.\(action)")
        }
    }

    // MARK: - Today Summary

    private func todaySummary() async throws -> [String: AnyCodable] {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Date()

        var summary: [String: Any] = [:]

        if let steps = try? await queryStatistic(.stepCount, start: start, end: end, unit: .count()) {
            summary["steps"] = Int(steps)
        }
        if let distance = try? await queryStatistic(.distanceWalkingRunning, start: start, end: end, unit: .meter()) {
            summary["distanceMeters"] = Int(distance)
        }
        if let energy = try? await queryStatistic(.activeEnergyBurned, start: start, end: end, unit: .kilocalorie()) {
            summary["activeCalories"] = Int(energy)
        }
        if let flights = try? await queryStatistic(.flightsClimbed, start: start, end: end, unit: .count()) {
            summary["flightsClimbed"] = Int(flights)
        }

        return ["summary": AnyCodable(summary)]
    }

    // MARK: - Query

    private func queryData(params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        guard let dataType = params?["dataType"]?.value as? String else {
            throw DeviceRequestError.unknownMethod("health.query: dataType required")
        }

        let range = parseDateRange(params: params)

        switch dataType {
        case "steps":
            let value = try await queryStatistic(.stepCount, start: range.start, end: range.end, unit: .count())
            return ["value": AnyCodable(Int(value)), "unit": AnyCodable("count")]
        case "distance":
            let value = try await queryStatistic(.distanceWalkingRunning, start: range.start, end: range.end, unit: .meter())
            return ["value": AnyCodable(Int(value)), "unit": AnyCodable("meters")]
        case "energy":
            let value = try await queryStatistic(.activeEnergyBurned, start: range.start, end: range.end, unit: .kilocalorie())
            return ["value": AnyCodable(Int(value)), "unit": AnyCodable("kcal")]
        case "flights":
            let value = try await queryStatistic(.flightsClimbed, start: range.start, end: range.end, unit: .count())
            return ["value": AnyCodable(Int(value)), "unit": AnyCodable("count")]
        case "heartRate":
            let samples = try await querySamples(.heartRate, start: range.start, end: range.end, unit: .count().unitDivided(by: .minute()))
            return ["samples": AnyCodable(samples)]
        case "restingHeartRate":
            let samples = try await querySamples(.restingHeartRate, start: range.start, end: range.end, unit: .count().unitDivided(by: .minute()))
            return ["samples": AnyCodable(samples)]
        case "sleep":
            let samples = try await querySleepSamples(start: range.start, end: range.end)
            return ["samples": AnyCodable(samples)]
        default:
            throw DeviceRequestError.unknownMethod("health.query: unknown dataType '\(dataType)'")
        }
    }

    // MARK: - Workouts

    private func recentWorkouts(params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        let limit = (params?["limit"]?.value as? Int) ?? 10

        return try await withQueryTimeout {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: HKWorkoutType.workoutType(),
                    predicate: nil,
                    limit: limit,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    let workouts = (samples as? [HKWorkout] ?? []).map { workout -> [String: Any] in
                        var dict: [String: Any] = [
                            "type": workout.workoutActivityType.name,
                            "startDate": DateParser.toISO8601(workout.startDate),
                            "endDate": DateParser.toISO8601(workout.endDate),
                            "durationMinutes": Int(workout.duration / 60)
                        ]
                        if let distance = workout.totalDistance {
                            dict["distanceMeters"] = Int(distance.doubleValue(for: .meter()))
                        }
                        if let energy = workout.totalEnergyBurned {
                            dict["calories"] = Int(energy.doubleValue(for: .kilocalorie()))
                        }
                        return dict
                    }

                    continuation.resume(returning: ["workouts": AnyCodable(workouts)])
                }

                self.store.execute(query)
            }
        }
    }

    // MARK: - Helpers

    /// Timeout for individual HealthKit queries. Prevents hanging Tasks when
    /// a query's completion handler is never called (e.g., unauthorized type).
    private static let queryTimeout: TimeInterval = 15

    private func queryStatistic(
        _ identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date,
        unit: HKUnit
    ) async throws -> Double {
        let quantityType = HKQuantityType(identifier)

        return try await withQueryTimeout {
            try await withCheckedThrowingContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
                let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let value = result?.sumQuantity()?.doubleValue(for: unit) ?? 0
                    continuation.resume(returning: value)
                }
                self.store.execute(query)
            }
        }
    }

    private func querySamples(
        _ identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date,
        unit: HKUnit
    ) async throws -> [[String: Any]] {
        let quantityType = HKQuantityType(identifier)

        return try await withQueryTimeout {
            try await withCheckedThrowingContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
                let query = HKSampleQuery(
                    sampleType: quantityType,
                    predicate: predicate,
                    limit: 100,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let results = (samples as? [HKQuantitySample] ?? []).map { sample -> [String: Any] in
                        [
                            "value": sample.quantity.doubleValue(for: unit),
                            "date": DateParser.toISO8601(sample.startDate)
                        ]
                    }
                    continuation.resume(returning: results)
                }
                self.store.execute(query)
            }
        }
    }

    private func querySleepSamples(start: Date, end: Date) async throws -> [[String: Any]] {
        let sleepType = HKCategoryType(.sleepAnalysis)

        return try await withQueryTimeout {
            try await withCheckedThrowingContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
                let query = HKSampleQuery(
                    sampleType: sleepType,
                    predicate: predicate,
                    limit: 100,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let results = (samples as? [HKCategorySample] ?? []).map { sample -> [String: Any] in
                        let stage: String
                        switch sample.value {
                        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: stage = "core"
                        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: stage = "deep"
                        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: stage = "rem"
                        case HKCategoryValueSleepAnalysis.awake.rawValue: stage = "awake"
                        case HKCategoryValueSleepAnalysis.inBed.rawValue: stage = "inBed"
                        default: stage = "unknown"
                        }
                        return [
                            "stage": stage,
                            "startDate": DateParser.toISO8601(sample.startDate),
                            "endDate": DateParser.toISO8601(sample.endDate),
                            "durationMinutes": Int(sample.endDate.timeIntervalSince(sample.startDate) / 60),
                        ]
                    }
                    continuation.resume(returning: results)
                }
                self.store.execute(query)
            }
        }
    }

    /// Box to shuttle non-Sendable HealthKit results through a task group.
    private struct ResultBox<T>: @unchecked Sendable {
        let value: T
    }

    /// Wraps a HealthKit query with a timeout to prevent hanging forever
    /// when HealthKit never calls the completion handler.
    private func withQueryTimeout<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: ResultBox<T>.self) { group in
            group.addTask {
                ResultBox(value: try await operation())
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.queryTimeout))
                throw HealthQueryError.timeout
            }
            // First to complete wins; cancel the other
            let result = try await group.next()!
            group.cancelAll()
            return result.value
        }
    }

    private func parseDateRange(params: [String: AnyCodable]?) -> (start: Date, end: Date) {
        let dateRange = params?["dateRange"]?.value as? [String: Any]
        let start: Date
        var end: Date

        if let fromStr = dateRange?["from"] as? String,
           let parsed = DateParser.parse(fromStr) {
            start = parsed
        } else {
            start = Calendar.current.startOfDay(for: Date())
        }

        if let toStr = dateRange?["to"] as? String,
           let parsed = DateParser.parse(toStr) {
            end = parsed
        } else {
            end = Date()
        }

        // When from == to (date-only strings like "2026-03-10"), extend to end of day
        if end <= start {
            end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        }

        return (start, end)
    }
}

// MARK: - Health Query Error

enum HealthQueryError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "HealthKit query timed out — the data type may not be authorized or available on this device"
        }
    }
}

// MARK: - Workout Activity Type Names

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .walking: return "Walking"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining: return "Core Training"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing: return "Stair Climbing"
        case .dance: return "Dance"
        case .cooldown: return "Cooldown"
        default: return "Other"
        }
    }
}
