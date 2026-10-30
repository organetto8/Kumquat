import CoreGraphics
import Foundation
import PDFKit
import Vision

public struct Barcode: Sendable, Hashable {
    public let payload: String
    public let symbology: String
}

/// A recognised line with its box in normalised, bottom-left-origin image coordinates
/// (the same orientation as PDF user space).
struct RecognizedLine: Sendable {
    let text: String
    let box: CGRect
}

/// Vision OCR and barcode reading.
public enum TextExtractor {
    static func lines(in image: CGImage, accurate: Bool = true) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = accurate
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, box: observation.boundingBox) }
        }
    }

    public static func recognize(_ image: CGImage, accurate: Bool = true) throws -> String {
        try lines(in: image, accurate: accurate).map(\.text).joined(separator: "\n")
    }

    public static func barcodes(in image: CGImage) throws -> [Barcode] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var codes: [Barcode] = []
        for observation in request.results ?? [] {
            guard let payload = observation.payloadStringValue else { continue }
            let code = Barcode(payload: payload, symbology: observation.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: ""))
            if !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    public static func imageText(_ url: URL) async throws -> String {
        try await runBlocking { try recognize(try ImageEngine.decode(url, maxPixelSize: 6000)) }
    }

    public static func imageBarcodes(_ url: URL) async throws -> [Barcode] {
        try await runBlocking { try barcodes(in: try ImageEngine.decode(url, maxPixelSize: 4000)) }
    }

    /// Text per page: the PDF's own text layer, with OCR (in parallel) only for pages that
    /// have none — scanned pages.
    public static func pdfPages(_ url: URL) async throws -> [String] {
        var pages: [String] = try await runBlocking {
            guard let document = PDFDocument(url: url) else { throw KumquatError.cannotOpen(url.lastPathComponent) }
            return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        }
        let missing = pages.indices.filter { pages[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !missing.isEmpty else { return pages }
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var queue = missing.makeIterator()
            func schedule() {
                guard let index = queue.next() else { return }
                group.addTask {
                    try await runBlocking {
                        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: index + 1),
                              let image = PDFEngine.render(page, scale: 2.5) else { return (index, "") }
                        return (index, try recognize(image))
                    }
                }
            }
            for _ in 0..<min(missing.count, 4) { schedule() }
            while let (index, text) = try await group.next() {
                pages[index] = text
                schedule()
            }
        }
        return pages
    }
}
