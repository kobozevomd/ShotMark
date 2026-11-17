import Foundation
import Vision

/// Apple's on-device OCR. No image data leaves the Mac.
enum TextRecognizer {
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["ru-RU", "en-US"] + Locale.preferredLanguages
        var languages: [String] = []
        for language in preferred {
            if let match = supported.first(where: { $0 == language }), !languages.contains(match) {
                languages.append(match)
            }
        }
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
