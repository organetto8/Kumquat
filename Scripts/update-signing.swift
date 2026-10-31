// Signs releases for Kumquat's updater with an Ed25519 key kept in the login keychain.
//
//   swift Scripts/update-signing.swift generate            new key; its public half goes into Resources/Info.plist
//   swift Scripts/update-signing.swift sign <app> <zip>    writes <zip>.sig for the app the zip was made from
//   swift Scripts/update-signing.swift export              prints the private key (base64) for an offline backup
//   swift Scripts/update-signing.swift import              reads a backed-up key from standard input
//   swift Scripts/update-signing.swift rotate              next key; the next release, still signed with the
//                                                          current key, carries the new public half
//   swift Scripts/update-signing.swift finish-rotation     after publishing that release: the next key becomes current
//
// The app installs an update only if <zip>.sig is this key's signature of
//   "kumquat-update-1\n<bundle identifier>\n<version>\n<SHA-256 of the zip, lowercase hex>\n"
// (UpdateSignature.message in KumquatCore). The private key never goes into the repository or CI.
import CryptoKit
import Foundation
import Security

let service = "app.kumquat.update-signing"
let currentAccount = "ed25519"
let nextAccount = "ed25519-next"
let infoPlist = "Resources/Info.plist"
let publicKeyField = "KumquatUpdatePublicKey"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
}

func storedKey(_ account: String = currentAccount) -> Curve25519.Signing.PrivateKey? {
    var search = query(account)
    search[kSecReturnData as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(search as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { fail("can't read the signing key from the keychain (\(status))") }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("the keychain item isn't an Ed25519 key") }
    return key
}

func store(_ key: Curve25519.Signing.PrivateKey, as account: String = currentAccount) {
    guard storedKey(account) == nil else { fail("a signing key is already in the keychain (\(service), \(account))") }
    var item = query(account)
    item[kSecAttrLabel as String] = account == currentAccount ? "Kumquat update signing key" : "Kumquat update signing key (next)"
    item[kSecValueData as String] = key.rawRepresentation
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("can't save the signing key in the keychain (\(status))") }
}

func delete(_ account: String) {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { fail("can't delete the \(account) key from the keychain (\(status))") }
}

func base64(_ key: Curve25519.Signing.PublicKey) -> String { key.rawRepresentation.base64EncodedString() }

func contents(ofPlist plist: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: plist),
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { fail("can't read \(plist)") }
    return values
}

func publish(_ key: Curve25519.Signing.PublicKey) {
    let plutil = Process()
    plutil.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    plutil.arguments = ["-replace", publicKeyField, "-string", base64(key), infoPlist]
    do { try plutil.run() } catch { fail("can't run plutil: \(error.localizedDescription)") }
    plutil.waitUntilExit()
    guard plutil.terminationStatus == 0 else { fail("plutil couldn't update \(infoPlist)") }
    print("Wrote the public key into \(infoPlist) (\(publicKeyField)). Commit it, and back up the private key: see docs/RELEASING.md.")
}

func sha256(_ file: String) -> String {
    guard let handle = FileHandle(forReadingAtPath: file) else { fail("can't read \(file)") }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    store(key)
    publish(key.publicKey)

case "sign":
    guard arguments.count == 3 else { fail("usage: sign <Kumquat.app> <Kumquat-x.y.z.zip>") }
    let app = arguments[1], zip = arguments[2]
    guard let key = storedKey() else { fail("no signing key in the keychain: run `make update-key` once (docs/RELEASING.md)") }
    let next = storedKey(nextAccount)
    let appInfo = contents(ofPlist: app + "/Contents/Info.plist")
    guard let identifier = appInfo["CFBundleIdentifier"] as? String, let version = appInfo["CFBundleShortVersionString"] as? String else {
        fail("\(app) has no bundle identifier or version")
    }
    // Copies installed today check with the current key; the app being released must trust the key that signs
    // the release after it: the current one, or the next one while rotating.
    let carried = appInfo[publicKeyField] as? String
    guard carried == base64(key.publicKey) || (next != nil && carried == next.map { base64($0.publicKey) }) else {
        fail("\(app) carries a different \(publicKeyField) than the keychain's key: fix \(infoPlist) and rebuild")
    }
    guard (zip as NSString).lastPathComponent == "Kumquat-\(version).zip" else { fail("\(zip) should be named Kumquat-\(version).zip") }
    let message = Data("kumquat-update-1\n\(identifier)\n\(version)\n\(sha256(zip))\n".utf8)
    guard let signature = try? key.signature(for: message), key.publicKey.isValidSignature(signature, for: message) else { fail("signing failed") }
    do {
        try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: zip + ".sig"))
    } catch {
        fail("can't write \(zip).sig: \(error.localizedDescription)")
    }
    print("Signed \(zip) for \(identifier) \(version)")
    if next != nil {
        print("This release moves users to the next key. Once it is published, run: swift Scripts/update-signing.swift finish-rotation")
    }

case "export":
    guard let key = storedKey() else { fail("no signing key in the keychain") }
    FileHandle.standardError.write(Data("This is the private key. Keep it offline (a password manager), never in the repository.\n".utf8))
    print(key.rawRepresentation.base64EncodedString())

case "import":
    guard let text = readLine(strippingNewline: true), let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespaces)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("paste the base64 key printed by export") }
    store(key)
    if contents(ofPlist: infoPlist)[publicKeyField] as? String != base64(key.publicKey) { publish(key.publicKey) }

case "rotate":
    guard storedKey() != nil else { fail("no current key to rotate from") }
    let next = Curve25519.Signing.PrivateKey()
    store(next, as: nextAccount)
    publish(next.publicKey)
    print("Release the next version as usual: it is signed with the current key and carries the new one. Then run finish-rotation.")

case "finish-rotation":
    guard let next = storedKey(nextAccount) else { fail("no rotation in progress") }
    delete(currentAccount)
    store(next)
    delete(nextAccount)
    print("The new key is now the signing key. Back it up: swift Scripts/update-signing.swift export")

default:
    fail("usage: swift Scripts/update-signing.swift generate | sign <app> <zip> | export | import | rotate | finish-rotation")
}
