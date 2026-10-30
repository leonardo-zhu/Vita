import Observation
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class ChatModel {
    private let services: AppServices
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    private(set) var pending: PendingSnapshot?
    var message: String?

    init(services: AppServices, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.services = services
        self.now = now
        self.timeZone = timeZone
    }

    /// 对话日期；按日期切换 Session 随 Phase 5 加入。
    var sessionDate: LocalDate { LocalDate(date: now(), timeZone: timeZone()) }

    func reload() {
        do {
            pending = try services.pending.active(on: sessionDate)
        } catch {
            message = "无法读取待确认内容：\(error)"
        }
    }

    func confirm() {
        guard let pending else { return }
        do {
            try services.pending.confirm(pending.id)
        } catch PendingServiceError.revisionConflict {
            message = "当天数据在提案后有变化，这张卡片已作废，请重新提出。"
        } catch PendingServiceError.expired {
            message = "这张卡片已过期，没有写入任何数据。"
        } catch {
            message = "确认失败：\(error)"
        }
        reload()
    }

    func cancel() {
        guard let pending else { return }
        try? services.pending.cancel(pending.id)
        reload()
    }

    #if DEBUG
    func runFakeAgent(_ step: FakeAgent.Step) {
        do {
            let day = try services.dayData.day(sessionDate)
            send(try FakeAgent.call(step, day: day, products: try services.foods.products(), replacing: pending?.id))
        } catch {
            message = "\(error)"
        }
        reload()
    }

    /// 模拟 `attachNutritionLabel` 之后模型的下一步：本地识别图片，再按候选值提出新建食品。
    func scanLabel(_ imageData: Data) async {
        do {
            let scan = try await services.labels.scan(imageData)
            send(try FakeAgent.foodFromLabel(scan, day: try services.dayData.day(sessionDate)))
        } catch FakeAgent.FakeAgentError.incompleteLabel(let warnings) {
            message = "标签没有识别完整：" + warnings.joined(separator: "；")
        } catch {
            message = "识别失败：\(error)"
        }
        reload()
    }

    private func send(_ call: FakeAgent.Call) {
        let handler = ProposalToolHandler(
            pending: services.pending, referenceFoods: services.container.referenceFoods,
            labels: services.labels, now: now, timeZone: timeZone
        )
        let result = handler.handle(tool: call.tool, arguments: call.arguments, sessionDate: sessionDate)
        if let error = result.error {
            message = "\(error.code)：\(error.message)"
        }
    }
    #endif
}

/// Chat 页骨架：对话随 Phase 5 接入，现在只承载当天的确认卡；Debug 构建可用“假 Agent”生成提案。
struct ChatView: View {
    @State private var model: ChatModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?

    init(services: AppServices) {
        _model = State(initialValue: ChatModel(services: services))
    }

    var body: some View {
        NavigationStack {
            ContentUnavailableView("对话即将上线", systemImage: "bubble.left.and.bubble.right", description: Text("模型接入后，在这里用自然语言记录饮食。"))
                .safeAreaInset(edge: .bottom) {
                    if let pending = model.pending {
                        PendingCardView(pending: pending, onConfirm: model.confirm, onCancel: model.cancel)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.smooth, value: model.pending?.id)
                .navigationTitle("Chat")
                .toolbar {
                    #if DEBUG
                    ToolbarItem(placement: .topBarTrailing) { fakeAgentMenu }
                    #endif
                }
                .alert("提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(model.message ?? "")
                }
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) {
            guard let item = pickedPhoto else { return }
            pickedPhoto = nil
            #if DEBUG
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await model.scanLabel(data) }
            }
            #endif
        }
        .onAppear { model.reload() }
        .onChange(of: scenePhase) { if scenePhase == .active { model.reload() } }
    }

    #if DEBUG
    private var fakeAgentMenu: some View {
        Menu("假 Agent", systemImage: "ladybug") {
            Section("营养标签") {
                Button("扫描样例营养标签", systemImage: "doc.text.viewfinder") {
                    Task { await model.scanLabel(SampleLabelImage.render()) }
                }
                Button("从相册选择营养标签", systemImage: "photo") { isPickingPhoto = true }
            }
            Section("记录") {
                ForEach(FakeAgent.Step.allCases, id: \.self) { step in
                    Button(step.title) { model.runFakeAgent(step) }
                }
            }
        }
    }
    #endif
}
