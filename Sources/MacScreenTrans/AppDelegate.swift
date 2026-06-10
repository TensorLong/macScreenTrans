import AppKit
import MacScreenTransCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let trackpadMonitor = TrackpadTapMonitor()
    private let client = OpenAIStreamingClient()
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var settingsWindow: SettingsWindowController?
    private var streamingTask: Task<Void, Never>?
    /// Monotonic token for the tap → resolve → stream pipeline. Every UI
    /// write from an async continuation re-checks it, so a superseded tap
    /// (or a popup the user already closed) can never repaint the popup or
    /// resurrect stale overlays. Cancellation alone is not enough:
    /// AsyncThrowingStream ends with nil instead of throwing when its
    /// consumer task is cancelled, so the post-stream code keeps running.
    private var tapGeneration = 0
    /// True while an OCR resolve is in flight; taps arriving meanwhile are
    /// dropped instead of queueing (a queued tap would re-read the cursor
    /// position later and OCR wherever it drifted to).
    private var resolveInFlight = false
    /// Set when the user scrolls while the popup is up: the content under
    /// the highlights moved, so this tap's OCR geometry is stale. The
    /// overlays are hidden immediately and must not reappear for this
    /// generation (the still-streaming task would otherwise paint the green
    /// phrase at the old coordinates when the LLM answers). The popup itself
    /// survives — the user may be scrolling elsewhere to cross-reference.
    private var scrolledSinceTap = false
    private lazy var popup: FloatingTranslationWindowController = {
        let controller = FloatingTranslationWindowController()
        controller.setOnClose { [weak self] in
            guard let self else { return }
            // Closing the popup invalidates the in-flight pipeline —
            // otherwise a still-streaming task would resurrect the overlays
            // (or repaint the popup) seconds after the user dismissed it.
            self.tapGeneration += 1
            self.streamingTask?.cancel()
            self.streamingTask = nil
            self.highlightOverlay.hide()
            self.phraseOverlay.hide()
        }
        controller.setOnScrollAway { [weak self] in
            guard let self else { return }
            self.scrolledSinceTap = true
            self.highlightOverlay.hide()
            self.phraseOverlay.hide()
        }
        return controller
    }()
    private lazy var highlightOverlay = WordHighlightOverlayController()
    private lazy var phraseOverlay = PhraseHighlightOverlayController()
    private lazy var shortcutMonitor = GlobalShortcutMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConfiguration.bootstrapDefaults()
        configureApplicationMenu()
        configureStatusItem()

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

        shortcutMonitor.start { [weak self] in
            Task { @MainActor in
                self?.handleThreeFingerTap()
            }
        }

        settingsWindow?.show()
        if !PermissionHelper.screenRecordingGranted || !AppConfiguration.hasMinimumLLMConfig {
            PermissionHelper.requestScreenRecording()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        streamingTask?.cancel()
        trackpadMonitor.stop()
        shortcutMonitor.stop()
    }

    private func configureStatusItem() {
        // Don't set autosaveName: Hidden Bar / Bartender-style utilities can
        // pin the status item to a collapsed zone permanently.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.title = "译"
            button.image = nil
            button.imagePosition = .noImage
            button.font = .systemFont(ofSize: 15, weight: .semibold)
            button.toolTip = "MacScreenTrans"
            button.setAccessibilityLabel("MacScreenTrans 菜单栏图标")
            button.setAccessibilityHelp("点击打开设置和翻译菜单")
        }
        statusItem = item
        statusMenu.delegate = self
        rebuildStatusMenu()
        statusItem?.menu = statusMenu
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let translateItem = menuItem("翻译光标下文本", action: #selector(translateUnderCursor), keyEquivalent: "t")
        translateItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(translateItem)
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
        statusMenu.addItem(disabledMenuItem("MacScreenTrans v\(AppConfiguration.appVersion)"))
        statusMenu.addItem(.separator())
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
        // Click-driven triggers (menu item, settings button) leave the
        // cursor on the control that was clicked — sampling mouseLocation
        // immediately would OCR the menu bar or the settings window. Give
        // the user a beat to move the cursor onto the target text. The
        // global hotkey path calls handleThreeFingerTap directly because
        // the cursor is already where the user wants it.
        tapGeneration += 1
        let generation = tapGeneration
        popup.show(at: NSEvent.mouseLocation, text: "请在 2 秒内把鼠标移到要翻译的文字上...")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.tapGeneration == generation else { return }
            self.handleThreeFingerTap()
        }
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
        // Drop taps while a resolve is still running: a queued tap would
        // re-read the cursor later and OCR wherever it drifted to.
        guard !resolveInFlight else { return }

        tapGeneration += 1
        let generation = tapGeneration
        scrolledSinceTap = false
        streamingTask?.cancel()
        streamingTask = nil
        highlightOverlay.hide()
        phraseOverlay.hide()
        let point = NSEvent.mouseLocation

        guard PermissionHelper.screenRecordingGranted else {
            PermissionHelper.requestScreenRecording()
            popup.show(
                at: point,
                text: "需要屏幕录制权限。\n请打开设置页，点击“打开屏幕录制设置”，允许 MacScreenTrans 后重启应用。"
            )
            return
        }

        // Immediate feedback at the cursor; OCR runs off the main thread and
        // the popup re-anchors once the word geometry is known.
        popup.show(at: point, text: "取词中...")

        resolveInFlight = true
        Task { @MainActor in
            // No AX role gate any more: the OCR reader IS the text detector.
            // When the tap doesn't land on a recognized word, `resolve`
            // returns nil with a populated diagnostic, and we show the same
            // compact popup (no LLM round-trip) the role gate used to.
            let result = await OCRWordReader.resolve(at: point)
            self.resolveInFlight = false
            guard self.tapGeneration == generation else { return }
            guard let result else {
                self.popup.show(
                    at: point,
                    text: """
                    当前位置未识别到文字。
                    请把鼠标放在屏幕上清晰可见的文字上再试。

                    — OCR 诊断（v\(AppConfiguration.appVersion) debug）—
                    \(OCRWordReader.lastDiagnostic)
                    """
                )
                return
            }
            self.startTranslation(for: result, generation: generation)
        }
    }

    private func startTranslation(for result: OCRWordReader.Result, generation: Int) {
        let selection = result.selection

        // Re-anchor the popup to the recognized word's screen rect when OCR
        // gives us bounds. Otherwise it stays at the cursor — this still
        // happens for image PDFs / custom UIs that don't report bounds.
        // A scroll during the resolve means the word is no longer at that
        // rect: skip both the highlight and the re-anchor (the popup stays
        // at the cursor, which is still where the user is looking).
        if let wordRect = result.wordRect, !scrolledSinceTap {
            highlightOverlay.show(at: wordRect)
            popup.show(anchoredTo: wordRect, text: "取词中...")
        }

        let config = AppConfiguration.current
        popup.update("正在解释：\(selection.word)\n\n")
        let lookupBox = PhraseLookupBox(result: result)
        // Compute the 3-word verbatim position string once per resolve.
        // It accompanies the LLM payload AND drives the new range-anchor
        // localisation in OCRWordReader.phraseSegments — the cursor anchor
        // expands from a single-word range to a 3-word neighbourhood, so
        // any reasonable source_chunk that overlaps the neighbourhood
        // passes cover. Wraps duplicate-word sentences where the LLM picks
        // the right occurrence but the old single-word anchor was too
        // narrow to recognise it.
        let positionString = PromptBuilder.position(for: selection)
        streamingTask = Task { @MainActor in
            // A UI write is allowed only while this tap is still the active
            // generation AND nobody cancelled us. The generation is the
            // load-bearing check: the stream iterator ends with nil instead
            // of throwing when its consumer task is cancelled, so execution
            // reaches the post-stream branches even after a cancel().
            @MainActor func stillCurrent() -> Bool {
                self.tapGeneration == generation && !Task.isCancelled
            }
            do {
                var output = ""
                for try await delta in self.client.streamExplanation(selection: selection, config: config) {
                    output += delta
                    guard stillCurrent() else { return }
                    self.popup.update(SenseGroupResponseRenderer.displayText(
                        for: output.isEmpty ? "正在识别意群..." : output,
                        overrideWord: selection.word
                    ))
                }
                guard stillCurrent() else { return }
                if output.isEmpty {
                    self.popup.update("模型没有返回内容。")
                } else if let response = SenseGroupResponseRenderer.response(for: output) {
                    // Reveal the green phrase overlay as soon as the LLM gives
                    // us a usable source phrase, regardless of whether we'll
                    // later fall through to the translation-only fallback.
                    // Per-line segments come from OCRWordReader.phraseSegments.
                    // The overlay is a translucent tint over the real glyphs,
                    // so no font is needed — the box size is all that matters.
                    if !response.source.isEmpty, !self.scrolledSinceTap {
                        let phrase = response.source
                        let segs = lookupBox.result.phraseSegments(for: phrase, positionString: positionString)
                        if !segs.isEmpty {
                            self.phraseOverlay.show(segments: segs)

                            // Option B: yellow word box was missing because
                            // the OCR word range carried no geometry (soft-
                            // wrap / zero-width-space / odd web glyph). When
                            // green segments DID resolve, slice the matching
                            // segment proportionally to land yellow on the
                            // word visually. We pass the cursor anchor so a
                            // sentence with two of the same word still gets
                            // yellow on the occurrence the user pointed at.
                            if lookupBox.result.wordRect == nil,
                               let derivedRect = Self.deriveWordRectFromSegments(
                                segments: segs,
                                clickedWordRange: lookupBox.result.clickedWordRangeInLookupText
                               ) {
                                self.highlightOverlay.show(at: derivedRect)
                            }
                        }
                    }
                    if SenseGroupResponseRenderer.needsTranslationFallback(
                        response,
                        targetLanguage: config.targetLanguage
                    ) {
                        let fallbackSource = response.source.isEmpty ? selection.word : response.source
                        self.popup.update("单词: \(selection.word)\n意群: \(fallbackSource)\n译文: 正在补译...")
                        let fallbackSelection = WordSelection(
                            word: fallbackSource,
                            context: fallbackSource,
                            wordRangeInContext: 0..<fallbackSource.utf16.count
                        )
                        var fallbackConfig = config
                        fallbackConfig.promptTemplate = PromptBuilder.translationOnlyPromptTemplate
                        var fallbackOutput = ""
                        for try await delta in self.client.streamExplanation(selection: fallbackSelection, config: fallbackConfig) {
                            fallbackOutput += delta
                            guard stillCurrent() else { return }
                            let target = SenseGroupResponseRenderer.plainTranslationText(for: fallbackOutput)
                            self.popup.update("单词: \(selection.word)\n意群: \(fallbackSource)\n译文: \(target.isEmpty ? "正在补译..." : target)")
                        }
                        guard stillCurrent() else { return }
                        let finalTarget = SenseGroupResponseRenderer.plainTranslationText(for: fallbackOutput)
                        self.popup.update(
                            "单词: \(selection.word)\n意群: \(fallbackSource)\n译文: \(finalTarget.isEmpty ? "模型没有返回译文，请重试。" : finalTarget)"
                        )
                    } else {
                        self.popup.update(SenseGroupResponseRenderer.displayText(for: output, overrideWord: selection.word))
                    }
                } else {
                    // The model ignored the JSON contract — pure machine-
                    // translation models do. The raw text is almost always
                    // the translation itself, so show it instead of
                    // discarding the answer behind a format error.
                    let plain = SenseGroupResponseRenderer.plainTranslationText(for: output)
                    self.popup.update("单词: \(selection.word)\n译文: \(plain)")
                }
            } catch is CancellationError {
            } catch {
                guard stillCurrent() else { return }
                self.popup.update(Self.friendlyErrorMessage(for: error))
            }
        }
    }

    /// Belt-and-suspenders for Issue 3: when the AX layer failed to give us
    /// a word rect (soft wrap, zero-width-space glyphs, odd web glyphs),
    /// but the green phrase segments DID resolve — pick the segment whose
    /// UTF-16 range covers the cursor anchor, then proportionally slice
    /// that segment's rect using the anchor's offset inside the segment.
    /// The slicing is offset-based (not substring-based) so a sentence
    /// like "set the timer and set the alarm" puts yellow on whichever
    /// "set" the user actually pointed at, instead of always the first
    /// occurrence the old `range(of: word)` shortcut returned.
    private static func deriveWordRectFromSegments(
        segments: [PhraseSegment],
        clickedWordRange: Range<Int>?
    ) -> NSRect? {
        guard let anchor = clickedWordRange, anchor.lowerBound < anchor.upperBound else {
            return nil
        }

        guard let seg = segments.first(where: {
            $0.rangeInElementText.lowerBound <= anchor.lowerBound
                && $0.rangeInElementText.upperBound >= anchor.upperBound
        }) else { return nil }

        let segSpan = seg.rangeInElementText.upperBound - seg.rangeInElementText.lowerBound
        guard segSpan > 0 else { return nil }

        let relStart = CGFloat(anchor.lowerBound - seg.rangeInElementText.lowerBound) / CGFloat(segSpan)
        let relEnd = CGFloat(anchor.upperBound - seg.rangeInElementText.lowerBound) / CGFloat(segSpan)
        return NSRect(
            x: seg.rect.minX + seg.rect.width * relStart,
            y: seg.rect.minY,
            width: seg.rect.width * (relEnd - relStart),
            height: seg.rect.height
        )
    }

    private static func friendlyErrorMessage(for error: Error) -> String {
        guard let streamingError = error as? OpenAIStreamingError else {
            return "请求失败：\(error.localizedDescription)"
        }

        switch streamingError {
        case let .serverError(message):
            return "服务端返回错误：\(message)\n请检查模型名和服务状态后重试。"
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
        let apiKeyStatus = apiKeyOK ? "已配置" : "未填写（本地服务可留空）"
        let trackpadStatus = trackpadMonitor.isRunning
            ? "运行中"
            : "未运行\(trackpadMonitor.lastError.map { ": \($0)" } ?? "")"

        return """
        屏幕录制权限：\(PermissionHelper.screenRecordingGranted ? "已授权" : "未授权")
        三指轻点监听：\(trackpadStatus)
        Endpoint：\(endpointOK ? "正常" : "无效")
        API Key：\(apiKeyStatus)
        Model：\(modelOK ? "已配置" : "缺失")
        目标语言：\(config.targetLanguage)
        最近一次手势判定：\(trackpadMonitor.lastRejection)
        """
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu()
    }
}

/// Carries an `OCRWordReader.Result` into the streaming Task. The OCR result
/// is a pure value type (text, ranges, screen rects) with no Accessibility
/// element handles, so it is genuinely `Sendable` — no unchecked override
/// needed.
private struct PhraseLookupBox: Sendable {
    let result: OCRWordReader.Result
}
