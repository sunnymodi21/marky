import Foundation
import Vision

/// On-device OCR (the Live Text engine) for images stored in clipboard history.
/// No permissions required — it only reads image data we already have.
enum ImageTextRecognizer {
    static func recognizeText(pngData: Data) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(data: pngData, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
