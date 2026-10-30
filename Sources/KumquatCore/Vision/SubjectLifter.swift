import CoreImage
import Foundation
import Vision

public enum SubjectLifter {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Foreground subject(s) cut out on a transparent background, cropped to their extent.
    public static func lift(_ url: URL) async throws -> CGImage {
        try await runBlocking {
            let image = try ImageEngine.decode(url, maxPixelSize: 4096)
            return try lift(image)
        }
    }

    public static func lift(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw KumquatError.noResult(String(localized: "No subject found in this image."))
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: true)
        let masked = CIImage(cvPixelBuffer: buffer)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = context.createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: space) else {
            throw KumquatError.noResult(String(localized: "Couldn't render the subject."))
        }
        return result
    }
}
