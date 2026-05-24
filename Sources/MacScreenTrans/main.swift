import AppKit

if CommandLine.arguments.contains("--self-test") {
    SelfTest.run()
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
