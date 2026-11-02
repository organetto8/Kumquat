import Foundation
import Testing
@testable import KumquatCore

@Suite struct EnginePackTests {
    private let architectures = ["arm64", "x86_64"]

    @Test func everyEngineHasABuildForBothProcessors() {
        for engine in Engine.allCases {
            for architecture in architectures {
                #expect(EnginePack.assets["\(engine.rawValue)-\(architecture)"] != nil, "\(engine.rawValue)-\(architecture)")
            }
        }
    }

    /// The setup window ticks the recommended engines, so together they must stay a small download.
    @Test func recommendedEnginesAreASmallDownload() {
        for architecture in architectures {
            let bytes = Engine.allCases.filter { $0.group == .recommended }
                .compactMap { EnginePack.assets["\($0.rawValue)-\(architecture)"]?.size }
                .reduce(0, +)
            #expect(bytes < 50_000_000, "\(architecture): \(bytes) bytes")
        }
    }

    @Test func remembersWhichPackAnEngineCameFrom() throws {
        let folder = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = folder.appendingPathComponent("ffmpeg", isDirectory: true)
        #expect(EnginePack.release(in: engine) == nil)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        // Unpacked before folders were marked: engines-1 was the only pack then.
        #expect(EnginePack.release(in: engine) == "engines-1")
        try EnginePack.recordRelease("engines-2", in: engine)
        #expect(EnginePack.release(in: engine) == "engines-2")
    }
}
