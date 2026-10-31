import Foundation

/// 暴露给模型的工具清单与参数 schema（agent-tools.md）。清单和 schema 只随客户端发布；
/// 远程配置只能替换描述文字（vita-admin.md §3.2）。client-only 工具（confirmPending、commitInitialGoals 等）不在这里。
enum AgentToolCatalog {
    static let readTools: Set<String> = [
        "getDaySummary", "getRecordDetail", "searchPersonalFoods", "searchReferenceFoods",
        "getGoals", "getHealthSnapshot", "getGoalRecommendation",
    ]

    static var names: Set<String> { readTools.union(ProposalToolHandler.toolNames).union(["updateGoal"]) }

    /// 按配置里的描述覆盖生成定义；未知的覆盖键被忽略。
    static func definitions(descriptions: [String: ToolPrompt]) -> [LLMToolDefinition] {
        specs.map { spec in
            LLMToolDefinition(
                name: spec.name,
                description: descriptions[spec.name]?.description ?? spec.description,
                parameters: spec.parameters
            )
        }
    }

    private struct Spec {
        var name: String
        var description: String
        var parameters: JSONValue
    }

    private static let specs: [Spec] = [
        Spec(
            name: "getDaySummary",
            description: "读取某一天的全部记录（含 Record ID、Item ID、用量与营养）、当天汇总、目标与 revision。不传 date 时读当前会话日期；历史日期可读但不能写。",
            parameters: schema(#"{"type":"object","properties":{"date":{"type":"string","description":"YYYY-MM-DD，可省略"}}}"#)
        ),
        Spec(
            name: "getRecordDetail",
            description: "读取当前会话日期中一条记录的完整内容，包括每项的营养来源与估算依据。",
            parameters: schema(#"{"type":"object","properties":{"recordId":{"type":"string"}},"required":["recordId"]}"#)
        ),
        Spec(
            name: "searchPersonalFoods",
            description: "按名称或品牌在用户的个人食品库中查找，返回产品 ID、生效版本 ID、包装规格与每基准营养。个人库优先于公共参考库。",
            parameters: schema(#"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)
        ),
        Spec(
            name: "searchReferenceFoods",
            description: "在公共营养参考库中按名称或别名精确查找，可附加其他写法。返回多个候选（如生/熟）时必须先问用户，不要自己挑。",
            parameters: schema(#"{"type":"object","properties":{"query":{"type":"string"},"aliases":{"type":"array","items":{"type":"string"}}},"required":["query"]}"#)
        ),
        Spec(
            name: "getGoals",
            description: "读取当前会话日期生效的每日目标（能量、蛋白质、脂肪、碳水）及其来源。",
            parameters: schema(#"{"type":"object","properties":{}}"#)
        ),
        Spec(
            name: "getHealthSnapshot",
            description: "读取 Apple 健康与手动补录的身体数据：体重、身高、体脂率、出生日期、生理性别、当日活动能量与前一晚睡眠，并标明来源。",
            parameters: schema(#"{"type":"object","properties":{}}"#)
        ),
        Spec(
            name: "getGoalRecommendation",
            description: "由客户端按固定公式计算每日目标建议（只读，不保存）。返回输入、公式、结果或缺失项。不要自己计算目标数值；首次保存目标由用户在 Data 页的目标设定里确认。",
            parameters: schema(#"{"type":"object","properties":{}}"#)
        ),
        Spec(
            name: "updateGoal",
            description: "用户明确给出新的目标数值时直接修改（如“把蛋白质目标改成 150g”）。只传要改的项，返回旧值与新值，请据此复述。建议性或含糊的说法先在对话中确认，不要调用。",
            parameters: schema(#"""
            {"type":"object","properties":{
              "energyKcal":{"type":"number"},"proteinG":{"type":"number"},"fatG":{"type":"number"},"carbohydrateG":{"type":"number"},
              "userCommand":{"type":"string","description":"用户的原话，作为指令证据"}
            },"required":["userCommand"]}
            """#)
        ),
        Spec(
            name: "proposeRecordChange",
            description: "提出新建、追加、替换或移除饮食记录的提案，生成确认卡；用户点确认后才会保存。命中个人库或参考库时只给 ID 与用量，不要给营养值；只有都没命中时才用 aiEstimated 并写明估算依据。用户没说时间就省略 eventTime。修正当前待确认卡片时填 replacesPendingId。",
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
            description: "提出删除整条记录的提案，生成确认卡；用户确认后才删除。",
            parameters: schema(#"""
            {"type":"object","properties":{
              "sessionDate":{"type":"string"},"expectedRevision":{"type":"integer"},
              "payload":{"type":"object","properties":{"recordId":{"type":"string"},"replacesPendingId":{"type":"string"}},"required":["recordId"]}
            },"required":["sessionDate","payload"]}
            """#)
        ),
        Spec(
            name: "proposeFoodChange",
            description: "提出把食品存入个人食品库（新建产品或为已有产品加新版本）的提案，生成确认卡。来源只能是营养标签、用户提供的数值或公共参考库，AI 估算不能存入。",
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
