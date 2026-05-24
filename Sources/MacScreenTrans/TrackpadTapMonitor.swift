import CMultitouchSupport
import Foundation
import MacScreenTransCore

final class TrackpadTapMonitor: @unchecked Sendable {
    var onTap: (() -> Void)?

    private let queue = DispatchQueue(label: "MacScreenTrans.TrackpadTapMonitor")
    private var detector: ThreeFingerTapDetector
    private(set) var isRunning = false
    private(set) var lastError: String?

    init() {
        detector = ThreeFingerTapDetector {}
        detector = ThreeFingerTapDetector { [weak self] in
            DispatchQueue.main.async {
                self?.onTap?()
            }
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
    }

    deinit {
        stop()
    }

    private func process(
        contactCount: Int32,
        timestamp: TimeInterval,
        centroidX: Float,
        centroidY: Float
    ) {
        queue.async { [weak self] in
            self?.detector.process(
                contactCount: contactCount,
                timestamp: timestamp,
                centroidX: centroidX,
                centroidY: centroidY
            )
        }
    }

    private static let touchCallback: MSTouchFrameCallback = { contactCount, timestamp, _, centroidX, centroidY, context in
        guard let context else { return }
        let monitor = Unmanaged<TrackpadTapMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.process(
            contactCount: contactCount,
            timestamp: timestamp,
            centroidX: centroidX,
            centroidY: centroidY
        )
    }
}
