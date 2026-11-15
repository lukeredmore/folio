import Darwin
import Foundation

public enum FolioCLIImmediateAction: Equatable {
    case printHelp(String)
    case printVersion(String)
}

public struct FolioCLIOpenRequest: Equatable, Sendable {
    public var paths: [String]
    public var waitTokenPath: String?

    public init(paths: [String], waitTokenPath: String? = nil) {
        self.paths = paths
        self.waitTokenPath = waitTokenPath
    }
}

extension FolioCLIManager {

    public static var helpText: String {
        """
        Usage: folio [options] [path[:line[:column]] ...]

        Open files or folders in Folio.

        Options:
          -n, --new          Open in a new Folio instance
          -a, --add          Open in the existing Folio instance
          -w, --wait         Wait for files to be closed before returning
              --foreground   Run Folio in the foreground attached to the terminal
          -v, --version      Print the Folio version and exit
          -h, --help         Print this help message and exit
        """
    }

    public static func resolveVersionString(
        bundleInfoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        if let shortVersion = bundleInfoDictionary?["CFBundleShortVersionString"] as? String,
            !shortVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return shortVersion
        }
        return "1.0.0"
    }

    public static func evaluateImmediateCLIAction(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundleInfoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> FolioCLIImmediateAction? {
        guard arguments.count > 1 else { return nil }
        var skipNext = false
        for arg in arguments.dropFirst() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" { break }
            if arg == "--wait-token" {
                skipNext = true
                continue
            }
            if arg == "-h" || arg == "--help" {
                return .printHelp(helpText)
            }
            if arg == "-v" || arg == "--version" {
                return .printVersion("folio \(resolveVersionString(bundleInfoDictionary: bundleInfoDictionary))")
            }
        }
        return nil
    }

    public static func handleImmediateCLIFlagsIfNeeded(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundleInfoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        guard
            let action = evaluateImmediateCLIAction(
                arguments: arguments,
                bundleInfoDictionary: bundleInfoDictionary
            )
        else {
            return
        }
        switch action {
        case .printHelp(let text), .printVersion(let text):
            print(text)
            fflush(stdout)
            Darwin.exit(0)
        }
    }

    /// Resolves the caller's effective working directory, honoring `FOLIO_CALLER_CWD`
    /// and Bazel's `BUILD_WORKING_DIRECTORY` when launched via `bazel run //:FolioApp -- <args>`.
    public static func effectiveWorkingDirectoryPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> String {
        for key in ["FOLIO_CALLER_CWD", "BUILD_WORKING_DIRECTORY"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            {
                return value
            }
        }
        return currentDirectoryPath
    }

    public static func splitPathAndLineColumnSuffix(
        _ rawPath: String,
        checkDiskExistence: Bool = true
    ) -> (basePath: String, lineNumber: Int?, columnNumber: Int?, rawSuffix: String?) {
        if checkDiskExistence && FileManager.default.fileExists(atPath: rawPath) {
            return (rawPath, nil, nil, nil)
        }
        let parts = rawPath.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (rawPath, nil, nil, nil) }
        if let lastNum = Int(parts[parts.count - 1]), lastNum >= 1 {
            if parts.count >= 3, let secondLastNum = Int(parts[parts.count - 2]), secondLastNum >= 1 {
                let basePath = parts.dropLast(2).joined(separator: ":")
                if !basePath.isEmpty {
                    return (basePath, secondLastNum, lastNum, ":\(secondLastNum):\(lastNum)")
                }
            }
            let basePath = parts.dropLast(1).joined(separator: ":")
            if !basePath.isEmpty {
                return (basePath, lastNum, nil, ":\(lastNum)")
            }
        }
        return (rawPath, nil, nil, nil)
    }

    public static func extractCommandLineOpenRequest(
        from arguments: [String],
        currentDirectoryPath: String = effectiveWorkingDirectoryPath()
    ) -> FolioCLIOpenRequest {
        guard arguments.count > 1 else { return FolioCLIOpenRequest(paths: []) }
        var paths: [String] = []
        var waitTokenPath: String?
        var skipNext = false
        var captureWaitTokenNext = false
        var treatRemainingAsPaths = false

        for arg in arguments.dropFirst() {
            if captureWaitTokenNext {
                captureWaitTokenNext = false
                if !arg.isEmpty {
                    waitTokenPath = arg
                }
                continue
            }
            if skipNext {
                skipNext = false
                continue
            }
            if !treatRemainingAsPaths {
                if arg == "--" {
                    treatRemainingAsPaths = true
                    continue
                }
                if arg == "--wait-token" {
                    captureWaitTokenNext = true
                    continue
                }
                if arg.hasPrefix("--wait-token=") {
                    let token = String(arg.dropFirst("--wait-token=".count))
                    if !token.isEmpty {
                        waitTokenPath = token
                    }
                    continue
                }
                if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") || arg.hasPrefix("-psn_") || arg == "-XCTest" {
                    if arg == "-NSDocumentRevisionsDebugMode" || arg == "-ApplePersistenceIgnoreState" || arg == "-XCTest" {
                        skipNext = true
                    }
                    continue
                }
                if arg.hasPrefix("-") || arg.hasSuffix(".xctest") { continue }
            }

            var cleaned = arg
            if cleaned.count >= 2,
                (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) || (cleaned.hasPrefix("'") && cleaned.hasSuffix("'"))
            {
                cleaned = String(cleaned.dropFirst().dropLast())
            }
            if cleaned.hasPrefix("file://") {
                if let fileURL = URL(string: cleaned), fileURL.isFileURL {
                    cleaned = fileURL.path
                } else {
                    cleaned = String(cleaned.dropFirst("file://".count))
                }
            }

            let (basePath, _, _, rawSuffix) = splitPathAndLineColumnSuffix(cleaned, checkDiskExistence: false)
            let expanded = (basePath as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { continue }
            let resolvedURL =
                expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded).standardizedFileURL
                : URL(fileURLWithPath: currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL
            if let suffix = rawSuffix {
                paths.append("\(resolvedURL.path)\(suffix)")
            } else {
                paths.append(resolvedURL.path)
            }
        }
        return FolioCLIOpenRequest(paths: paths, waitTokenPath: waitTokenPath)
    }

    public static func extractCommandLinePaths(
        from arguments: [String],
        currentDirectoryPath: String = effectiveWorkingDirectoryPath()
    ) -> [String] {
        extractCommandLineOpenRequest(from: arguments, currentDirectoryPath: currentDirectoryPath).paths
    }

    public static func deduplicateCommandLinePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where seen.insert(path).inserted {
            result.append(path)
        }
        return result
    }

    public static func parseQueuedOpenRequests(_ content: String) -> [FolioCLIOpenRequest] {
        let waitPrefix = "--wait-token="
        var rawRequests: [FolioCLIOpenRequest] = []

        for rawLine in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix(waitPrefix) {
                let remainder = line.dropFirst(waitPrefix.count)
                if let tabIndex = remainder.firstIndex(of: "\t") {
                    let token = String(remainder[..<tabIndex]).trimmingCharacters(in: .whitespaces)
                    let path = String(remainder[remainder.index(after: tabIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !token.isEmpty {
                        rawRequests.append(FolioCLIOpenRequest(paths: path.isEmpty ? [] : [path], waitTokenPath: token))
                    }
                } else {
                    let token = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !token.isEmpty {
                        rawRequests.append(FolioCLIOpenRequest(paths: [], waitTokenPath: token))
                    }
                }
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    rawRequests.append(FolioCLIOpenRequest(paths: [trimmed], waitTokenPath: nil))
                }
            }
        }
        return mergeOpenRequests(rawRequests)
    }

    public static func mergeOpenRequests(_ requests: [FolioCLIOpenRequest]) -> [FolioCLIOpenRequest] {
        var merged: [FolioCLIOpenRequest] = []
        var indexByKey: [String: Int] = [:]

        for request in requests {
            let cleanPaths = deduplicateCommandLinePaths(request.paths)
            if cleanPaths.isEmpty && request.waitTokenPath == nil {
                continue
            }
            let key = request.waitTokenPath.map { "wait:\($0)" } ?? "plain"
            if let existingIndex = indexByKey[key] {
                merged[existingIndex].paths = deduplicateCommandLinePaths(merged[existingIndex].paths + cleanPaths)
            } else {
                indexByKey[key] = merged.count
                merged.append(FolioCLIOpenRequest(paths: cleanPaths, waitTokenPath: request.waitTokenPath))
            }
        }
        return merged
    }
}
