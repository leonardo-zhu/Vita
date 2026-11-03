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

    /// 体脂秤写入的类型：和膳食一起申请，但授权状态分开判断（膳食写入被拒不影响称重写入）。
    private static var bodyWriteTypes: Set<HKSampleType> { [HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage)] }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthStoreError.unavailable }
        // 膳食与体脂秤的写入一次申请完；已经答复过的类型系统不会再问，只列出新的。
        try await store.requestAuthorization(toShare: Self.writeTypes.union(Self.bodyWriteTypes), read: Self.readTypes)
    }

    /// iOS 不告诉 App 读取是否被允许，只能看写入：任何一项写入有过答复，就说明问过了。
    func hasRequestedAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return Self.writeTypes.union(Self.bodyWriteTypes).contains { store.authorizationStatus(for: $0) != .notDetermined }
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

    func bodyWriteAuthorization() -> HealthWriteAuthorization {
        guard isAvailable else { return .denied }
        return switch store.authorizationStatus(for: HKQuantityType(.bodyMass)) {
        case .sharingAuthorized: .authorized
        case .sharingDenied: .denied
        default: .notDetermined
        }
    }

    func saveBodyMeasurement(_ sample: BodyMeasurementSample) async throws -> [UUID] {
        guard bodyWriteAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        let metadata: [String: Any] = [HKMetadataKeyWasUserEntered: false]
        var objects = [
            HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: NSDecimalNumber(decimal: sample.bodyMassKg).doubleValue),
                start: sample.date, end: sample.date, metadata: metadata
            ),
        ]
        // 体脂率允许单独被拒；被拒时只写体重。
        if let fat = sample.bodyFatFraction, store.authorizationStatus(for: HKQuantityType(.bodyFatPercentage)) == .sharingAuthorized {
            objects.append(HKQuantitySample(
                type: HKQuantityType(.bodyFatPercentage),
                quantity: HKQuantity(unit: .percent(), doubleValue: NSDecimalNumber(decimal: fat).doubleValue),
                start: sample.date, end: sample.date, metadata: metadata
            ))
        }
        try await store.save(objects)
        return objects.map(\.uuid)
    }

    func deleteBodyMeasurements(_ uuids: [UUID]) async throws {
        guard !uuids.isEmpty else { return }
        guard bodyWriteAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        let predicate = HKQuery.predicateForObjects(with: Set(uuids))
        for type in Self.bodyWriteTypes {
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
