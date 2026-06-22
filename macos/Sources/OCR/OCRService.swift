import CoreGraphics
import Foundation
import Vision

/// An item that carries a normalized Vision bounding box and can be ordered into
/// natural reading order. `VNRecognizedTextObservation` conforms in production;
/// a synthetic value type conforms in tests (real observations cannot be
/// constructed by hand).
protocol ReadingOrderItem {
    /// Vision-normalized bounding box: origin bottom-left, `y` grows *upward*,
    /// values in `0...1`.
    var boundingBox: CGRect { get }
}

extension VNRecognizedTextObservation: ReadingOrderItem {}

/// On-device OCR via Vision (TECH §8.1).
///
/// Uses `VNRecognizeTextRequest` (`.accurate`,
/// `recognitionLanguages = ["zh-Hans","en-US"]`, language correction on),
/// orders the observations into natural reading order, takes the top candidate
/// of each line, and joins them. The PNG is discarded by the caller after.
struct OCRService {

    /// Languages we recognize, in priority order: Simplified Chinese then US
    /// English (TECH §8.1).
    static let recognitionLanguages = ["zh-Hans", "en-US"]

    /// Lines whose `boundingBox` mid-`y` differs by less than this fraction of
    /// the image height are treated as the *same* row, then ordered left→right.
    /// Without this, Vision's tiny per-glyph `y` jitter scrambles a single line.
    static let sameLineTolerance: CGFloat = 0.01

    /// Recognizes text in the image at `imageURL` and returns it joined into one
    /// string in reading order. Returns an empty string when nothing is found.
    func recognizeText(in imageURL: URL) async throws -> String {
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw OCRError.imageLoadFailed(imageURL)
        }

        let observations = try await recognize(cgImage: cgImage)
        return Self.joinedText(from: observations)
    }

    /// Runs the Vision request on a decoded image. Split out so the request
    /// configuration is in one place.
    private func recognize(cgImage: CGImage) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let results = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = Self.recognitionLanguages
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Joins recognized observations into one reading-order string, taking each
    /// line's single best candidate.
    static func joinedText(from observations: [VNRecognizedTextObservation]) -> String {
        sortedReadingOrder(observations)
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Orders items into natural reading order: top→bottom (by box `y`
    /// descending, since Vision's `y` grows upward), then left→right within a
    /// row (by box `x` ascending). Pure and generic so it is unit-testable with
    /// synthetic items.
    static func sortedReadingOrder<Item: ReadingOrderItem>(_ items: [Item]) -> [Item] {
        items.sorted { lhs, rhs in
            let lhsMidY = lhs.boundingBox.midY
            let rhsMidY = rhs.boundingBox.midY
            // Same row? Higher normalized y is visually higher → comes first.
            if abs(lhsMidY - rhsMidY) > sameLineTolerance {
                return lhsMidY > rhsMidY
            }
            return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
        }
    }
}

/// Errors surfaced by `OCRService`.
enum OCRError: Error, Equatable {
    /// The image at the URL could not be decoded.
    case imageLoadFailed(URL)
}
