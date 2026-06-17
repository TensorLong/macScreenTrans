import CMultitouchSupport
import Foundation
import MacScreenTransCore

final class TrackpadTapMonitor: @unchecked Sendable {
    var onTap: (() -> Void)?

    private let queue = DispatchQueue(label: "MacScreenTrans.TrackpadTapMonitor")
    /// One detector per multitouch device. Frames from a built-in trackpad
    /// and an external surface must never interleave into one gesture
    /// state: a hand resting on the other device would hold the gesture
    /// "active" for minutes and every real tap would be rejected with
    /// "duration > max".
    private var detectors: [UInt64: ThreeFingerTapDetector] = [:]
    private(set) var isRunning = false
    private(set) var lastError: String?

    /// Diagnostic surface: the per-device detectors' last-rejection strings,
    /// read across the queue boundary. Used by the settings self-check
    /// report so the user can see why a 3-finger gesture they just performed
    /// didn't fire instead of having to ask the QA (us) to read source.
    var lastRejection: String {
        queue.sync {
            let rejections = detectors.values.map(\.lastRejection).filter { $0 != "(none)" }
            return rejections.isEmpty ? "(none)" : rejections.joined(separator: " | ")
        }
    }

    func start() {
        guard !isRunning else { return }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let ok = errorBuffer.withUnsafeMutableBufferPointer { buffer in
            MSTrackpadStart(
                TrackpadTapMonitor.touchCallback,
                Unmanaged.passUnretained(self).toOpaque(),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }

        isRunning = ok
        let messageBytes = errorBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        lastError = ok ? nil : String(decoding: messageBytes, as: UTF8.self)
    }

    func stop() {
        guard isRunning else { return }
        MSTrackpadStop()
        isRunning = false
        queue.async { [weak self] in
            self?.detectors.removeAll()
        }
    }

    /// Tears the multitouch registration down and stands it back up so we
    /// get fresh device handles. MultitouchSupport invalidates the
    /// MTDeviceRef handles we registered when the machine sleeps; after wake
    /// the OS delivers no frames to the stale handles, so the monitor goes
    /// deaf while `isRunning` still reads true. Re-registering is the only
    /// recovery short of relaunching the app.
    func restart() {
        stop()
        start()
    }

    deinit {
        stop()
    }

    private func makeDetector() -> ThreeFingerTapDetector {
        ThreeFingerTapDetector { [weak self] in
            // Hoist `onTap` out of `self` before hopping to the main queue so
            // the escaping closure sends a captured function value, not the
            // monitor itself, across the concurrency boundary (Swift 6).
            guard let onTap = self?.onTap else { return }
            DispatchQueue.main.async {
                onTap()
            }
        }
    }

    private func process(
        deviceID: UInt64,
        contactCount: Int32,
        timestamp: TimeInterval,
        centroidX: Float,
        centroidY: Float
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            var detector = self.detectors[deviceID] ?? self.makeDetector()
            detector.process(
                contactCount: contactCount,
                timestamp: timestamp,
                centroidX: centroidX,
                centroidY: centroidY
            )
            self.detectors[deviceID] = detector
        }
    }

    private static let touchCallback: MSTouchFrameCallback = { deviceID, contactCount, timestamp, _, centroidX, centroidY, context in
        guard let context else { return }
        let monitor = Unmanaged<TrackpadTapMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.process(
            deviceID: deviceID,
            contactCount: contactCount,
            timestamp: timestamp,
            centroidX: centroidX,
            centroidY: centroidY
        )
    }
}
