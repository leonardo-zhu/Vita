import Foundation

/// 每日目标存在服务端，只追加、按日期生效。对话里改目标由服务端的 Agent 处理（`updateGoal`）；
/// App 里只有首次（或主动重新）生成：客户端选类型和调整，服务端按它存的健康数据重新计算后保存，不能提交数值。
@MainActor
final class GoalService {
    private let api: VitaAPIClient

    init(api: VitaAPIClient) {
        self.api = api
    }

    func activeGoal(on date: LocalDate) async throws -> GoalSnapshot? {
        let response: GoalResponseDTO = try await api.get("/v1/goals/active", query: [URLQueryItem(name: "date", value: date.isoString)])
        return response.goal?.domain
    }

    /// 用户在预览上确认后生成目标。预览是本机按同一公式算的；服务端重新算一遍，所以健康数据要先传上去（`HealthService.snapshot`）。
    @discardableResult
    func commitInitialGoals(kind: EnergyPlan.Kind, adjustment: EnergyPlan.Adjustment, effectiveFrom: LocalDate) async throws -> GoalSnapshot? {
        let request = GoalRequestDTO(date: effectiveFrom, kind: kind, adjustment: EnergyAdjustmentDTO(adjustment))
        let response: GoalResponseDTO = try await api.send("POST", "/v1/goals/initial", body: request)
        return response.goal?.domain
    }
}
