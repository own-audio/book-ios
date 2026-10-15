#!/usr/bin/env swift
// The App Store listing to App Store Connect: the texts in AppStore/<language>/ and the
// captioned screenshots in AppStore/marketing/ (scripts/marketing-screenshots.swift), for every
// language there is, on the version being prepared.
//
// Needs an App Store Connect API key (App Manager): the .p8 in ~/.appstoreconnect/private_keys/
// and ASC_KEY_ID / ASC_ISSUER_ID in release.local.env (gitignored).
//
// Usage: swift scripts/app-store-upload.swift [--dry-run | --status]
import CryptoKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let dryRun = CommandLine.arguments.contains("--dry-run")
let bundleId = "audio.own.bookplayer"
let api = URL(string: "https://api.appstoreconnect.apple.com")!

/// Folders here → App Store Connect locales.
let locales: [(folder: String, screenshots: String, locale: String)] = [("en-US", "en", "en-US"), ("cs", "cs", "cs")]
/// Device folders → screenshot display types (6.9" iPhone, 13" iPad).
let displayTypes: [(folder: String, type: String)] = [("iPhone 17 Pro Max", "APP_IPHONE_67"), ("iPad Pro 13-inch (M5)", "APP_IPAD_PRO_3GEN_129")]

// MARK: - Settings and the token

func settings() -> [String: String] {
    let text = (try? String(contentsOf: root.appendingPathComponent("release.local.env"), encoding: .utf8)) ?? ""
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") where line.contains("=") && !line.hasPrefix("#") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        out[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }
    return out
}

let env = settings()
guard let keyId = env["ASC_KEY_ID"], let issuer = env["ASC_ISSUER_ID"] else {
    fatalError("ASC_KEY_ID and ASC_ISSUER_ID go in release.local.env")
}
let keyURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".appstoreconnect/private_keys/AuthKey_\(keyId).p8")
let privateKey = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOf: keyURL, encoding: .utf8))

func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// A token good for 15 minutes (App Store Connect takes at most 20).
func token() throws -> String {
    let header = base64url(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyId, "typ": "JWT"]))
    let now = Int(Date().timeIntervalSince1970)
    let claims = base64url(try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"]))
    let signature = try privateKey.signature(for: Data("\(header).\(claims)".utf8))
    return "\(header).\(claims).\(base64url(signature.rawRepresentation))"
}

// MARK: - Requests

struct Failure: Error, CustomStringConvertible {
    let description: String
}

