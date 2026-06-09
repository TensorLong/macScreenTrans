import CoreGraphics
import MacScreenTransCore
import Vision

/// Runs Apple Vision text recognition on a captured image and returns
/// `RecognizedLine`s in the assembler's coordinate convention: normalized
/// image coordinates with a TOP-LEFT origin (y grows down). Vision natively
/// reports normalized BOTTOM-LEFT boxes, so every box is flipped here once,
/// at the boundary, and nothing downstream has to think about it again.
struct VisionTextRecognizer {
    /// BCP-47 codes ordered by likelihood of the SOURCE language. Vision uses
    /// the order as a ranking hint; the source language should lead.
    let recognitionLanguages: [String]

    func recognize(in image: CGImage) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !recognitionLanguages.isEmpty {
            request.recognitionLanguages = recognitionLanguages
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        var lines: [RecognizedLine] = []
        lines.reserveCapacity(observations.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            guard !text.isEmpty else { continue }

            let lineBox = Self.normalizedTopLeft(observation.boundingBox)
            let words = Self.words(in: text, candidate: candidate)
            lines.append(RecognizedLine(text: text, box: lineBox, words: words))
        }
        return lines
    }

    /// Per-word boxes, computed by asking Vision for the bounding box of each
    /// word's character range. Words are linguistic tokens (`.byWords`), which
    /// is enough for tap hit-testing — the precise token under the cursor is
    /// re-derived from the offset by `WordContextExtractor` downstream.
    private static func words(in text: String, candidate: VNRecognizedText) -> [RecognizedWord] {
        var words: [RecognizedWord] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { substring, range, _, _ in
            guard let substring,
                  let boxObservation = try? candidate.boundingBox(for: range) else {
                return
            }
            let box = normalizedTopLeft(boxObservation.boundingBox)
            let lo = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
            let hi = text.utf16.distance(from: text.startIndex, to: range.upperBound)
            guard lo < hi else { return }
            words.append(RecognizedWord(text: substring, range: lo..<hi, box: box))
        }
        return words
    }

    /// Flip a Vision normalized box (bottom-left origin) to top-left origin.
    private static func normalizedTopLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
