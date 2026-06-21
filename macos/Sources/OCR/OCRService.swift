import Foundation

/// On-device OCR via Vision (TECH §8.1).
///
/// Will use `VNRecognizeTextRequest` (`.accurate`,
/// `recognitionLanguages = ["zh-Hans","en-US"]`); observations sorted by
/// bounding box for reading order; the PNG is discarded after. Stub for slice 1.
struct OCRService {
    func recognizeText(in imageURL: URL) async throws -> String {
        // TODO(slice: ocr): VNRecognizeTextRequest pipeline.
        return ""
    }
}
