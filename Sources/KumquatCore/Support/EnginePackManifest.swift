// Which engines-N release the app installs engines from, and the SHA-256 of each file in it.
// Scripts/engines/publish.py attaches this file to every engines release: replace this copy with that
// one to move the app to a new pack (docs/RELEASING.md). Empty until the first engines release.
extension EnginePack {
    static let release: String? = nil
    static let assets: [String: Asset] = [:]
}
