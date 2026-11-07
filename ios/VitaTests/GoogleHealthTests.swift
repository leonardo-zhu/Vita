import Foundation
import Testing
@testable import Vita

@MainActor
struct GoogleHealthTests {
    @Test func decodesGoogleHealthReadingsInTheSnapshot() async throws {
        let stub = APIStub()
        stub.on("GET", "/v1/health/snapshot", json: """
        {"bodyMassKg":{"status":"value","value":70,"source":"healthKit","measuredAt":"2026-10-30T00:00:00.000Z"},
        "heightCm":{"status":"noData"},"bodyFatFraction":{"status":"noData"},"dateOfBirth":{"status":"noData"},"sex":{"status":"noData"},
        "sleepHours":{"status":"value","value":6.8,"source":"googleHealth","measuredAt":null},
        "activeEnergyKcal":{"status":"value","value":450,"source":"googleHealth","measuredAt":null},
        "averageActiveEnergyKcal":{"status":"value","value":400,"source":"googleHealth","measuredAt":null},
        "authorizationRequested":true,"writeDenied":false,"uploadedAt":null}
        """)
        let snapshot: HealthSnapshotDTO = try await stub.client().get("/v1/health/snapshot")
        let domain = snapshot.domain
        #expect(domain.activeEnergyKcal == .value(450, source: .googleHealth, measuredAt: nil))
        #expect(domain.sleepHours.source == .googleHealth)
        #expect(domain.bodyMassKg.source == .healthKit)
    }

    @Test func readsTheStatusFromTheServer() async throws {
        let stub = APIStub()
        stub.on("GET", "/v1/google-health", json: #"{"configured":true,"connected":true,"connectedAt":"2026-10-30T12:00:00.000Z","lastSyncAt":"2026-10-30T12:00:00.000Z","lastError":"network","lastErrorAt":"2026-10-30T12:30:00.000Z"}"#)
        let status = try await GoogleHealthService(api: stub.client()).status()
        #expect(status.connected)
        #expect(status.lastError == "network")
        #expect(status.lastSyncAt == VitaAPIClient.parseDate("2026-10-30T12:00:00.000Z"))
    }

    @Test func labelsTheSourceOnTheCard() {
        #expect(MetricCardSource.note(.googleHealth, nil) == "Google 健康")
        #expect(MetricCardSource.note(.manual, nil) == "手动补录")
        #expect(MetricCardSource.note(.healthKit, nil) == nil)
    }
}
