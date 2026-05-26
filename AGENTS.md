# AGENTS.md

## Tooling Contract

- For Apple-platform build, test, run, debug, simulator, or Xcode project work, use the installed `xcodebuildmcp` skill before calling XcodeBuildMCP tools.
- Prefer XcodeBuildMCP MCP tools over raw `xcodebuild`, `xcrun`, or `simctl` when the MCP is available. If the current Codex session has not loaded newly added MCP tools yet, use the installed `xcodebuildmcp` CLI as the fallback and say so in the report.
- Before the first XcodeBuildMCP build, run, or test action in a session, call `session_show_defaults`. Run project discovery only when defaults are missing or wrong.
- This repo is a SwiftPM macOS app. Start regression verification with `scripts/test`, then use XcodeBuildMCP `swift-package` or `macos` workflows for build/run/toolchain checks.
- UI claims must be visually verified. Use Computer Use, screenshots, or screen capture for status bar icons, windows, popovers, permissions, and translation output. Do not claim a UI is visible or usable from logs, process state, or accessibility metadata alone.
- For SwiftUI/AppKit UI work, use the installed `swiftui-pro` skill when relevant and preserve existing app design patterns.
- For OpenAI/Codex/API behavior, use the OpenAI Developer Docs MCP or official OpenAI docs. For current third-party framework docs, use Context7 before relying on memory.
- Never commit real API keys or secrets. Use environment variables, local settings, or masked placeholders.
