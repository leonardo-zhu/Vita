import Observation
import PhotosUI
import SwiftUI
import UIKit

@MainActor
@Observable
final class ChatModel {
    private let services: AppServices
    private let orchestrator: ChatOrchestrator
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    /// 当前会话日期（PRD §3.1：一个 Session 对应一天）。默认跟随今天，跨午夜自动换到新的一天。
    private(set) var sessionDate: LocalDate
    private var followsToday = true
    private(set) var entries: [ChatEntry] = []
    /// 正在生成的回复；nil 表示没有进行中的请求。
    private(set) var streamingText: String?
    /// 此刻在做什么（思考、查库、生成卡片）；nil 表示正在输出正文。
    private(set) var activity: ChatProgress.Activity?
    /// 模型此刻的推理摘要；不保存。
    private(set) var thinking = ""
    /// 这一轮调用过的工具；不保存。
    private(set) var steps: [ChatProgress.Step] = []
    /// 发送中的用户消息：一轮成功后才和回复一起保存，先在界面上显示。
    private(set) var outgoing: String?
    /// 发送中消息附带的标签照片，只用于显示。
    private(set) var outgoingImage: UIImage?
    /// 待发送的营养标签照片（已压缩的 JPEG）；发送时先在本机识别，再把识别结果交给模型。
    private(set) var attachment: Data?
    /// 缩略图缓存：在视图取值时写入，不参与界面刷新。
    @ObservationIgnored private var thumbnails: [UUID: UIImage] = [:]
    private(set) var pending: PendingSnapshot?
    /// 模型提到了别的日期：只提示切换，不自动跳转（TDD §5.2）。
    private(set) var requestedDate: LocalDate?
    private(set) var hasToken = false
    private var sendTask: Task<Void, Never>?
    var draft = ""
    var message: String?

    init(services: AppServices, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.services = services
        self.now = now
        self.timeZone = timeZone
        orchestrator = ChatOrchestrator(services: services, client: services.container.llmClient, now: now, timeZone: timeZone)
        sessionDate = LocalDate(date: now(), timeZone: timeZone())
    }

