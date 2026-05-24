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

    /// Diagnostic string describing why the most recently observed tap was
    /// rejected (or "(none — last tap accepted)" if it fired). Surfaced via
    /// the settings self-check report so the user can see why a gesture they
    /// just performed didn't trigger — closes the v0.2.1 visibility gap.
    public private(set) var lastRejection: String = "(none)"

    public init(
        maximumTapDuration: TimeInterval = 0.28,
        minimumTapDuration: TimeInterval = 0.02,
        maximumDrift: Float = 0.08,
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
        // MultitouchSupport reports per-finger frames; a realistic three-finger
        // tap looks like 0 → 1 → 2 → 3 → 2 → 1 → 0 because fingers never land
        // and lift perfectly in sync. Track the peak contact count during an
        // active touch and only resolve the gesture when fully released
        // (contactCount == 0). contactCount here is the *firm* finger count
        // (state ∈ {3, 4}) from MSComputeCentroid — fingers in the lifting
        // state are filtered out at the C layer so they can't bump the peak.
        if contactCount > 0 {
            if activeTouchStartedAt == nil {
                activeTouchStartedAt = timestamp
            }
            if contactCount > peakContactCount {
                peakContactCount = contactCount
            }
            if contactCount >= 3 {
                if startCentroid == nil {
                    // First frame with all three fingers firmly down. Anchor
                    // here — before this point the centroid averages 1 or 2
                    // fingers and reflects nothing meaningful about drift.
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

        guard peak == 3 else {
            lastRejection = "peak=\(peak), expected 3"
            return
        }

        let duration = timestamp - startedAt
        guard duration >= minimumTapDuration else {
            lastRejection = String(format: "duration=%.3fs < min %.3fs", duration, minimumTapDuration)
            return
        }
        guard duration <= maximumTapDuration else {
            lastRejection = String(format: "duration=%.3fs > max %.3fs", duration, maximumTapDuration)
            return
        }

        // Real taps stay anchored — fingers don't slide. A system three-finger
        // swipe (Mission Control, desktop switching, etc.) accumulates drift.
        guard drift <= maximumDrift else {
            lastRejection = String(format: "drift=%.4f > max %.4f", drift, maximumDrift)
            return
        }

        if let lastRecognizedAt, timestamp - lastRecognizedAt < debounceInterval {
            lastRejection = String(format: "debounced %.3fs since last", timestamp - lastRecognizedAt)
            return
        }
        lastRejection = "(none — last tap accepted)"
        lastRecognizedAt = timestamp
        onTap()
    }
}
