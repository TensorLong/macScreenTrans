import AppKit
import MacScreenTransCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(onSelfCheck: @escaping () -> String, onTranslateUnderCursor: @escaping () -> Void) {
        let view = SettingsView(onSelfCheck: onSelfCheck, onTranslateUnderCursor: onTranslateUnderCursor)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacScreenTrans"
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

    let onSelfCheck: () -> String
    let onTranslateUnderCursor: () -> Void
    @State private var selfCheckResult = ""
    @State private var permissionGranted = PermissionHelper.accessibilityTrusted
    @State private var connectionResult = ""
    @State private var isTestingConnection = false
    @State private var showSelfCheckResult = false
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusPanel
                configurationPanel
                actionsPanel
                advancedSettings
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 640, minHeight: 640)
        .onAppear(perform: refreshStatuses)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatuses()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: StatusBarIcon.makeBadge())
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text("MacScreenTrans 设置")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("配置光标取词翻译、辅助功能权限和模型连接。API Key 不会在状态或结果中显示。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出") {
                NSApp.terminate(nil)
            }
        }
    }

    private var statusPanel: some View {
        Panel("开始使用") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    StatusTile(
                        title: "辅助功能",
                        value: permissionGranted ? "已授权" : "需要授权",
                        detail: permissionGranted ? "可以读取光标下文本" : "请允许 MacScreenTrans 访问辅助功能",
                        state: permissionGranted ? .good : .warning
                    )
                    StatusTile(
                        title: "API 配置",
                        value: apiConfigurationStatus.value,
                        detail: apiConfigurationStatus.detail,
                        state: apiConfigurationStatus.state
                    )
                    StatusTile(
                        title: "监听 / 菜单栏",
                        value: listeningStatus.value,
                        detail: listeningStatus.detail,
                        state: listeningStatus.state
                    )
                }

                Text("配置完成后，把鼠标放到文字上，三指轻点触控板即可翻译光标下文本；如果系统弹出“查找”，请在触控板设置里关闭相关手势。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configurationPanel: some View {
        Panel("基础配置") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledField("服务地址") {
                    TextField("https://openrouter.ai/api/v1", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                LabeledField("API Key") {
                    SecureField("粘贴 OpenAI-compatible API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .top, spacing: 14) {
                    LabeledField("模型") {
                        TextField("openai/gpt-4o-mini", text: $model)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledField("目标语言") {
                        TextField("zh", text: $targetLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }

                Text("服务地址会自动补全 `/v1/chat/completions`；API Key 仅通过安全输入框编辑。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionsPanel: some View {
        Panel("操作") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                    Button {
                        testConnection()
                    } label: {
                        Label(isTestingConnection ? "正在测试..." : "测试连接", systemImage: "network")
                    }
                    .disabled(isTestingConnection)
                    .frame(maxWidth: .infinity)

                    Button {
                        runSelfCheck()
                    } label: {
                        Label("权限自检", systemImage: "checkmark.shield")
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        PermissionHelper.openAccessibilitySettings()
                    } label: {
                        Label("打开辅助功能设置", systemImage: "gearshape")
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        PermissionHelper.openTrackpadSettings()
                    } label: {
                        Label("打开触控板设置", systemImage: "hand.tap")
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        triggerTranslateUnderCursor()
                    } label: {
                        Label("翻译光标下文本", systemImage: "text.cursor")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if !connectionResult.isEmpty {
                    ResultBox(text: connectionResult)
                }

                if showSelfCheckResult, !selfCheckResult.isEmpty {
                    ResultBox(text: friendlySelfCheckResult)
                }
            }
        }
    }

    private var advancedSettings: some View {
        Panel("高级") {
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

                    Text("支持 `{word}`、`{context}`、`{target_language}` 等占位符，修改会立即保存。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            }
        }
    }

    private var apiConfigurationStatus: (value: String, detail: String, state: StatusState) {
        let endpointOK = EndpointResolver.chatCompletionsURL(baseURL: endpoint) != nil
        let apiKeyOK = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modelOK = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard endpointOK else {
            return ("服务地址无效", "请填写 https:// 开头的兼容接口", .bad)
        }
        guard apiKeyOK else {
            return ("缺少 API Key", "填写后才能请求模型", .warning)
        }
        guard modelOK else {
            return ("缺少模型名", "请填写可用模型", .warning)
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
        permissionGranted = PermissionHelper.accessibilityTrusted
        selfCheckResult = onSelfCheck()
    }

    private func runSelfCheck() {
        refreshStatuses()
        showSelfCheckResult = true
    }

    private func triggerTranslateUnderCursor() {
        refreshStatuses()
        connectionResult = permissionGranted
            ? "已请求翻译光标下文本。请查看光标附近的弹窗。"
            : "需要辅助功能权限。点击“打开辅助功能设置”授权 MacScreenTrans 后重启应用。"
        onTranslateUnderCursor()
    }

    private func testConnection() {
        guard !isTestingConnection else { return }

        let config = TranslationConfig(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            targetLanguage: targetLanguage,
            promptTemplate: promptTemplate
        )

        guard EndpointResolver.chatCompletionsURL(baseURL: config.endpoint) != nil else {
            connectionResult = "服务地址无效。请检查是否为 https:// 开头的 OpenAI 兼容接口地址。"
            return
        }
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connectionResult = "缺少 API Key。填写后再测试连接。"
            return
        }
        guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connectionResult = "缺少模型名。请填写一个可用模型。"
            return
        }

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
        case .missingAPIKey:
            return "缺少 API Key。"
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

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusTile: View {
    let title: String
    let value: String
    let detail: String
    let state: StatusState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(state.color)
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.headline)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(state.color.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(state.color.opacity(0.22))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
}
