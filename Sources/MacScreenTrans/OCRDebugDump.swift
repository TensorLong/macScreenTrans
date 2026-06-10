import CoreGraphics
import Foundation
import ImageIO
import MacScreenTransCore
import UniformTypeIdentifiers

/// Per-tap evidence dump: the captured strip PNG, an annotated copy with every
/// recognized box drawn on it, and a text report of the geometry at each
/// pipeline stage. This exists because the on-screen overlays can't be
/// screenshotted while a capture-driven popup is being debugged — the dump IS
/// the ground truth, no screenshot needed.
///
/// Activation (no-op when neither is set):
///   - `MST_DEBUG_DIR=/tmp/mst-dump` in the environment, or
///   - `defaults write <bundle id> MSTDebugDumpDir /tmp/mst-dump`
enum OCRDebugDump {
    /// Set programmatically (the self-test uses this); wins over env/defaults.
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static var directory: URL? {
        if let overrideDirectory { return overrideDirectory }
        if let env = ProcessInfo.processInfo.environment["MST_DEBUG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let path = UserDefaults.standard.string(forKey: "MSTDebugDumpDir"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    /// Monotonic per-process tap counter so consecutive dumps don't collide.
    nonisolated(unsafe) private static var sequence = 0
    private static let sequenceLock = NSLock()

    static func dumpIfEnabled(
        image: CGImage,
        screenFrame: CGRect,
        assembled: AssembledText,
        tapNorm: CGPoint,
        appKitTap: CGPoint,
        report: String
    ) {
        guard let root = directory else { return }

        sequenceLock.lock()
        sequence += 1
        let seq = sequence
        sequenceLock.unlock()

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let folder = root.appendingPathComponent("tap-\(stamp)-\(seq)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return
        }

        writePNG(image, to: folder.appendingPathComponent("strip.png"))
        if let annotated = annotate(image, assembled: assembled, tapNorm: tapNorm) {
            writePNG(annotated, to: folder.appendingPathComponent("annotated.png"))
        }

        var text = """
        appKitTap=\(appKitTap)
        tapNorm=\(tapNorm)
        screenFrame=\(screenFrame)
        imagePx=\(image.width)x\(image.height)

        """
        for (i, line) in assembled.lines.enumerated() {
            let lineScreen = OCRGeometry.screenRect(fromNormalizedTopLeft: line.box, in: screenFrame)
            text += "line[\(i)] range=\(line.range) norm=\(round4(line.box)) screen=\(round1(lineScreen))\n"
            for word in line.words {
                let wordScreen = OCRGeometry.screenRect(fromNormalizedTopLeft: word.box, in: screenFrame)
                text += "  word \"\(word.text)\" range=\(word.range) norm=\(round4(word.box)) screen=\(round1(wordScreen))\n"
            }
        }
        if let box = assembled.tappedWordBox, let range = assembled.tappedWordRange {
            let screen = OCRGeometry.screenRect(fromNormalizedTopLeft: box, in: screenFrame)
            text += "\ntapped range=\(range) norm=\(round4(box)) screen=\(round1(screen))\n"
        } else {
            text += "\ntapped: (none)\n"
        }
        text += "\n--- pipeline diagnostic ---\n\(report)\n"
        try? text.write(
            to: folder.appendingPathComponent("report.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Draw line boxes (blue), word boxes (red), the tapped word box (thick
    /// yellow) and a tap crosshair (green) onto a copy of the strip.
    private static func annotate(
        _ image: CGImage,
        assembled: AssembledText,
        tapNorm: CGPoint
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Normalized top-left box -> CG (bottom-left) pixel rect.
        func pixelRect(_ box: CGRect) -> CGRect {
            CGRect(
                x: box.minX * CGFloat(width),
                y: CGFloat(height) * (1 - box.maxY),
                width: box.width * CGFloat(width),
                height: box.height * CGFloat(height)
            )
        }

        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(red: 0, green: 0.4, blue: 1, alpha: 0.9))
        for line in assembled.lines {
            ctx.stroke(pixelRect(line.box))
        }
        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
        for line in assembled.lines {
            for word in line.words {
                ctx.stroke(pixelRect(word.box))
            }
        }
        if let tapped = assembled.tappedWordBox {
            ctx.setLineWidth(3)
            ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1))
            ctx.stroke(pixelRect(tapped))
        }

        let tapPx = CGPoint(x: tapNorm.x * CGFloat(width), y: CGFloat(height) * (1 - tapNorm.y))
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(red: 0, green: 0.8, blue: 0.2, alpha: 1))
        ctx.strokeLineSegments(between: [
            CGPoint(x: tapPx.x - 12, y: tapPx.y), CGPoint(x: tapPx.x + 12, y: tapPx.y),
            CGPoint(x: tapPx.x, y: tapPx.y - 12), CGPoint(x: tapPx.x, y: tapPx.y + 12),
        ])

        return ctx.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func round4(_ rect: CGRect) -> String {
        String(
            format: "(%.4f,%.4f %.4fx%.4f)",
            rect.minX, rect.minY, rect.width, rect.height
        )
    }

    private static func round1(_ rect: CGRect) -> String {
        String(
            format: "(%.1f,%.1f %.1fx%.1f)",
            rect.minX, rect.minY, rect.width, rect.height
        )
    }
}
