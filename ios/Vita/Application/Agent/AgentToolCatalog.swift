import Foundation

/// 暴露给模型的工具清单与参数 schema（agent-tools.md）。清单和 schema 只随客户端发布；
/// 远程配置只能替换描述文字（vita-admin.md §3.2）。client-only 工具（confirmPending、commitInitialGoals 等）不在这里。
enum AgentToolCatalog {
    static let readTools: Set<String> = [
        "getDaySummary", "getRecordDetail", "searchPersonalFoods", "searchReferenceFoods",
        "getGoals", "getHealthSnapshot", "getGoalRecommendation",
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

    private struct Spec {
        var name: String
        var parameters: JSONValue
    }

    private static let specs: [Spec] = [
        Spec(
            name: "getDaySummary",
            parameters: schema(#"{"type":"object","properties":{"date":{"type":"string","description":"YYYY-MM-DD，可省略"}}}"#)
        ),
        Spec(
            name: "getRecordDetail",
            parameters: schema(#"{"type":"object","properties":{"recordId":{"type":"string"}},"required":["recordId"]}"#)
        ),
        Spec(
            name: "searchPersonalFoods",
            parameters: schema(#"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)
        ),
        Spec(
            name: "searchReferenceFoods",
            parameters: schema(#"{"type":"object","properties":{"query":{"type":"string"},"aliases":{"type":"array","items":{"type":"string"}}},"required":["query"]}"#)
        ),
        Spec(
            name: "getGoals",
            parameters: schema(#"{"type":"object","properties":{}}"#)
        ),
        Spec(
            name: "getHealthSnapshot",
            parameters: schema(#"{"type":"object","properties":{}}"#)
        ),
        Spec(
            name: "getGoalRecommendation",
            parameters: schema(#"{"type":"object","properties":{}}"#)
        ),
        Spec(
            name: "updateGoal",
            parameters: schema(#"""
            {"type":"object","properties":{
              "energyKcal":{"type":"number"},"proteinG":{"type":"number"},"fatG":{"type":"number"},"carbohydrateG":{"type":"number"},
              "userCommand":{"type":"string","description":"用户的原话，作为指令证据"}
            },"required":["userCommand"]}
            """#)
        ),
        Spec(
            name: "proposeRecordChange",
            parameters: schema(#"""
            {"type":"object","properties":{
              "sessionDate":{"type":"string","description":"YYYY-MM-DD，当前会话日期"},
              "expectedRevision":{"type":"integer","description":"读取到的当天 revision"},
              "payload":{"type":"object","properties":{
                "intent":{"type":"string","enum":["create","appendItems","replaceItem","removeItem"]},
                "recordId":{"type":"string","description":"非 create 时必填"},
                "itemId":{"type":"string","description":"replaceItem / removeItem 必填"},
                "record":{"type":"object","description":"create 用","properties":{
                  "eventTime":{"$ref":"#/$defs/eventTime"},
                  "mealLabel":{"type":"string"},
                  "note":{"type":"string"},
                  "items":{"type":"array","items":{"$ref":"#/$defs/item"}}
                },"required":["items"]},
                "items":{"type":"array","description":"appendItems 用","items":{"$ref":"#/$defs/item"}},
                "item":{"$ref":"#/$defs/item"},
                "replacesPendingId":{"type":"string"}
              },"required":["intent"]}
            },"required":["sessionDate","payload"],
            "$defs":{
              "eventTime":{"type":"object","properties":{
                "precision":{"type":"string","enum":["exact","approximate","mealPeriod","dateOnly"]},
                "time":{"type":"string","description":"HH:mm，exact / approximate 用"},
                "mealPeriod":{"type":"string","enum":["breakfast","lunch","dinner","snack","other"]}
              },"required":["precision"]},
              "item":{"type":"object","properties":{
                "displayName":{"type":"string"},
                "groupName":{"type":"string","description":"可选的菜品名，如“番茄炒蛋”"},
                "originalAmountText":{"type":"string","description":"用户的原始用量表达"},
                "quantity":{"type":"object","properties":{"amount":{"type":"number"},"unit":{"type":"string","description":"g / kg / ml / L / 斤 / 两 等；计数单位须先换算"}},"required":["amount","unit"]},
                "amountSource":{"type":"string","enum":["userMeasured","userStated","packageConversion","aiEstimated"]},
                "nutrition":{"type":"object","properties":{
                  "source":{"type":"string","enum":["personalFoodVersion","referenceFood","aiEstimated"]},
                  "foodVersionId":{"type":"string"},
                  "referenceFoodId":{"type":"string"},
                  "values":{"type":"object","properties":{"energyKcal":{"type":"number"},"proteinG":{"type":"number"},"fatG":{"type":"number"},"carbohydrateG":{"type":"number"}}},
                  "estimateBasis":{"type":"string"}
                },"required":["source"]},
                "includeInSummary":{"type":"boolean","description":"盐、葱花等可设 false"}
              },"required":["displayName","originalAmountText","amountSource","nutrition"]}
            }}
            """#)
        ),
        Spec(
            name: "proposeRecordDeletion",
            parameters: schema(#"""
            {"type":"object","properties":{
              "sessionDate":{"type":"string"},"expectedRevision":{"type":"integer"},
              "payload":{"type":"object","properties":{"recordId":{"type":"string"},"replacesPendingId":{"type":"string"}},"required":["recordId"]}
            },"required":["sessionDate","payload"]}
            """#)
        ),
        Spec(
            name: "proposeFoodChange",
            parameters: schema(#"""
            {"type":"object","properties":{
              "sessionDate":{"type":"string"},"expectedRevision":{"type":"integer"},
              "payload":{"type":"object","properties":{
                "intent":{"type":"string","enum":["createProduct","addVersion"]},
                "productId":{"type":"string"},
                "expectedActiveVersionId":{"type":"string"},
                "product":{"type":"object","properties":{
                  "name":{"type":"string"},"brandOrSupplier":{"type":"string"},
                  "package":{"type":"object","properties":{"amount":{"type":"number"},"unit":{"type":"string"}},"required":["amount","unit"]},
                  "note":{"type":"string"}
                },"required":["name"]},
                "version":{"type":"object","properties":{
                  "source":{"type":"string","enum":["nutritionLabel","manualEntry","referenceDerived"]},
                  "labelScanId":{"type":"string"},"referenceFoodId":{"type":"string"},
                  "basis":{"type":"object","properties":{"amount":{"type":"number"},"unit":{"type":"string"}},"required":["amount","unit"]},
                  "values":{"type":"object","properties":{"energyKcal":{"type":"number"},"proteinG":{"type":"number"},"fatG":{"type":"number"},"carbohydrateG":{"type":"number"}}},
                  "note":{"type":"string"}
                },"required":["source"]},
                "replacesPendingId":{"type":"string"}
              },"required":["intent","version"]}
            },"required":["sessionDate","payload"]}
            """#)
        ),
    ]

    /// schema 是源码里的常量；解析失败是编程错误，由测试保证。
    private static func schema(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .object([:])
    }
}
