import Foundation

public struct ThreeFingerTapDetector {
    public var maximumTapDuration: TimeInterval
    public var debounceInterval: TimeInterval

    private var activeTouchStartedAt: TimeInterval?
    private var lastRecognizedAt: TimeInterval?
    private let onTap: () -> Void

    public init(
        maximumTapDuration: TimeInterval = 0.28,
        debounceInterval: TimeInterval = 0.35,
        onTap: @escaping () -> Void
    ) {
        self.maximumTapDuration = maximumTapDuration
        self.debounceInterval = debounceInterval
        self.onTap = onTap
    }

    public mutating func process(contactCount: Int32, timestamp: TimeInterval) {
        if contactCount == 3 {
            if activeTouchStartedAt == nil {
                activeTouchStartedAt = timestamp
            }
            return
        }

        guard contactCount == 0, let startedAt = activeTouchStartedAt else {
            if contactCount != 3 {
                activeTouchStartedAt = nil
            }
            return
        }
        activeTouchStartedAt = nil

        let duration = timestamp - startedAt
        guard duration >= 0, duration <= maximumTapDuration else { return }
        if let lastRecognizedAt, timestamp - lastRecognizedAt < debounceInterval {
            return
        }

        lastRecognizedAt = timestamp
        onTap()
    }
}
