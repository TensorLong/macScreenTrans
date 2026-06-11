import AppKit
import MacScreenTransCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(onSelfCheck: @escaping () -> String, onTranslateUnderCursor: @escaping () -> Void) {
        let view = SettingsView(onSelfCheck: onSelfCheck, onTranslateUnderCursor: onTranslateUnderCursor)
        // Resizable: on small displays or with enlarged system text the
        // grouped Form overflows one screen, so users must be able to grow
        // and shrink the window. The Form scrolls internally at any size.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacScreenTrans 设置"
        // A closable NSWindow defaults to isReleasedWhenClosed == true; with
        // this controller also holding a strong Swift reference, clicking
        // the red close button would over-release the window and crash on
        // the next show(). Keep ownership purely with ARC.
        window.isReleasedWhenClosed = false
        // Kept out of our own OCR captures via window-ID exclusion (see
        // ScreenRegionCapture), NOT sharingType — so external screenshot
        // tools can still record this window.
        window.contentView = NSHostingView(rootView: view)
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @AppStorage(DefaultsKey.endpoint) private var endpoint = EndpointResolver.defaultBaseURL
    @AppStorage(DefaultsKey.apiKey) private var apiKey = ""
    @AppStorage(DefaultsKey.model) private var model = AppConfiguration.defaultModel
    @AppStorage(DefaultsKey.targetLanguage) private var targetLanguage = "zh"
    @AppStorage(DefaultsKey.promptTemplate) private var promptTemplate = PromptBuilder.defaultPromptTemplate
    @AppStorage(DefaultsKey.fetchedModels) private var fetchedModelsStorage = ""
    @AppStorage(DefaultsKey.fetchedModelsSource) private var fetchedModelsSource = ""
    @AppStorage(DefaultsKey.fetchedModelsAt) private var fetchedModelsAt = 0.0

    let onSelfCheck: () -> String
    let onTranslateUnderCursor: () -> Void

    @State private var selfCheckResult = ""
    @State private var permissionGranted = PermissionHelper.screenRecordingGranted
    @State private var connectionResult = ""
    @State private var isTestingConnection = false
    @State private var showSelfCheckResult = false
    @State private var showAdvanced = false
    @State private var modelFetchPhase = ModelFetchPhase.idle
    @State private var isCustomModelEntry = false
    @State private var isCustomLanguageEntry = false

    /// Sentinel Picker tags for the "自定义…" entries. Control characters
    /// cannot collide with real model ids or language codes.
    private static let customModelSentinel = "\u{1}custom-model"
    private static let customLanguageSentinel = "\u{1}custom-language"

    private static let languagePresets: [(code: String, label: String)] = [
        ("zh", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                statusSection
                translationServiceSection
                languageSection
                diagnosticsSection
                advancedSection
            }
            .formStyle(.grouped)

            Divider()
            footerBar
        }
        .frame(minWidth: 560, idealWidth: 680, maxWidth: .infinity,
               minHeight: 420, idealHeight: 760, maxHeight: .infinity)
        .onAppear(perform: refreshStatuses)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatuses()
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section {
            LabeledContent("屏幕录制") {
                HStack(spacing: 10) {
                    statusLabel(
                        permissionGranted ? "已授权" : "需要授权",
                        state: permissionGranted ? .good : .warning
                    )
                    if !permissionGranted {
                        Button("去授权") {
                            PermissionHelper.openScreenRecordingSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .help(permissionGranted ? "可以截取屏幕识别文字" : "请允许 MacScreenTrans 录制屏幕，授权后需重启应用")

            LabeledContent("API 配置") {
                statusLabel(apiConfigurationStatus.value, state: apiConfigurationStatus.state)
            }
            .help(apiConfigurationStatus.detail)

            LabeledContent("取词监听") {
                statusLabel(listeningStatus.value, state: listeningStatus.state)
            }
            .help(listeningStatus.detail)
        } footer: {
            Text("配置完成后，把鼠标放到文字上，三指轻点触控板即可翻译光标下文本；如果系统弹出“查找”，请在触控板设置里关闭相关手势。")
        }
    }

    private func statusLabel(_ text: String, state: StatusState) -> some View {
        Label(text, systemImage: state.symbol)
            .foregroundStyle(state.color)
    }

    // MARK: - 翻译服务

    private var translationServiceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("服务地址", text: $endpoint, prompt: Text(EndpointResolver.defaultBaseURL))
                    .autocorrectionDisabled()
                endpointCaption
            }

            LabeledContent("API Key") {
                RevealableSecureField(text: $apiKey)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("模型") {
                    HStack(spacing: 8) {
                        modelPicker
                        fetchModelsButton
                    }
                }
                if isCustomModelEntry {
                    TextField("输入模型 ID，如 openai/gpt-4o-mini", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit {
                            if cachedModels.contains(model) {
                                isCustomModelEntry = false
                            }
                        }
                }
                modelCatalogCaption
            }

            HStack {
                Spacer()
                Button {
                    testConnection()
                } label: {
                    Group {
                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("测试连接", systemImage: "network")
                        }
                    }
                    .frame(minWidth: 96)
                }
                .disabled(isTestingConnection || testConnectionBlocker != nil)
                .help(testConnectionBlocker ?? "用当前配置发起一次真实翻译，验证地址、Key 和模型")
            }

            if !connectionResult.isEmpty {
                ResultBox(text: connectionResult)
            }
        } header: {
            Text("翻译服务")
        } footer: {
            Text("服务地址会自动补全 `/v1/chat/completions`。API Key 仅保存在本机，不会在状态或结果中显示；本地服务（Ollama、LM Studio）可留空。")
        }
    }

    private var endpointCaption: some View {
        Group {
            if let url = EndpointResolver.chatCompletionsURL(baseURL: endpoint) {
                Text("实际请求：\(url.absoluteString)")
                    .foregroundStyle(.secondary)
            } else {
                Text("地址无效：需以 http:// 或 https:// 开头")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private var modelPicker: some View {
        Picker("", selection: modelPickerSelection) {
            if !cachedModels.contains(model) {
                Text(model.isEmpty ? "（未设置）" : "\(model)（自定义）").tag(model)
                Divider()
            }
            ForEach(cachedModels, id: \.self) { id in
                Text(id).tag(id)
            }
            Divider()
            Text("自定义…").tag(Self.customModelSentinel)
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var modelPickerSelection: Binding<String> {
        Binding(
            get: {
                isCustomModelEntry ? Self.customModelSentinel : model
            },
            set: { newValue in
                if newValue == Self.customModelSentinel {
                    isCustomModelEntry = true
                } else {
                    isCustomModelEntry = false
                    model = newValue
                }
            }
        )
    }

    private var fetchModelsButton: some View {
        Button {
            fetchModels()
        } label: {
            Group {
                if modelFetchPhase == .loading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(minWidth: 24)
        }
        .disabled(modelFetchPhase == .loading || modelsURL == nil)
        .accessibilityLabel("获取模型列表")
        .help(modelsURL == nil
            ? "需要先填写有效的服务地址（http/https）"
            : "获取模型列表：从 \(modelsURL!.absoluteString) 拉取可用模型")
    }

    @ViewBuilder private var modelCatalogCaption: some View {
        switch modelFetchPhase {
        case let .failed(message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("重试") {
                    fetchModels()
                }
                .controlSize(.small)
            }
        case .unsupported:
            Text("该服务不支持模型列表接口，请手动输入模型 ID。")
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle, .loading:
            if !cachedModels.isEmpty {
                let fetchedAt = Date(timeIntervalSince1970: fetchedModelsAt)
                Text("已获取 \(cachedModels.count) 个模型 · \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 取词与语言

    private var languageSection: some View {
        Section("翻译目标") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("目标语言") {
                    Picker("", selection: languagePickerSelection) {
                        if !Self.languagePresets.contains(where: { $0.code == targetLanguage }) {
                            Text("\(targetLanguage)（自定义）").tag(targetLanguage)
                            Divider()
                        }
                        ForEach(Self.languagePresets, id: \.code) { preset in
                            Text("\(preset.label)（\(preset.code)）").tag(preset.code)
                        }
                        Divider()
                        Text("自定义…").tag(Self.customLanguageSentinel)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                if isCustomLanguageEntry {
                    TextField("输入语言代码，如 fr、de", text: $targetLanguage)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 240)
                }
            }
        }
    }

    private var languagePickerSelection: Binding<String> {
        Binding(
            get: {
                isCustomLanguageEntry ? Self.customLanguageSentinel : targetLanguage
            },
            set: { newValue in
                if newValue == Self.customLanguageSentinel {
                    isCustomLanguageEntry = true
                } else {
                    isCustomLanguageEntry = false
                    targetLanguage = newValue
                }
            }
        )
    }

    // MARK: - 诊断与权限

    private var diagnosticsSection: some View {
        Section("诊断与权限") {
            HStack(spacing: 10) {
                Button {
                    runSelfCheck()
                } label: {
                    Label("权限自检", systemImage: "checkmark.shield")
                }
                Button {
                    triggerTranslateUnderCursor()
                } label: {
                    Label("翻译光标下文本", systemImage: "text.cursor")
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    PermissionHelper.openScreenRecordingSettings()
                } label: {
                    Label("屏幕录制设置", systemImage: "rectangle.dashed.badge.record")
                }
                Button {
                    PermissionHelper.openTrackpadSettings()
                } label: {
                    Label("触控板设置", systemImage: "hand.tap")
                }
                Spacer()
            }

            if showSelfCheckResult, !selfCheckResult.isEmpty {
                ResultBox(text: friendlySelfCheckResult)
            }
        }
    }

    // MARK: - 高级

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Prompt 与模型行为", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("只有模型持续返回错误格式时才需要修改。")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") {
                            promptTemplate = PromptBuilder.defaultPromptTemplate
                        }
                    }

                    TextEditor(text: $promptTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.24))
                        )
                }
                .padding(.top, 10)
            }
        } header: {
            Text("高级")
        } footer: {
            Text("支持 `{word}`、`{context}`、`{target_language}` 等占位符，修改会立即保存。")
        }
    }

    private var footerBar: some View {
        HStack {
            Text("MacScreenTrans v\(AppConfiguration.appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("退出 MacScreenTrans") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - 模型列表获取

    private enum ModelFetchPhase: Equatable {
        case idle
        case loading
        case unsupported
        case failed(String)
    }

    /// The resolved `/v1/models` URL — doubles as the cache key, so a changed
    /// endpoint automatically invalidates the cached list while an API key
    /// change keeps it (model catalogs belong to hosts, not keys).
    private var modelsURL: URL? {
        EndpointResolver.endpointURL(baseURL: endpoint, path: ModelCatalogClient.modelsPath)
    }

    private var cachedModels: [String] {
        guard !fetchedModelsSource.isEmpty,
              fetchedModelsSource == modelsURL?.absoluteString else {
            return []
        }
        return fetchedModelsStorage
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func fetchModels() {
        guard modelFetchPhase != .loading, let url = modelsURL else { return }
        modelFetchPhase = .loading

        let endpoint = endpoint
        let apiKey = apiKey
        let source = url.absoluteString

        Task {
            do {
                let ids = try await ModelCatalogClient().fetchModelIDs(endpoint: endpoint, apiKey: apiKey)
                await MainActor.run {
                    guard !ids.isEmpty else {
                        // An empty (or unsupported) catalog must never wipe an
                        // existing cache or the configured model — manual
                        // entry stays a first-class path.
                        modelFetchPhase = .unsupported
                        return
                    }
                    fetchedModelsStorage = ids.joined(separator: "\n")
                    fetchedModelsSource = source
                    fetchedModelsAt = Date().timeIntervalSince1970
                    modelFetchPhase = .idle
                }
            } catch {
                await MainActor.run {
                    modelFetchPhase = Self.fetchFailurePhase(for: error)
                }
            }
        }
    }

    private static func fetchFailurePhase(for error: Error) -> ModelFetchPhase {
        guard let catalogError = error as? ModelCatalogError else {
            return .failed("获取失败：\(error.localizedDescription)")
        }
        switch catalogError {
        case .malformedResponse, .httpFailure(404, _):
            return .unsupported
        case .invalidEndpoint:
            return .failed("获取失败：服务地址无效。")
        case .invalidHTTPResponse:
            return .failed("获取失败：服务返回了无法识别的响应。")
        case let .httpFailure(status, _):
            let hint: String
            switch status {
            case 401, 403:
                hint = "API Key 无效或权限不足。"
            case 429:
                hint = "请求过于频繁或额度不足。"
            case 500...599:
                hint = "服务端暂时不可用。"
            default:
                hint = "HTTP \(status)。"
            }
            return .failed("获取失败：\(hint)")
        }
    }

    // MARK: - 状态计算

    private var apiConfigurationStatus: (value: String, detail: String, state: StatusState) {
        let endpointOK = EndpointResolver.chatCompletionsURL(baseURL: endpoint) != nil
        let apiKeyOK = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modelOK = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard endpointOK else {
            return ("服务地址无效", "请填写 OpenAI 兼容接口地址（http/https）", .bad)
        }
        guard modelOK else {
            return ("缺少模型名", "请选择或填写可用模型", .warning)
        }
        guard apiKeyOK else {
            return ("已配置（无 Key）", "本地服务（如 Ollama）可留空 API Key", .good)
        }
        return ("已配置", "可进行连接测试", .good)
    }

    private var listeningStatus: (value: String, detail: String, state: StatusState) {
        if selfCheckResult.contains("三指轻点监听：运行中") {
            return ("监听中", "菜单栏图标“译”已启用", .good)
        }
        if selfCheckResult.contains("三指轻点监听：未运行") {
            return ("未监听", "可从菜单栏重新启动监听", .warning)
        }
        if selfCheckResult.isEmpty {
            return ("检查中", "菜单栏图标“译”可打开操作菜单", .neutral)
        }
        return ("状态未知", "请运行权限自检查看详情", .warning)
    }

    private var friendlySelfCheckResult: String {
        selfCheckResult
            .replacingOccurrences(of: "Endpoint", with: "服务地址")
            .replacingOccurrences(of: "Model", with: "模型")
    }

    private func refreshStatuses() {
        permissionGranted = PermissionHelper.screenRecordingGranted
        selfCheckResult = onSelfCheck()
    }

    private func runSelfCheck() {
        refreshStatuses()
        showSelfCheckResult = true
    }

    private func triggerTranslateUnderCursor() {
        refreshStatuses()
        connectionResult = permissionGranted
            ? "已请求翻译。请在 2 秒内把鼠标移到要翻译的文字上，然后查看光标附近的弹窗。"
            : "需要屏幕录制权限。点击“屏幕录制设置”授权 MacScreenTrans 后重启应用。"
        onTranslateUnderCursor()
    }

    // MARK: - 测试连接

    /// Non-nil when the test-connection button must stay disabled; the value
    /// is the exact missing prerequisite, surfaced via `.help()`.
    private var testConnectionBlocker: String? {
        guard EndpointResolver.chatCompletionsURL(baseURL: endpoint) != nil else {
            return "需要先填写有效的服务地址（http/https）"
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "需要先选择或填写模型"
        }
        return nil
    }

    private func testConnection() {
        guard !isTestingConnection, testConnectionBlocker == nil else { return }

        let config = TranslationConfig(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            targetLanguage: targetLanguage,
            promptTemplate: promptTemplate
        )

        isTestingConnection = true
        connectionResult = "正在测试连接..."

        Task {
            do {
                let selection = WordSelection(
                    word: "sentence",
                    context: "The phrase given a sentence should translate clearly.",
                    wordRangeInContext: 19..<27
                )
                var output = ""
                for try await delta in OpenAIStreamingClient().streamExplanation(selection: selection, config: config) {
                    output += delta
                    if output.utf16.count > 1_200 {
                        break
                    }
                }

                await MainActor.run {
                    isTestingConnection = false
                    if let response = SenseGroupResponseRenderer.response(for: output), response.hasSource, response.hasTarget {
                        connectionResult = "连接成功。示例：\(response.source) → \(response.target)"
                    } else if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        connectionResult = "连接成功，但模型没有返回文本。请换一个模型或稍后重试。"
                    } else {
                        connectionResult = "连接成功，但模型没有返回可解析的译文 JSON。请点击“恢复默认”后重试，或换一个模型。"
                    }
                }
            } catch {
                await MainActor.run {
                    isTestingConnection = false
                    connectionResult = settingsErrorMessage(for: error)
                }
            }
        }
    }

    private func settingsErrorMessage(for error: Error) -> String {
        guard let streamingError = error as? OpenAIStreamingError else {
            return "请求失败：\(error.localizedDescription)"
        }
        switch streamingError {
        case let .serverError(message):
            return "服务端返回错误：\(message)"
        case .invalidEndpoint:
            return "服务地址无效。"
        case .invalidHTTPResponse:
            return "服务返回了无法识别的响应。"
        case let .httpFailure(status, _):
            let hint: String
            switch status {
            case 401, 403:
                hint = "API Key 无效、权限不足或模型不可用。"
            case 404:
                hint = "接口或模型不存在。"
            case 429:
                hint = "请求过于频繁或额度不足。"
            case 500...599:
                hint = "服务端暂时不可用。"
            default:
                hint = "HTTP \(status)。"
            }
            return "连接失败：\(hint)"
        }
    }
}

/// SecureField with an eye toggle that reveals the key as plain text.
/// The two fields share one binding and swap via opacity so the toggle
/// preserves the caret/focus; the key re-masks whenever the app deactivates.
private struct RevealableSecureField: View {
    @Binding var text: String

    @State private var revealed = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case secure
        case plain
    }

    var body: some View {
        HStack(spacing: 6) {
            // Conditional swap, not a ZStack opacity cross-fade: the
            // AppKit-backed hidden twin still paints its placeholder at
            // opacity 0, ghosting "可留空" on top of the secure dots.
            Group {
                if revealed {
                    TextField("", text: $text)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .plain)
                } else {
                    SecureField("", text: $text)
                        .focused($focusedField, equals: .secure)
                }
            }
            .multilineTextAlignment(.trailing)

            Button {
                let wasFocused = focusedField != nil
                revealed.toggle()
                if wasFocused {
                    focusedField = revealed ? .plain : .secure
                }
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? "隐藏 API Key" : "显示 API Key")
            .help(revealed ? "隐藏 API Key" : "显示 API Key")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            revealed = false
        }
    }
}

private struct ResultBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum StatusState {
    case good
    case warning
    case bad
    case neutral

    var color: Color {
        switch self {
        case .good:
            return .green
        case .warning:
            return .orange
        case .bad:
            return .red
        case .neutral:
            return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .good:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .bad:
            return "xmark.octagon.fill"
        case .neutral:
            return "circle.dashed"
        }
    }
}