@discardableResult
func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
    var request = URLRequest(url: path.hasPrefix("http") ? URL(string: path)! : api.appendingPathComponent(path))
    if path.contains("?"), !path.hasPrefix("http") { request.url = URL(string: api.absoluteString + "/" + path)! }
    request.httpMethod = method
    request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw Failure(description: "\(method) \(path) → \(status): \(String(decoding: data.prefix(600), as: UTF8.self))")
    }
    return data.isEmpty ? [:] : ((try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
}

func items(_ answer: [String: Any]) -> [[String: Any]] { answer["data"] as? [[String: Any]] ?? [] }
func id(_ item: [String: Any]) -> String { item["id"] as? String ?? "" }
func attribute(_ item: [String: Any], _ name: String) -> Any? { (item["attributes"] as? [String: Any])?[name] }

func text(_ folder: String, _ file: String) -> String? {
    (try? String(contentsOf: root.appendingPathComponent("AppStore/\(folder)/\(file)"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - The listing

let app = try await call("GET", "v1/apps?filter[bundleId]=\(bundleId)")
guard let appItem = items(app).first else { throw Failure(description: "no app with the bundle id \(bundleId) in App Store Connect") }
let appId = id(appItem)
print("app \(attribute(appItem, "name") ?? "?") (\(appId))")

// The version being prepared: the editable one, else a new one at the app's version.
let versions = items(try await call("GET", "v1/apps/\(appId)/appStoreVersions?filter[platform]=IOS"))
for v in versions { print("  version \(attribute(v, "versionString") ?? "?") — \(attribute(v, "appStoreState") ?? "?")") }
let editable: Set<String> = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "WAITING_FOR_REVIEW"]
var versionId = versions.first { editable.contains(attribute($0, "appStoreState") as? String ?? "") }.map(id)
if versionId == nil {
    let plist = root.appendingPathComponent("App/OwnAudioBooks/Info.plist")
    let info = NSDictionary(contentsOf: plist) as? [String: Any]
    let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
    print("  no version being prepared: \(dryRun ? "would make" : "making") \(version)")
    if !dryRun {
        let made = try await call("POST", "v1/appStoreVersions", ["data": [
            "type": "appStoreVersions", "attributes": ["platform": "IOS", "versionString": version],
            "relationships": ["app": ["data": ["type": "apps", "id": appId]]],
        ]])
        versionId = (made["data"] as? [String: Any]).map(id)
    }
}

// App-level texts: name, subtitle, privacy policy.
let appInfos = items(try await call("GET", "v1/apps/\(appId)/appInfos"))
let appInfo = appInfos.first { (attribute($0, "appStoreState") as? String) != "READY_FOR_SALE" } ?? appInfos.first
let infoLocalizations = appInfo != nil ? items(try await call("GET", "v1/appInfos/\(id(appInfo!))/appInfoLocalizations")) : []
let versionLocalizations = versionId != nil ? items(try await call("GET", "v1/appStoreVersions/\(versionId!)/appStoreVersionLocalizations")) : []
print("  app info locales: \(infoLocalizations.compactMap { attribute($0, "locale") as? String })")
print("  version locales: \(versionLocalizations.compactMap { attribute($0, "locale") as? String })")

// `--status`: how App Store Connect took each screenshot, and nothing else.
if CommandLine.arguments.contains("--status") {
    for localization in versionLocalizations {
        for set in items(try await call("GET", "v1/appStoreVersionLocalizations/\(id(localization))/appScreenshotSets")) {
            let shots = items(try await call("GET", "v1/appScreenshotSets/\(id(set))/appScreenshots"))
            let states = shots.map { ((attribute($0, "assetDeliveryState") as? [String: Any])?["state"] as? String) ?? "?" }
            print("\(attribute(localization, "locale") ?? "?") \(attribute(set, "screenshotDisplayType") ?? "?"): \(Dictionary(grouping: states, by: { $0 }).mapValues(\.count))")
        }
    }
    exit(0)
}

let privacyURL = "https://github.com/own-audio/book-ios/blob/main/PRIVACY.md"
let supportURL = "https://github.com/own-audio/book-ios/issues"
let marketingURL = "https://www.own.audio"

for (folder, shotFolder, locale) in locales {
    print("== \(locale)")
    // Name, subtitle, privacy policy.
    let infoAttributes: [String: Any] = [
        "name": text(folder, "name.txt") ?? "", "subtitle": text(folder, "subtitle.txt") ?? "", "privacyPolicyUrl": privacyURL,
    ]
    if let existing = infoLocalizations.first(where: { attribute($0, "locale") as? String == locale }) {
        print("  app info: update name, subtitle, privacy policy")
        if !dryRun { try await call("PATCH", "v1/appInfoLocalizations/\(id(existing))", ["data": ["type": "appInfoLocalizations", "id": id(existing), "attributes": infoAttributes]]) }
    } else if let appInfo {
        print("  app info: add \(locale)")
        if !dryRun {
            try await call("POST", "v1/appInfoLocalizations", ["data": [
                "type": "appInfoLocalizations", "attributes": infoAttributes.merging(["locale": locale]) { a, _ in a },
                "relationships": ["appInfo": ["data": ["type": "appInfos", "id": id(appInfo)]]],
            ]])
        }
    }

    // Description, keywords, promotional text, links.
    guard let versionId else { continue }
    let versionAttributes: [String: Any] = [
        "description": text(folder, "description.txt") ?? "", "keywords": text(folder, "keywords.txt") ?? "",
        "promotionalText": text(folder, "promotional_text.txt") ?? "", "supportUrl": supportURL, "marketingUrl": marketingURL,
    ]
    var localizationId = versionLocalizations.first { attribute($0, "locale") as? String == locale }.map(id)
    if let existing = localizationId {
        print("  version: update description, keywords, promotional text, links")
        if !dryRun { try await call("PATCH", "v1/appStoreVersionLocalizations/\(existing)", ["data": ["type": "appStoreVersionLocalizations", "id": existing, "attributes": versionAttributes]]) }
    } else {
        print("  version: add \(locale)")
        if !dryRun {
            let made = try await call("POST", "v1/appStoreVersionLocalizations", ["data": [
                "type": "appStoreVersionLocalizations", "attributes": versionAttributes.merging(["locale": locale]) { a, _ in a },
                "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionId]]],
            ]])
            localizationId = (made["data"] as? [String: Any]).map(id)
        }
    }
    guard let localizationId else { continue }

    // Screenshots: each device's set replaced by the captioned ones, in their order.
    let sets = items(try await call("GET", "v1/appStoreVersionLocalizations/\(localizationId)/appScreenshotSets"))
    for (deviceFolder, displayType) in displayTypes {
        let folderURL = root.appendingPathComponent("AppStore/marketing/\(shotFolder)/\(deviceFolder)")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        guard !files.isEmpty else { print("  \(displayType): no screenshots in \(folderURL.path)"); continue }
        print("  \(displayType): \(files.count) screenshots")
        if dryRun { continue }
        var setId = sets.first { attribute($0, "screenshotDisplayType") as? String == displayType }.map(id)
        if let existing = setId {
            for old in items(try await call("GET", "v1/appScreenshotSets/\(existing)/appScreenshots")) {
                try await call("DELETE", "v1/appScreenshots/\(id(old))")
            }
        } else {
            let made = try await call("POST", "v1/appScreenshotSets", ["data": [
                "type": "appScreenshotSets", "attributes": ["screenshotDisplayType": displayType],
                "relationships": ["appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": localizationId]]],
            ]])
            setId = (made["data"] as? [String: Any]).map(id)
        }
        guard let setId else { continue }
        for file in files {
            let data = try Data(contentsOf: folderURL.appendingPathComponent(file))
            let reserved = try await call("POST", "v1/appScreenshots", ["data": [
                "type": "appScreenshots", "attributes": ["fileName": file, "fileSize": data.count],
                "relationships": ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": setId]]],
            ]])
            guard let shot = reserved["data"] as? [String: Any],
                  let operations = attribute(shot, "uploadOperations") as? [[String: Any]] else { throw Failure(description: "no upload for \(file)") }
            for op in operations {
                var put = URLRequest(url: URL(string: op["url"] as! String)!)
                put.httpMethod = op["method"] as? String ?? "PUT"
                for header in op["requestHeaders"] as? [[String: String]] ?? [] { put.setValue(header["value"], forHTTPHeaderField: header["name"] ?? "") }
                let offset = op["offset"] as? Int ?? 0, length = op["length"] as? Int ?? data.count
                let (_, response) = try await URLSession.shared.upload(for: put, from: data.subdata(in: offset..<(offset + length)))
                guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw Failure(description: "upload of \(file) refused") }
            }
            let checksum = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try await call("PATCH", "v1/appScreenshots/\(id(shot))", ["data": [
                "type": "appScreenshots", "id": id(shot), "attributes": ["uploaded": true, "sourceFileChecksum": checksum],
            ]])
            print("    \(file)")
        }
    }
}
print(dryRun ? "dry run: nothing changed" : "done")
