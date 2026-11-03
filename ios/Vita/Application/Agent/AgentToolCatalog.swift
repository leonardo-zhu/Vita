import Foundation

/// 暴露给模型的工具清单与参数 schema（agent-tools.md）。清单和 schema 只随客户端发布（`shared/agent-tools/tool-parameters.json`）；
/// 远程配置只能替换描述文字（vita-admin.md §3.2）。client-only 工具（confirmPending、commitInitialGoals 等）不在这里。
enum AgentToolCatalog {
    static let readTools: Set<String> = [
        "getDaySummary", "getRecordDetail", "searchPersonalFoods", "searchReferenceFoods",
        "getGoals", "getHealthSnapshot", "getBodyComposition", "getGoalRecommendation",
    ]

    static var names: Set<String> { readTools.union(ProposalToolHandler.toolNames).union(["updateGoal"]) }

    /// 描述来自生效配置：内置默认值（DefaultConfig.json）给出每个工具的描述，远程配置可以替换。
    /// 内置默认值覆盖全部工具由测试保证；未知的键被忽略。
    static func definitions(descriptions: [String: ToolPrompt]) -> [LLMToolDefinition] {
        specs.map { spec in
            LLMToolDefinition(
                name: spec.name,
                description: descriptions[spec.name]?.description ?? "",
                parameters: spec.parameters
            )
        }
    }

    struct Spec: Decodable, Equatable {
        var name: String
        var parameters: JSONValue
    }

    static let resourceName = "tool-parameters"

    /// 参数 schema 在 `shared/agent-tools/tool-parameters.json`，随 App 打包，Admin 试跑用同一份。
    /// 文件是构建产物，读不到或解析失败是构建错误，由测试保证；这里退回空清单而不是崩溃。
    static let specs: [Spec] = (try? loadSpecs(from: .main)) ?? []

    static func loadSpecs(from bundle: Bundle) throws -> [Spec] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        struct File: Decodable { var tools: [Spec] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).tools
    }
}
