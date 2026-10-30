import CoreGraphics
import Foundation
import Vision

/// Four corners in normalised, bottom-left-origin image coordinates (Vision's and Core Image's orientation).
struct Quad: Sendable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    init(_ observation: VNRectangleObservation) {
        topLeft = observation.topLeft
        topRight = observation.topRight
        bottomRight = observation.bottomRight
        bottomLeft = observation.bottomLeft
    }

    /// Share of the picture covered (shoelace formula).
    var area: CGFloat {
        let points = [topLeft, topRight, bottomRight, bottomLeft]
        var sum: CGFloat = 0
        for (index, point) in points.enumerated() {
            let next = points[(index + 1) % points.count]
            sum += point.x * next.y - next.x * point.y
        }
        return abs(sum) / 2
    }
}

/// Vision lookups behind the image tools: paper sheets, faces and what a picture shows.
enum ImageAnalysis {
    /// The sheet of paper in a photo, from Vision's document segmentation (a model trained on pages,
    /// receipts and cards). It always returns its best guess; a real sheet scores close to 1, anything
    /// else close to 0. The plain rectangle detector isn't used as a fallback: it happily reports
    /// screens, frames and round shapes.
    static func document(in image: CGImage) throws -> Quad? {
        let segmentation = VNDetectDocumentSegmentationRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([segmentation])
        return segmentation.results?.first(where: { $0.confidence >= 0.5 && Quad($0).area >= 0.05 }).map(Quad.init)
    }

    /// Face boxes, normalised with a bottom-left origin.
    static func faces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    /// The few labels Vision is fairly sure about, most confident first, as words people would
    /// type ("Golden retriever", not "golden_retriever").
    static func labels(in image: CGImage, limit: Int = 5, minimumConfidence: Float = 0.3) throws -> [String] {
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map { readable($0.identifier) }
    }

    static func readable(_ identifier: String) -> String {
        let words = identifier.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
