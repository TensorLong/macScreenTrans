import AppKit
import MacScreenTransCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let trackpadMonitor = TrackpadTapMonitor()
    private let client = OpenAIStreamingClient()
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var menuBarBadge: MenuBarBadgeWindowController?
    private var settingsWindow: SettingsWindowController?
    private var streamingTask: Task<Void, Never>?
    private lazy var popup = FloatingTranslationWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConfiguration.bootstrapDefaults()
        configureApplicationMenu()
        configureStatusItem()
        menuBarBadge = MenuBarBadgeWindowController(menu: statusMenu)
        menuBarBadge?.show()

        settingsWindow = SettingsWindowController(
            onSelfCheck: { [weak self] in
                self?.selfCheckReport() ?? "Self-check unavailable"
            },
            onTranslateUnderCursor: { [weak self] in
                self?.handleThreeFingerTap()
            }
        )

        trackpadMonitor.onTap = { [weak self] in
            Task { @MainActor in
                self?.handleThreeFingerTap()
            }
        }
        trackpadMonitor.start()

        settingsWindow?.show()
        if !PermissionHelper.accessibilityTrusted || !AppConfiguration.hasMinimumLLMConfig {
            PermissionHelper.promptForAccessibility()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        streamingTask?.cancel()
        trackpadMonitor.stop()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 92)
        statusItem?.button?.image = StatusBarIcon.makeBadge()
        statusItem?.button?.title = " 译 Trans"
        statusItem?.button?.imagePosition = .imageLeft
        statusItem?.button?.font = .systemFont(ofSize: 13, weight: .semibold)
        statusItem?.button?.toolTip = "MacScreenTrans - 点击打开设置和翻译菜单"
        statusItem?.button?.setAccessibilityLabel("MacScreenTrans menu bar item")
        statusItem?.button?.setAccessibilityHelp("菜单栏应显示为蓝色译图标和 Trans 文字")
        statusMenu.delegate = self
        rebuildStatusMenu()
        statusItem?.menu = statusMenu
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(menuItem("翻译光标下文本", action: #selector(translateUnderCursor), keyEquivalent: "t"))
        appMenu.addItem(menuItem("权限自检", action: #selector(runSelfCheck), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("设置...", action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("退出 MacScreenTrans", action: #selector(quit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()
        statusMenu.addItem(disabledMenuItem(trackpadMonitor.isRunning ? "监听：开启" : "监听：关闭"))
        statusMenu.addItem(menuItem("翻译光标下文本", action: #selector(translateUnderCursor), keyEquivalent: ""))
        statusMenu.addItem(.separator())
        statusMenu.addItem(menuItem("设置...", action: #selector(showSettings), keyEquivalent: ","))
        statusMenu.addItem(menuItem("权限自检", action: #selector(runSelfCheck), keyEquivalent: ""))
        statusMenu.addItem(.separator())

        if trackpadMonitor.isRunning {
            statusMenu.addItem(menuItem("停止监听", action: #selector(stopListening), keyEquivalent: ""))
        } else {
            statusMenu.addItem(menuItem("开始监听", action: #selector(startListening), keyEquivalent: ""))
        }

        statusMenu.addItem(.separator())
        statusMenu.addItem(menuItem("退出", action: #selector(quit), keyEquivalent: "q"))
    }

    @objc private func showSettings() {
        settingsWindow?.show()
    }

    @objc private func runSelfCheck() {
        popup.show(at: NSEvent.mouseLocation, text: selfCheckReport())
    }

    @objc private func translateUnderCursor() {
        handleThreeFingerTap()
    }

    @objc private func startListening() {
        trackpadMonitor.start()
        rebuildStatusMenu()
    }

    @objc private func stopListening() {
        trackpadMonitor.stop()
        rebuildStatusMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleThreeFingerTap() {
        streamingTask?.cancel()
        let point = NSEvent.mouseLocation
        popup.show(at: point, text: "取词中...")

        guard PermissionHelper.accessibilityTrusted else {
            PermissionHelper.promptForAccessibility()
            popup.update("需要辅助功能权限。\n请打开设置页，点击“打开辅助功能设置”，允许 MacScreenTrans 后重启应用。")
            return
        }

        guard let selection = AXWordReader.selection(at: point) else {
            popup.update("当前位置不支持取词。\n请把鼠标放在可选择的正文或输入框文字上再试。图片、部分 PDF 或自绘界面可能不支持。")
            return
        }

        let config = AppConfiguration.current
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            popup.update("请先在设置里配置 API key。")
            settingsWindow?.show()
            return
        }

        popup.update("正在解释：\(selection.word)\n\n")
        streamingTask = Task { [client, popup] in
            do {
                var output = ""
                for try await delta in client.streamExplanation(selection: selection, config: config) {
                    output += delta
                    await MainActor.run {
                        popup.update(SenseGroupResponseRenderer.displayText(for: output.isEmpty ? "正在识别意群..." : output))
                    }
                }
                if output.isEmpty {
                    await MainActor.run {
                        popup.update("模型没有返回内容。")
                    }
                } else if let response = SenseGroupResponseRenderer.response(for: output),
                          response.hasSource,
                          !response.hasTarget {
                    await MainActor.run {
                        popup.update("意群: \(response.source)\n释义: 正在补译...")
                    }
                    let fallbackSelection = WordSelection(
                        word: response.source,
                        context: response.source,
                        wordRangeInContext: 0..<response.source.utf16.count
                    )
                    var fallbackConfig = config
                    fallbackConfig.promptTemplate = PromptBuilder.translationOnlyPromptTemplate
                    var fallbackOutput = ""
                    for try await delta in client.streamExplanation(selection: fallbackSelection, config: fallbackConfig) {
                        fallbackOutput += delta
                        await MainActor.run {
                            let target = fallbackOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                            popup.update("意群: \(response.source)\n释义: \(target.isEmpty ? "正在补译..." : target)")
                        }
                    }
                    if fallbackOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await MainActor.run {
                            popup.update("意群: \(response.source)\n释义: 模型没有返回译文，请重试。")
                        }
                    }
                } else if SenseGroupResponseRenderer.isLikelyStructuredResponse(output),
                          SenseGroupResponseRenderer.response(for: output) == nil {
                    await MainActor.run {
                        popup.update("模型返回格式不完整。\n请在设置页点击“恢复默认”后重试，或换一个模型。")
                    }
                } else if SenseGroupResponseRenderer.response(for: output) == nil {
                    await MainActor.run {
                        popup.update("模型没有按要求返回译文 JSON。\n请在设置页点击“恢复默认”后重试，或换一个模型。")
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    popup.update(Self.friendlyErrorMessage(for: error))
                }
            }
        }
    }

    private static func friendlyErrorMessage(for error: Error) -> String {
        guard let streamingError = error as? OpenAIStreamingError else {
            return "请求失败：\(error.localizedDescription)"
        }

        switch streamingError {
        case .missingAPIKey:
            return "缺少 API Key。\n请在设置页填写 OpenRouter 或 OpenAI-compatible API key。"
        case .invalidEndpoint:
            return "Endpoint URL 无效。\n请检查设置页中的 API URL，例如 https://openrouter.ai/api/v1。"
        case .invalidHTTPResponse:
            return "API 返回了无效响应。\n请稍后重试或检查 Endpoint。"
        case let .httpFailure(status, _):
            let hint: String
            switch status {
            case 400:
                hint = "请求参数或模型名不兼容。"
            case 401, 403:
                hint = "API Key 无效或没有权限。"
            case 429:
                hint = "请求过于频繁或额度不足。"
            case 500...599:
                hint = "服务端暂时不可用。"
            default:
                hint = "HTTP \(status)。"
            }
            return "请求失败：\(hint)\n请检查设置页中的服务地址、API Key 和模型名。"
        }
    }

    private func selfCheckReport() -> String {
        let config = AppConfiguration.current
        let endpointOK = EndpointResolver.chatCompletionsURL(baseURL: config.endpoint) != nil
        let apiKeyOK = !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modelOK = !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let trackpadStatus = trackpadMonitor.isRunning
            ? "运行中"
            : "未运行\(trackpadMonitor.lastError.map { ": \($0)" } ?? "")"

        return """
        辅助功能权限：\(PermissionHelper.accessibilityTrusted ? "已授权" : "未授权")
        三指轻点监听：\(trackpadStatus)
        Endpoint：\(endpointOK ? "正常" : "无效")
        API Key：\(apiKeyOK ? "已配置" : "缺失")
        Model：\(modelOK ? "已配置" : "缺失")
        目标语言：\(config.targetLanguage)
        """
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu()
    }
}
