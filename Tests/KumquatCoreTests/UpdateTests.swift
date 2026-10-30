import CryptoKit
import Foundation
import Testing
@testable import KumquatCore

@Suite struct UpdateTests {
    private let identifier = "app.kumquat.Kumquat"

    @Test func versionsParseStrictly() {
        #expect(ReleaseVersion("1.2.3")?.description == "1.2.3")
        #expect(ReleaseVersion("1.2.3-beta.1")?.prerelease == ["beta", "1"])
        #expect(ReleaseVersion("0.10.0-rc-2")?.description == "0.10.0-rc-2")
        #expect(ReleaseVersion(tag: "v1.0.0") == ReleaseVersion("1.0.0"))
        #expect(ReleaseVersion(tag: "1.0.0") == nil)
        let rejected = ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.3-", "1.2.3-beta..1", "1.2.3-01", "+1.2.3", "1.+2.3",
                        "1.2.3+build", "1.2.3-be/ta", "1.2.3-é", "v1.2.3", " 1.2.3", "1.2.3\n", "1.-2.3", "１.2.3", "1.2.3-x/../../evil",
                        "1234567890.0.0", "1.2.3-" + String(repeating: "a", count: 60)]
        for text in rejected { #expect(ReleaseVersion(text) == nil, "\(text)") }
    }

    @Test func versionsSortLikeSemanticVersioning() throws {
        let texts = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1",
                     "1.0.0", "1.0.1", "1.1.0-beta.1", "1.1.0", "1.10.0", "2.0.0"]
        let versions = texts.compactMap { ReleaseVersion($0) }
        try #require(versions.count == texts.count)
        for (lower, higher) in zip(versions, versions.dropFirst()) { #expect(lower < higher, "\(lower) < \(higher)") }
        #expect(versions.reversed().sorted() == versions)
    }

    @Test func picksTheNewestSignedRelease() throws {
        func entry(_ tag: String, prerelease: Bool = false, draft: Bool = false, size: Int = 30_000_000, signed: Bool = true) -> [String: Any] {
            let name = "Kumquat-\(tag.dropFirst()).zip"
            var assets: [[String: Any]] = [["name": name, "size": size, "state": "uploaded"]]
            if signed { assets.append(["name": name + ".sig", "size": 89, "state": "uploaded"]) }
            return ["tag_name": tag, "draft": draft, "prerelease": prerelease, "body": "notes", "assets": assets]
        }
        let json = try JSONSerialization.data(withJSONObject: [
            entry("v2.0.0", draft: true),
            entry("v1.4.0-beta.1", prerelease: true),
            entry("v1.3.0", signed: false),
            entry("v1.2.5", size: 900_000_000),
            entry("v1.2.0"),
            entry("v1.1.0"),
            entry("v1.0.0"),
            entry("nightly"),
            // The engine pack's releases share the list; their tags are not app versions.
            entry("engines-1"),
        ])
        let installed = try #require(ReleaseVersion("1.0.0"))
        #expect(try UpdateFeed.newest(in: json, after: installed, includingBetas: false)?.version.description == "1.2.0")
        #expect(try UpdateFeed.newest(in: json, after: installed, includingBetas: true)?.version.description == "1.4.0-beta.1")
        #expect(try UpdateFeed.newest(in: json, after: try #require(ReleaseVersion("1.2.0")), includingBetas: false) == nil)
        #expect(try UpdateFeed.newest(in: json, after: try #require(ReleaseVersion("1.4.0-beta.1")), includingBetas: true) == nil)
        #expect(throws: UpdateError.unreachable) { try UpdateFeed.newest(in: Data("{\"message\": \"rate limited\"}".utf8), after: installed, includingBetas: false) }
        let newest = try #require(try UpdateFeed.newest(in: json, after: installed, includingBetas: false))
        #expect(newest.archiveName == "Kumquat-1.2.0.zip" && newest.signatureName == "Kumquat-1.2.0.zip.sig")
    }

