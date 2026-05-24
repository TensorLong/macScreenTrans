import AppKit
import MacScreenTransCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(onSelfCheck: @escaping () -> String) {
        let view = SettingsView(onSelfCheck: onSelfCheck)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
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
    @AppStorage(DefaultsKey.model) private var model = "gpt-4o-mini"
    @AppStorage(DefaultsKey.targetLanguage) private var targetLanguage = "zh"
    @AppStorage(DefaultsKey.promptTemplate) private var promptTemplate = PromptBuilder.defaultPromptTemplate

    let onSelfCheck: () -> String
    @State private var selfCheckResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("MacScreenTrans")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Endpoint")
                    TextField("", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("API Key")
                    SecureField("", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Model")
                    TextField("", text: $model)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Target")
                    TextField("", text: $targetLanguage)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Prompt")
                        .font(.headline)
                    Spacer()
                    Button("Reset") {
                        promptTemplate = PromptBuilder.defaultPromptTemplate
                    }
                }
                TextEditor(text: $promptTemplate)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
            }

            HStack {
                Button("Permission Self-Check") {
                    selfCheckResult = onSelfCheck()
                }
                Button("Open Accessibility Settings") {
                    PermissionHelper.openAccessibilitySettings()
                }
                Spacer()
                Text("Menu bar item: 译")
                    .foregroundStyle(.secondary)
            }

            if !selfCheckResult.isEmpty {
                Text(selfCheckResult)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 560)
    }
}
