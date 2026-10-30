import Foundation

public enum KumquatError: LocalizedError, Sendable, Equatable {
    case cannotOpen(String)
    case cannotDecode(String)
    case cannotEncode(String)
    case cannotWrite(String)
    case unsupported(String)
    case noResult(String)
    case toolMissing(String)
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): String(localized: "Can't open “\(name)”.")
        case .cannotDecode(let name): String(localized: "Can't decode “\(name)”.")
        case .cannotEncode(let format): String(localized: "Can't encode as \(format).")
        case .cannotWrite(let place): String(localized: "Can't write to “\(place)”.")
        case .unsupported(let what): String(localized: "\(what) isn't supported.")
        case .noResult(let message): message
        case .toolMissing(let tool): String(localized: "\(tool) is not installed.")
        case .processFailed(let message): message
        }
    }
}
