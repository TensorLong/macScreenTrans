import Foundation

public struct ThreeFingerTapDetector {
    public var maximumTapDuration: TimeInterval
    public var minimumTapDuration: TimeInterval
    public var maximumDrift: Float
    public var debounceInterval: TimeInterval

    private var activeTouchStartedAt: TimeInterval?
    private var peakContactCount: Int32 = 0
    private var startCentroid: (x: Float, y: Float)?
    private var recordedMaxDrift: Float = 0
    private var lastRecognizedAt: TimeInterval?
    private let onTap: () -> Void

    public init(
        maximumTapDuration: TimeInterval = 0.28,
        minimumTapDuration: TimeInterval = 0.02,
        maximumDrift: Float = 0.05,
        debounceInterval: TimeInterval = 0.35,
        onTap: @escaping () -> Void
    ) {
        self.maximumTapDuration = maximumTapDuration
        self.minimumTapDuration = minimumTapDuration
        self.maximumDrift = maximumDrift
        self.debounceInterval = debounceInterval
        self.onTap = onTap
    }

    public mutating func process(
        contactCount: Int32,
        timestamp: TimeInterval,
        centroidX: Float,
        centroidY: Float
    ) {
        // MultitouchSupport reports per-finger frames; a realistic three-finger tap
        // looks like 0 → 1 → 2 → 3 → 2 → 1 → 0 because fingers never land and lift
        // perfectly in sync. Track the peak contact count during an active touch
        // and only resolve the gesture when fully released (contactCount == 0).
        if contactCount > 0 {
            if activeTouchStartedAt == nil {
                activeTouchStartedAt = timestamp
                startCentroid = (centroidX, centroidY)
                recordedMaxDrift = 0
            } else if let start = startCentroid {
                let dx = centroidX - start.x
                let dy = centroidY - start.y
                let drift = (dx * dx + dy * dy).squareRoot()
                if drift > recordedMaxDrift {
                    recordedMaxDrift = drift
                }
            }
            if contactCount > peakContactCount {
                peakContactCount = contactCount
            }
            return
        }

        guard let startedAt = activeTouchStartedAt else { return }
        let peak = peakContactCount
        let drift = recordedMaxDrift
        activeTouchStartedAt = nil
        peakContactCount = 0
        startCentroid = nil
        recordedMaxDrift = 0

        guard peak == 3 else { return }

        let duration = timestamp - startedAt
        guard duration >= minimumTapDuration, duration <= maximumTapDuration else { return }

        // Real taps stay anchored — fingers don't slide. A system three-finger
        // swipe (Mission Control, desktop switching, etc.) accumulates drift.
        guard drift <= maximumDrift else { return }

        if let lastRecognizedAt, timestamp - lastRecognizedAt < debounceInterval {
            return
        }
        lastRecognizedAt = timestamp
        onTap()
    }
}
