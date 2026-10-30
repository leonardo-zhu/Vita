import Foundation
import HealthKit

/// HealthKit 实现。读写类型严格限定在 PRD §3.3 所列（TDD §6.1）。
final class HealthKitDataStore: HealthDataStore, @unchecked Sendable {
    private let store = HKHealthStore()

    private static let dietaryTypes: [Nutrient: HKQuantityType] = [
        .energyKcal: HKQuantityType(.dietaryEnergyConsumed),
        .proteinG: HKQuantityType(.dietaryProtein),
        .fatG: HKQuantityType(.dietaryFatTotal),
        .carbohydrateG: HKQuantityType(.dietaryCarbohydrates),
    ]

    private static var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.height), HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.activeEnergyBurned), HKCategoryType(.sleepAnalysis),
            HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex),
        ]
    }

    private static var writeTypes: Set<HKSampleType> { Set(dietaryTypes.values) }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthStoreError.unavailable }
        try await store.requestAuthorization(toShare: Self.writeTypes, read: Self.readTypes)
    }

    func hasRequestedAuthorization() async -> Bool {
        guard isAvailable,
              let status = try? await store.statusForAuthorizationRequest(toShare: Self.writeTypes, read: Self.readTypes)
        else { return false }
        return status == .unnecessary
    }

    func writeAuthorization() -> HealthWriteAuthorization {
        guard isAvailable else { return .denied }
        let statuses = Self.writeTypes.map { store.authorizationStatus(for: $0) }
        if statuses.contains(.sharingDenied) { return .denied }
        if statuses.contains(.notDetermined) { return .notDetermined }
        return .authorized
    }

    // MARK: - 读取

    private func latest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> (Decimal, Date)? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        guard let sample = try await descriptor.result(for: store).first else { return nil }
        return (Decimal(sample.quantity.doubleValue(for: unit)), sample.endDate)
    }

    func latestBodyMassKg() async throws -> (Decimal, Date)? {
        try await latest(.bodyMass, unit: .gramUnit(with: .kilo)).map { (Self.round($0.0, 1), $0.1) }
    }

    func latestHeightCm() async throws -> (Decimal, Date)? {
        try await latest(.height, unit: .meterUnit(with: .centi)).map { (Self.round($0.0, 1), $0.1) }
    }

    func latestBodyFatFraction() async throws -> (Decimal, Date)? {
        try await latest(.bodyFatPercentage, unit: .percent()).map { (Self.round($0.0, 3), $0.1) }
    }

    func dateOfBirth() throws -> LocalDate? {
        let components = try store.dateOfBirthComponents()
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }

    func biologicalSex() throws -> BiologicalSex? {
        switch try store.biologicalSex().biologicalSex {
        case .female: .female
        case .male: .male
        case .other: .other
        default: nil
        }
    }

    func activeEnergyKcal(on date: LocalDate, timeZone: TimeZone) async throws -> Decimal? {
        let (start, end) = Self.dayBounds(date, timeZone: timeZone)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.activeEnergyBurned), predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: .cumulativeSum
        )
        guard let sum = try await descriptor.result(for: store)?.sumQuantity() else { return nil }
        return Self.round(Decimal(sum.doubleValue(for: .kilocalorie())), 0)
    }

    func sleepHours(endingOn date: LocalDate, timeZone: TimeZone) async throws -> Decimal? {
        // 前一天 18:00 到当天 12:00 之间的“睡着”时段。
        let (start, _) = Self.dayBounds(date, timeZone: timeZone)
        let windowStart = start.addingTimeInterval(-6 * 3600)
        let windowEnd = start.addingTimeInterval(12 * 3600)
        let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd))],
            sortDescriptors: []
        )
        let samples = try await descriptor.result(for: store).filter { asleep.contains($0.value) }
        guard !samples.isEmpty else { return nil }
        let seconds = samples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        return Self.round(Decimal(seconds / 3600), 1)
    }

    // MARK: - 写入

    func save(_ samples: [DietarySample]) async throws -> [UUID] {
        guard writeAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        let objects = samples.map { sample -> HKQuantitySample in
            let type = Self.dietaryTypes[sample.nutrient]!
            let unit: HKUnit = sample.nutrient == .energyKcal ? .kilocalorie() : .gram()
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: NSDecimalNumber(decimal: sample.value).doubleValue),
                start: sample.date, end: sample.date,
                metadata: sample.metadata
            )
        }
        try await store.save(objects)
        return objects.map(\.uuid)
    }

    func delete(_ uuids: [UUID]) async throws {
        guard !uuids.isEmpty else { return }
        guard writeAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        let predicate = HKQuery.predicateForObjects(with: Set(uuids))
        for type in Self.writeTypes {
            try await store.deleteObjects(of: type, predicate: predicate)
        }
    }

    // MARK: - 工具

    private static func dayBounds(_ date: LocalDate, timeZone: TimeZone) -> (Date, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
        return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    private static func round(_ value: Decimal, _ scale: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }
}
