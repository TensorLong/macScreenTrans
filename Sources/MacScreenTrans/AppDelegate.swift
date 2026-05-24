import AppKit
import MacScreenTransCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let trackpadMonitor = TrackpadTapMonitor()
    private let client = OpenAIStreamingClient()
    private let translateNotificationName = Notification.Name("com.longmac.MacScreenTrans.translateUnderCursor")
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?
    private var streamingTask: Task<Void, Never>?
    private lazy var popup = FloatingTranslationWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConfiguration.bootstrapDefaults()
        configureApplicationMenu()
        configureStatusItem()

        settingsWindow = SettingsWindowController { [weak self] in
            self?.selfCheckReport() ?? "Self-check unavailable"
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(translateUnderCursor),
            name: translateNotificationName,
            object: nil
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
        DistributedNotificationCenter.default().removeObserver(self, name: translateNotificationName, object: nil)
        trackpadMonitor.stop()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = "译"
        statusItem?.button?.toolTip = "MacScreenTrans"

        let menu = NSMenu()
        menu.addItem(menuItem("Translate Under Cursor", action: #selector(translateUnderCursor), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(menuItem("Permission Self-Check", action: #selector(runSelfCheck), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Start Listening", action: #selector(startListening), keyEquivalent: ""))
        menu.addItem(menuItem("Stop Listening", action: #selector(stopListening), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(menuItem("Settings...", action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Quit MacScreenTrans", action: #selector(quit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
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
    }

    @objc private func stopListening() {
        trackpadMonitor.stop()
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
            popup.update("需要辅助功能权限后才能通过 Accessibility API 取词。")
            return
        }

        guard let selection = AXWordReader.selection(at: point) else {
            popup.update("当前位置不支持取词")
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
                        popup.update(output.isEmpty ? "等待模型输出..." : SenseGroupResponseRenderer.displayText(for: output))
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
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    popup.update("请求失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func selfCheckReport() -> String {
        let config = AppConfiguration.current
        let endpointOK = EndpointResolver.chatCompletionsURL(baseURL: config.endpoint) != nil
        let apiKeyOK = !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modelOK = !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let trackpadStatus = trackpadMonitor.isRunning
            ? "running"
            : "stopped\(trackpadMonitor.lastError.map { ": \($0)" } ?? "")"

        return """
        Accessibility: \(PermissionHelper.accessibilityTrusted ? "trusted" : "not trusted")
        Trackpad tap monitor: \(trackpadStatus)
        Endpoint: \(endpointOK ? "ok" : "invalid")
        API key: \(apiKeyOK ? "configured" : "missing")
        Model: \(modelOK ? "configured" : "missing")
        Target language: \(config.targetLanguage)
        """
    }
}
