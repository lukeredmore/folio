import Foundation

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let version: String
    public let buildNumber: Int
    public let commitSHA: String
    public let engineVersion: String?
    public let publishedAt: String
    public let dmgURL: String
    public let dmgSHA256: String
    public let zedDmgURL: String?
    public let zedDmgSHA256: String?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case version
        case buildNumber = "build_number"
        case commitSHA = "commit_sha"
        case engineVersion = "engine_version"
        case publishedAt = "published_at"
        case dmgURL = "dmg_url"
        case dmgSHA256 = "dmg_sha256"
        case zedDmgURL = "zed_dmg_url"
        case zedDmgSHA256 = "zed_dmg_sha256"
        case notes
    }

    public init(
        version: String,
        buildNumber: Int,
        commitSHA: String,
        engineVersion: String? = nil,
        publishedAt: String,
        dmgURL: String,
        dmgSHA256: String,
        zedDmgURL: String? = nil,
        zedDmgSHA256: String? = nil,
        notes: String? = nil
    ) {
        self.version = version
        self.buildNumber = buildNumber
        self.commitSHA = commitSHA
        self.engineVersion = engineVersion
        self.publishedAt = publishedAt
        self.dmgURL = dmgURL
        self.dmgSHA256 = dmgSHA256
        self.zedDmgURL = zedDmgURL
        self.zedDmgSHA256 = zedDmgSHA256
        self.notes = notes
    }

    /// Parses a `ReleaseManifest` from a GitHub Releases API JSON response (`/repos/<owner>/<repo>/releases/latest`).
    /// Reads embedded `<!-- folio-release: {...} -->` metadata when present, or falls back to release title/asset fields.
    public static func fromGitHubReleaseAPI(data: Data, defaultRepository: String = "lukeredmore/folio") throws -> ReleaseManifest {
        struct GitHubAsset: Decodable {
            let name: String
            let browser_download_url: String
            let digest: String?
        }
        struct GitHubRelease: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let published_at: String?
            let assets: [GitHubAsset]
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let body = release.body ?? ""

        // 1. If the release body embeds `<!-- folio-release: {...} -->`, decode it directly
        if let markerRange = body.range(of: "<!-- folio-release:"),
            let endRange = body.range(of: "-->", range: markerRange.upperBound..<body.endIndex)
        {
            let jsonSubstring = body[markerRange.upperBound..<endRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let embeddedData = jsonSubstring.data(using: .utf8),
                let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: embeddedData)
            {
                return manifest
            }
        }

        // 2. Fallback: extract from GitHub Release title, body, and Folio.dmg asset
        let dmgAsset =
            release.assets.first(where: { $0.name == "Folio.dmg" })
            ?? release.assets.first(where: { $0.name.hasSuffix(".dmg") && !$0.name.lowercased().contains("zed") })
        let dmgURL =
            dmgAsset?.browser_download_url
            ?? "https://github.com/\(defaultRepository)/releases/latest/download/Folio.dmg"

        var sha256 = ""
        if let digest = dmgAsset?.digest, digest.lowercased().hasPrefix("sha256:") {
            sha256 = String(digest.dropFirst("sha256:".count))
        }

        let zedAsset = release.assets.first(where: { $0.name == "Folio-Zed.dmg" })
        var zedSHA256: String?
        if let digest = zedAsset?.digest, digest.lowercased().hasPrefix("sha256:") {
            zedSHA256 = String(digest.dropFirst("sha256:".count))
        }

        let title = release.name ?? release.tag_name
        var version = "1.0.0"
        if let vRange = title.range(of: #"v(\d+\.\d+\.\d+)"#, options: .regularExpression) {
            version = String(title[vRange].dropFirst())
        }

        var buildNumber = 1
        if let bRange = title.range(of: #"#(\d+)"#, options: .regularExpression) {
            buildNumber = Int(title[bRange].dropFirst()) ?? 1
        }

        var commitSHA = ""
        if let shaRange = title.range(of: #"\b[0-9a-f]{7,40}\b"#, options: .regularExpression) {
            commitSHA = String(title[shaRange])
        }

        return ReleaseManifest(
            version: version,
            buildNumber: buildNumber,
            commitSHA: commitSHA,
            engineVersion: nil,
            publishedAt: release.published_at ?? "",
            dmgURL: dmgURL,
            dmgSHA256: sha256,
            zedDmgURL: zedAsset?.browser_download_url,
            zedDmgSHA256: zedSHA256,
            notes: body.isEmpty ? nil : body
        )
    }
}

