import Foundation

public struct ThreeFingerTapDetector {
    public var maximumTapDuration: TimeInterval
    public var debounceInterval: TimeInterval

    private var activeTouchStartedAt: TimeInterval?
    private var peakContactCount: Int32 = 0
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
        // MultitouchSupport reports per-finger frames; a realistic three-finger tap
        // looks like 0 → 1 → 2 → 3 → 2 → 1 → 0 because fingers never land and lift
        // perfectly in sync. Track the peak contact count during an active touch
        // and only resolve the gesture when fully released (contactCount == 0).
        if contactCount > 0 {
            if activeTouchStartedAt == nil {
                activeTouchStartedAt = timestamp
            }
            if contactCount > peakContactCount {
                peakContactCount = contactCount
            }
            return
        }

        guard let startedAt = activeTouchStartedAt else { return }
        let peak = peakContactCount
        activeTouchStartedAt = nil
        peakContactCount = 0

        guard peak == 3 else { return }

        let duration = timestamp - startedAt
        guard duration >= 0, duration <= maximumTapDuration else { return }

        if let lastRecognizedAt, timestamp - lastRecognizedAt < debounceInterval {
            return
        }
        lastRecognizedAt = timestamp
        onTap()
    }
}