    var today: LocalDate { LocalDate(date: now(), timeZone: timeZone()) }
    var isSending: Bool { streamingText != nil }
    var canSend: Bool { !isSending && (attachment != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var attachmentImage: UIImage? { attachment.flatMap(UIImage.init(data:)) }

    /// 选好照片后先放在输入框上方，用户可以再补一句（如品名、喝了多少）再发。
    func attach(_ image: UIImage) {
        attachment = Self.compressed(image)
    }

    func removeAttachment() {
        attachment = nil
    }

    private static func scaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// 长边压到 2000 像素以内：足够本地识别，也不占太多空间。原图只存本机。
    private static func compressed(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 2000 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.85)
    }

    /// 消息里标签照片的缩略图，按识别记录读取本机原图。
    func labelThumbnail(_ ref: ChatCardRef) -> UIImage? {
        guard case .label(let id) = ref else { return nil }
        if let cached = thumbnails[id] { return cached }
        guard let reference = try? services.labels.imageReference(forScan: id),
              let data = try? services.labels.imageData(reference),
              let original = UIImage(data: data) else { return nil }
        let image = Self.scaled(original, maxSide: 440)
        thumbnails[id] = image
        return image
    }

    func reload() {
        if followsToday { sessionDate = today }
        hasToken = ((try? services.container.secrets.read(.conduitToken)) ?? nil)?.isEmpty == false
        do {
            try services.pending.expireDue()
            pending = try services.pending.active(on: sessionDate)
            entries = try services.chatHistory.messages(on: sessionDate)
        } catch {
            message = "无法读取对话：\(error)"
        }
    }

    func switchTo(_ date: LocalDate) {
        guard !isSending else { return }
        sessionDate = min(date, today)
        followsToday = sessionDate == today
        requestedDate = nil
        reload()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let image = attachment
        draft = ""
        attachment = nil
        requestedDate = nil
        outgoing = text
        outgoingImage = image.flatMap(UIImage.init(data:))
        streamingText = ""
        activity = image == nil ? .thinking : .tool("attachNutritionLabel")
        let date = sessionDate
        sendTask = Task {
            do {
                // attachNutritionLabel：在本机保存原图并识别，模型只拿到识别出的文字与候选值。
                var scanID: UUID?
                if let image {
                    do {
                        scanID = try await services.labels.scan(image).scanID
                    } catch {
                        throw LabelAttachmentError.recognitionFailed
                    }
                }
                let result = try await orchestrator.send(text, on: date, labelScan: scanID) { [weak self] progress in
                    self?.streamingText = progress.text
                    self?.activity = progress.activity
                    self?.thinking = progress.thinking
                    self?.steps = progress.steps
                }
                requestedDate = result.requestedDate
            } catch {
                // 这一轮没有保存，把原文和照片放回输入框，方便重发。
                if draft.isEmpty { draft = text }
                if attachment == nil { attachment = image }
                if error is LabelAttachmentError {
                    message = "没能识别这张照片里的文字，换一张清楚些、正对营养成分表的照片试试。"
                } else if let error = error as? LLMError {
                    message = error.userMessage
                } else if !(error is CancellationError) {
                    message = "发送失败：\(error)"
                }
            }
            outgoing = nil
            outgoingImage = nil
            streamingText = nil
            activity = nil
            thinking = ""
            steps = []
            reload()
        }
    }

    func stop() {
        sendTask?.cancel()
    }

    func confirm() {
        guard let pending else { return }
        do {
            try services.pending.confirm(pending.id)
            // 正式写入后把这次变化同步到 Apple 健康；失败不影响本地记录。
            Task { await services.healthSync.run() }
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

    /// 历史消息里卡片的结局：已确认、已取消或已过期。仍待确认的卡片在底部单独显示。
    func cardStatus(_ ref: ChatCardRef) -> PendingStatus? {
        guard case .pending(let id) = ref, let snapshot = try? services.pending.pending(id) else { return nil }
        return snapshot.status
    }

}

/// 本机识别标签照片失败（Vision 出错）。识别出空结果不算失败，交给模型去说明。
enum LabelAttachmentError: Error {
    case recognitionFailed
}

/// Chat 页（PRD §3.1）：按日期组织的对话。模型只能提出确认卡，记录在用户点确认后才保存。
struct ChatView: View {
    let services: AppServices
    @State private var model: ChatModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPickingDate = false
    @State private var isShowingSettings = false
    @AppStorage(OnboardingState.key) private var onboardingCompleted = false
    @FocusState private var inputFocused: Bool
    @State private var isPickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isTakingPhoto = false

    /// 设置里清空数据之后调用。
    var onDataReset: (() -> Void)?

    init(services: AppServices, onDataReset: (() -> Void)? = nil) {
        self.services = services
        self.onDataReset = onDataReset
        _model = State(initialValue: ChatModel(services: services))
    }

    var body: some View {
        NavigationStack {
            messages
                .safeAreaInset(edge: .bottom) { bottomBar }
                .background { VitaTheme.background }
                .navigationTitle(model.sessionDate == model.today ? "今天" : DisplayFormat.date(model.sessionDate))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("设置", systemImage: "gearshape") { isShowingSettings = true }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("选择日期", systemImage: "calendar") { isPickingDate = true }
                    }
                }
                .alert("提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(model.message ?? "")
                }
                .sheet(isPresented: $isPickingDate) { datePicker }
                .sheet(isPresented: $isShowingSettings, onDismiss: model.reload) {
                    SettingsView(services: services, onReplayOnboarding: { onboardingCompleted = false }, onDataReset: onDataReset)
                }
        }
        .tint(VitaTheme.intake)
        .photosPicker(isPresented: $isPickingPhoto, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) {
            guard let item = pickedPhoto else { return }
            pickedPhoto = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    model.attach(image)
                }
            }
        }
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPicker { image in model.attach(image) }
                .ignoresSafeArea()
        }
        .onAppear { model.reload() }
        .onChange(of: scenePhase) { if scenePhase == .active { model.reload() } }
    }

    // MARK: - 消息列表

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 一天的对话不长，用普通 VStack：LazyVStack 估算行高，滚到底部时会在顶部留出空白。
                VStack(alignment: .leading, spacing: 12) {
                    if model.entries.isEmpty && !model.isSending { emptyState }
                    ForEach(model.entries) { entry in
                        MessageRow(entry: entry, cardStatus: entry.cardRef.flatMap(model.cardStatus), image: entry.cardRef.flatMap(model.labelThumbnail))
                            .id(entry.id)
                    }
                    if let text = model.outgoing {
                        MessageRow(entry: ChatEntry(id: UUID(), role: .user, text: text, createdAt: Date()), image: model.outgoingImage)
                            .id("outgoing")
                    }
                    if let text = model.streamingText {
                        MessageRow(entry: ChatEntry(id: UUID(), role: .assistant, text: text, createdAt: Date()), steps: model.steps, activity: model.activity, thinking: model.thinking)
                            .id("streaming")
                    }
                    if let date = model.requestedDate {
                        Button("切换到 \(DisplayFormat.date(date))", systemImage: "calendar") { model.switchTo(date) }
                            .glassButton()
                            .frame(maxWidth: .infinity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.entries.count) { scrollToBottom(proxy) }
            .onChange(of: model.streamingText) { scrollToBottom(proxy, animated: false) }
            // 思考摘要与步骤清单会让生成中的气泡变高，同样要跟到底部。
            .onChange(of: model.thinking) { scrollToBottom(proxy, animated: false) }
            .onChange(of: model.steps.count) { scrollToBottom(proxy) }
            .onChange(of: model.pending?.id) { scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.hasToken {
            InvitationCard(
                symbol: "key.fill",
                tint: VitaTheme.protein,
                title: "连接模型服务",
                message: "填入 Conduit 访问令牌后，就可以用对话记录饮食。",
                actionTitle: "去设置",
                action: { isShowingSettings = true }
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.sessionDate == model.today ? "今天吃了什么？" : "补记 \(DisplayFormat.date(model.sessionDate))")
                        .font(.title2.weight(.bold))
                    Text("用平常的话说就行，Vita 会算好营养，你确认后才保存。")
                        .font(VitaType.body)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.suggestions, id: \.text) { suggestion in
                        Button {
                            model.draft = suggestion.text
                            inputFocused = true
                        } label: {
                            Label(suggestion.text, systemImage: suggestion.symbol)
                                .font(VitaType.body)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(VitaTheme.card, in: .capsule)
                                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.06)) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 4)
        }
    }

    /// 空状态里的示例，点一下填进输入框（不直接发送）。
    private static let suggestions: [(symbol: String, text: String)] = [
        ("sun.max", "中午吃了 200g 鸡胸肉和一碗米饭"),
        ("cup.and.saucer", "早上喝了一杯牛奶，吃了两个鸡蛋"),
        ("target", "我今天还能吃多少？"),
    ]

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let pending = model.pending {
                PendingCardView(pending: pending, onConfirm: model.confirm, onCancel: model.cancel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.smooth, value: model.pending?.id)
    }

    /// 输入框与发送按钮放在同一个圆角容器里；多行时按钮贴底。左侧的“+”用来附上营养标签照片。
    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = model.attachmentImage {
                attachmentPreview(image)
            }
            HStack(alignment: .bottom, spacing: 2) {
                attachMenu
                TextField(placeholder, text: $model.draft, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.vertical, 11)
                    .onSubmit(model.send)
            Group {
                if model.isSending {
                    Button(action: model.stop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.primary.opacity(0.85), in: .circle)
                    }
                    .accessibilityLabel("停止")
                } else {
                    Button(action: model.send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(model.canSend ? VitaTheme.intake : Color.secondary.opacity(0.35), in: .circle)
                    }
                    .disabled(!model.canSend)
                    .accessibilityLabel("发送")
                }
            }
            .padding(.trailing, 6)
            .padding(.bottom, 6)
            .animation(.smooth(duration: 0.2), value: model.canSend)
            }
        }
        .background(VitaTheme.card, in: .rect(cornerRadius: 23))
        .overlay {
            RoundedRectangle(cornerRadius: 23)
                .strokeBorder(inputFocused ? VitaTheme.intake.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .animation(.smooth(duration: 0.2), value: inputFocused)
    }

    private var placeholder: String {
        if model.attachment != nil { return "补充品名、吃了多少（可不填）" }
        return model.sessionDate == model.today ? "说说吃了什么…" : "补记 \(DisplayFormat.shortDate(model.sessionDate)) 吃了什么…"
    }

    private var attachMenu: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍营养标签", systemImage: "camera") { isTakingPhoto = true }
            }
            Button("从相册选择", systemImage: "photo.on.rectangle") { isPickingPhoto = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.06), in: .circle)
        }
        .disabled(model.isSending)
        .padding(.leading, 6)
        .padding(.bottom, 6)
        .accessibilityLabel("附上营养标签照片")
    }

    private func attachmentPreview(_ image: UIImage) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("营养标签").font(VitaType.secondary.weight(.semibold))
                Text("发送后在本机识别，只把识别出的文字交给模型。")
                    .font(VitaType.meta)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("移除照片", systemImage: "xmark.circle.fill", action: model.removeAttachment)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var datePicker: some View {
        NavigationStack {
            DatePicker(
                "日期",
                selection: Binding(
                    get: {
                        let date = model.sessionDate
                        return Calendar.current.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? Date()
                    },
                    set: { model.switchTo(LocalDate(date: $0, timeZone: .current)) }
                ),
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("今天") { model.switchTo(model.today); isPickingDate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPickingDate = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}

/// 一条消息：用户靠右、助手靠左；助手消息支持行内 Markdown。
private struct MessageRow: View {
    let entry: ChatEntry
    var cardStatus: PendingStatus?
    /// 用户消息附带的营养标签照片。
    var image: UIImage?
    /// 仅用于生成中的回复：已调用的工具、当前步骤与推理摘要。
    var steps: [ChatProgress.Step] = []
    var activity: ChatProgress.Activity?
    var thinking = ""

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if let image {
                        // 按原比例显示，宽的标签不被裁掉。
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(.rect(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)) }
                            .accessibilityLabel("营养标签照片")
                    }
                    if !entry.text.isEmpty {
                        Text(entry.text)
                            .font(VitaType.body)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(VitaTheme.intake, in: .rect(cornerRadius: 20))
                            .textSelection(.enabled)
                    }
                }
            }
        case .assistant, .toolSummary:
            VStack(alignment: .leading, spacing: 6) {
                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            HStack(spacing: 6) {
                                if step.done {
                                    Image(systemName: step.failed ? "exclamationmark.circle" : "checkmark.circle.fill")
                                        .foregroundStyle(step.failed ? VitaTheme.caution : VitaTheme.intake)
                                } else {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(ChatProgress.Activity.title(step.tool))
                                    .foregroundStyle(.secondary)
                            }
                            .font(VitaType.meta)
                        }
                    }
                    .padding(.bottom, 2)
                }
                if !entry.text.isEmpty {
                    Text(Self.markdown(entry.text))
                        .font(VitaType.body)
                        .textSelection(.enabled)
                }
                // 工具执行中的状态已在步骤清单里；还没有步骤时（如识别标签）也在这里显示。
                if let activity, activity == .thinking || steps.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(activity.label)
                            .font(VitaType.secondary)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                    .animation(.smooth, value: activity)
                    if activity == .thinking, !thinking.isEmpty {
                        ThinkingTail(text: thinking)
                    }
                }
                if let cardStatus, cardStatus != .readyForConfirmation {
                    Label(Self.label(cardStatus), systemImage: Self.symbol(cardStatus))
                        .font(VitaType.meta)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(VitaTheme.card, in: .rect(cornerRadius: 20))
            .padding(.trailing, 48)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private static func label(_ status: PendingStatus) -> String {
        switch status {
        case .confirmed: "已确认"
        case .cancelled: "已取消"
        case .expired: "已过期，没有保存"
        case .readyForConfirmation: "待确认"
        }
    }

    private static func symbol(_ status: PendingStatus) -> String {
        switch status {
        case .confirmed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .expired: "clock.badge.xmark"
        case .readyForConfirmation: "clock"
        }
    }
}

/// 拍营养标签：系统相机。模拟器没有相机，“+”菜单里不会出现这一项。
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// 推理摘要：最多露出四行，新内容在底部出现、旧内容向上移出并渐隐；不足四行时按内容高度显示。
private struct ThinkingTail: View {
    let text: String
    @State private var overflows = false

    private static let maxHeight: CGFloat = 64

    var body: some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(VitaType.meta)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { $0.size.height > Self.maxHeight } action: { overflows = $0 }
            .frame(height: overflows ? Self.maxHeight : nil, alignment: .bottom)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [.init(color: overflows ? .clear : .black, location: 0), .init(color: .black, location: 0.35)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .animation(.smooth(duration: 0.2), value: text)
    }
}