    @Test func signaturesBindAppVersionAndFile() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        let version = try #require(ReleaseVersion("1.2.0"))
        let digest = String(repeating: "ab", count: 32)
        let message = UpdateSignature.message(bundleIdentifier: identifier, version: version, archiveDigest: digest)
        #expect(String(decoding: message, as: UTF8.self) == "kumquat-update-1\napp.kumquat.Kumquat\n1.2.0\n\(digest)\n")
        let signature = try key.signature(for: message)
        #expect(UpdateSignature.isValid(signature, publicKey: publicKey, message: message))

        let older = UpdateSignature.message(bundleIdentifier: identifier, version: try #require(ReleaseVersion("1.1.0")), archiveDigest: digest)
        let otherFile = UpdateSignature.message(bundleIdentifier: identifier, version: version, archiveDigest: String(repeating: "cd", count: 32))
        let otherApp = UpdateSignature.message(bundleIdentifier: "com.example.Other", version: version, archiveDigest: digest)
        for forged in [older, otherFile, otherApp] { #expect(!UpdateSignature.isValid(signature, publicKey: publicKey, message: forged)) }
        #expect(!UpdateSignature.isValid(signature, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, message: message))
        #expect(!UpdateSignature.isValid(Data(count: 64), publicKey: publicKey, message: message))
        #expect(!UpdateSignature.isValid(signature, publicKey: Data(count: 5), message: message))

        #expect(UpdateSignature.parse(Data((signature.base64EncodedString() + "\n").utf8)) == signature)
        #expect(UpdateSignature.parse(Data("not base64".utf8)) == nil)
        #expect(UpdateSignature.parse(Data(Data(count: 32).base64EncodedString().utf8)) == nil)
        #expect(UpdateSignature.parse(Data(count: 4096)) == nil)
    }

    @Test func onlyGitHubOverHTTPSIsFollowed() throws {
        for text in ["https://github.com/organetto8/Kumquat/releases/download/v1.0.0/Kumquat-1.0.0.zip", "https://api.github.com/repos/a/b/releases",
                     "https://release-assets.githubusercontent.com/x", "https://objects.githubusercontent.com/x"] {
            #expect(Transfer.isAllowed(try #require(URL(string: text))), "\(text)")
        }
        for text in ["http://github.com/x", "https://evilgithub.com/x", "https://github.com.evil.com/x", "https://evilgithubusercontent.com/x",
                     "https://github.com@evil.com/x", "https://user@github.com/x", "https://github.com:8443/x", "file:///etc/passwd"] {
            #expect(!Transfer.isAllowed(try #require(URL(string: text))), "\(text)")
        }
    }

    @Test func unpacksOnlyASignedCopyOfThisApp() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = Curve25519.Signing.PrivateKey()
        let version = try #require(ReleaseVersion("1.2.0"))
        let newer = try #require(ReleaseVersion("1.3.0"))
        let zip = try await Self.release(identifier: identifier, version: "1.2.0", in: dir)
        let signature = try key.signature(for: UpdateSignature.message(bundleIdentifier: identifier, version: version,
                                                                       archiveDigest: try UpdateSignature.sha256(of: zip)))
        func unpack(signature: Data, publicKey: Data, identifier: String, version: ReleaseVersion) async throws -> URL {
            let staging = dir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return try await UpdateInstaller.unpack(zip, signature: signature, publicKey: publicKey, bundleIdentifier: identifier,
                                                    version: version, into: staging)
        }

        let app = try await unpack(signature: signature, publicKey: key.publicKey.rawRepresentation, identifier: identifier, version: version)
        #expect(app.lastPathComponent == "Kumquat.app")
        #expect(try UpdateInstaller.bundleInfo(app).version == "1.2.0")

        // Another key, or the right key over another version or app: refused before unpacking.
        let stranger = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        await #expect(throws: UpdateError.badSignature) {
            try await unpack(signature: signature, publicKey: stranger, identifier: identifier, version: version)
        }
        await #expect(throws: UpdateError.badSignature) {
            try await unpack(signature: signature, publicKey: key.publicKey.rawRepresentation, identifier: identifier, version: newer)
        }

        // Correctly signed, but the archive holds another version or another app: refused after unpacking.
        let mislabelled = try key.signature(for: UpdateSignature.message(bundleIdentifier: identifier, version: newer,
                                                                         archiveDigest: try UpdateSignature.sha256(of: zip)))
        await #expect(throws: UpdateError.badArchive) {
            try await unpack(signature: mislabelled, publicKey: key.publicKey.rawRepresentation, identifier: identifier, version: newer)
        }
        let impostor = try key.signature(for: UpdateSignature.message(bundleIdentifier: "com.example.Other", version: version,
                                                                      archiveDigest: try UpdateSignature.sha256(of: zip)))
        await #expect(throws: UpdateError.badArchive) {
            try await unpack(signature: impostor, publicKey: key.publicKey.rawRepresentation, identifier: "com.example.Other", version: version)
        }
    }

    @Test func refusesAnAppWhoseFilesChangedAfterSigning() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let version = try #require(ReleaseVersion("1.2.0"))
        let folder = dir.appendingPathComponent("Unpacked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let app = try await Self.makeApp(identifier: identifier, version: "1.2.0", in: folder)
        #expect(try await UpdateInstaller.validatedApp(in: folder, bundleIdentifier: identifier, version: version).lastPathComponent == "Kumquat.app")

        try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("Contents/Resources/extra.sh"))
        await #expect(throws: UpdateError.badArchive) {
            try await UpdateInstaller.validatedApp(in: folder, bundleIdentifier: identifier, version: version)
        }

        try FileManager.default.removeItem(at: app)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: dir)
        await #expect(throws: UpdateError.badArchive) {
            try await UpdateInstaller.validatedApp(in: folder, bundleIdentifier: identifier, version: version)
        }
    }

    @Test func installSwapsTheAppInPlace() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applications = dir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: false)
        let target = try await Self.makeApp(identifier: identifier, version: "1.0.0", in: applications)
        let staging = dir.appendingPathComponent("Staging")
        let unpacked = staging.appendingPathComponent("Unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let version = try #require(ReleaseVersion("1.2.0"))
        let app = try await Self.makeApp(identifier: identifier, version: "1.2.0", in: unpacked)
        let update = PreparedUpdate(version: version, app: app, staging: staging, target: target)

        try UpdateInstaller.checkReplaceable(target)
        #expect(throws: UpdateError.cannotReplace) { try UpdateInstaller.checkReplaceable(dir.appendingPathComponent("Kumquat")) }
        try await UpdateInstaller.install(update)
        #expect(try UpdateInstaller.bundleInfo(target).version == "1.2.0")
        #expect(try UpdateInstaller.bundleInfo(staging.appendingPathComponent("Previous.app")).version == "1.0.0")
        UpdateInstaller.discard(update)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    /// A minimal app signed ad hoc, like a release build: a real Mach-O (a copy of `true`) and an Info.plist.
    private static func makeApp(identifier: String, version: String, in folder: URL) async throws -> URL {
        let app = folder.appendingPathComponent("Kumquat.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Kumquat"))
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Kumquat",
                                   "CFBundlePackageType": "APPL", "CFBundleName": "Kumquat"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try await ExternalTool.check(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", app.path])
        return app
    }

    /// The release archive for such an app, made the way `make release` makes it.
    private static func release(identifier: String, version: String, in dir: URL) async throws -> URL {
        let build = dir.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
        let app = try await makeApp(identifier: identifier, version: version, in: build)
        let zip = dir.appendingPathComponent("Kumquat-\(version).zip")
        try await ExternalTool.check(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", app.path, zip.path])
        return zip
    }
}
