import AppKit

private let delegate = AppDelegate()

NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