public struct AppVersionInfo: Equatable, Sendable {
    public let shortVersion: String
    public let buildNumber: Int
    public let commitSHA: String
    public let engineVersion: String
    public let repository: String
    public let isDevBuild: Bool

    public init(
        shortVersion: String,
        buildNumber: Int,
        commitSHA: String,
        engineVersion: String = "0.1.0",
        repository: String = "lukeredmore/folio",
        isDevBuild: Bool? = nil
    ) {
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
        self.commitSHA = commitSHA
        self.engineVersion = engineVersion
        self.repository = repository
        let normalizedSHA = commitSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.isDevBuild = isDevBuild ?? (normalizedSHA.isEmpty || normalizedSHA == "dev")
    }

    public static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppVersionInfo {
        fromInfoDictionary(
            bundle.infoDictionary ?? [:],
            bundle: bundle,
            environment: environment
        )
    }

    public static func fromAppBundle(
        at appBundleURL: URL,
        environment: [String: String] = [:]
    ) -> AppVersionInfo? {
        let plistURL =
            appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let info = plist as? [String: Any]
        else {
            return nil
        }
        return fromInfoDictionary(
            info,
            bundlePath: appBundleURL.path,
            environment: environment
        )
    }

    public static func fromInfoDictionary(
        _ info: [String: Any],
        bundle: Bundle = .main,
        bundlePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppVersionInfo {
        let shortVersion = (info["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        let buildString = (info["CFBundleVersion"] as? String) ?? "1"
        let buildNumber = Int(buildString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        let commitSHA = (info["FolioCommitSHA"] as? String) ?? "dev"
        let engineVersion = (info["FolioEngineVersion"] as? String) ?? "0.1.0"
        let repository = (info["FolioRepository"] as? String) ?? "lukeredmore/folio"
        let normalizedSHA = commitSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isDevFromIcon: Bool
        if let bundlePath {
            isDevFromIcon = FolioBrandIcon.isRunningDevBuild(
                bundlePath: bundlePath,
                infoDictionary: info,
                environment: environment
            )
        } else {
            isDevFromIcon = FolioBrandIcon.isRunningDevBuild(bundle: bundle, environment: environment)
        }
        let isDevBuild = isDevFromIcon || normalizedSHA.isEmpty || normalizedSHA == "dev"

        return AppVersionInfo(
            shortVersion: shortVersion,
            buildNumber: buildNumber,
            commitSHA: commitSHA,
            engineVersion: engineVersion,
            repository: repository,
            isDevBuild: isDevBuild
        )
    }

    public func matchesReleaseIdentity(of other: AppVersionInfo) -> Bool {
        let lhsSHA = commitSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhsSHA = other.commitSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shaMatches = lhsSHA == rhsSHA || lhsSHA.hasPrefix(rhsSHA) || rhsSHA.hasPrefix(lhsSHA)
        return shortVersion == other.shortVersion && buildNumber == other.buildNumber && shaMatches
    }

    public static func installedUpdateToken(for version: AppVersionInfo, remote: ReleaseManifest) -> String {
        let sha = version.commitSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dmgDigest = remote.dmgSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !dmgDigest.isEmpty {
            return "\(version.shortVersion)|\(version.buildNumber)|\(sha)|sha256:\(dmgDigest)"
        }
        let remoteSHA = remote.commitSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(version.shortVersion)|\(version.buildNumber)|\(sha)|manifest:\(remote.version)|\(remote.buildNumber)|\(remoteSHA)"
    }

    public var displayString: String {
        let shaSuffix = commitSHA.isEmpty ? "" : ", \(commitSHA.prefix(7))"
        return "v\(shortVersion) (Build #\(buildNumber)\(shaSuffix))"
    }
}
