import Foundation
import Testing
@testable import Vita

/// 服务端快照里体重、体脂率可能直接来自体脂秤的称重（source `vitaScale`）。
@MainActor
struct VitaScaleSourceTests {
    @Test func decodesScaleReadingsInTheSnapshot() async throws {
        let stub = APIStub()
        stub.on("GET", "/v1/health/snapshot", json: """
        {"bodyMassKg":{"status":"value","value":69.6,"source":"vitaScale","measuredAt":"2026-10-30T00:00:00.000Z"},
        "heightCm":{"status":"value","value":170,"source":"healthKit","measuredAt":null},
        "bodyFatFraction":{"status":"value","value":0.211,"source":"vitaScale","measuredAt":"2026-10-30T00:00:00.000Z"},
        "dateOfBirth":{"status":"noData"},"sex":{"status":"noData"},"sleepHours":{"status":"noData"},
        "activeEnergyKcal":{"status":"noData"},"averageActiveEnergyKcal":{"status":"noData"},
        "authorizationRequested":true,"writeDenied":false,"uploadedAt":null}
        """)
        let snapshot: HealthSnapshotDTO = try await stub.client().get("/v1/health/snapshot")
        let domain = snapshot.domain
        #expect(domain.bodyMassKg.source == .vitaScale)
        #expect(domain.bodyMassKg.value == Decimal(string: "69.6"))
        #expect(domain.bodyFatFraction.source == .vitaScale)
        #expect(domain.heightCm.source == .healthKit)
    }

    @Test func labelsTheScaleOnTheCard() {
        #expect(MetricCardSource.note(.vitaScale, nil) == "体脂秤")
        let measured = MetricCardSource.note(.vitaScale, Date())
        #expect(measured?.hasPrefix("体脂秤 · ") == true)
    }

    /// 写入被拒、Apple 健康什么都读不到时，体脂秤的称重不算 Apple 健康有数据。
    @Test func scaleReadingsDoNotHideDeniedAccess() {
        var snapshot = HealthSnapshot.empty
        snapshot.authorizationRequested = true
        snapshot.writeDenied = true
        snapshot.bodyMassKg = .value(70, source: .vitaScale, measuredAt: Date())
        snapshot.bodyFatFraction = .value(Decimal(string: "0.2")!, source: .vitaScale, measuredAt: Date())
        #expect(snapshot.accessLikelyDenied)
    }
}
