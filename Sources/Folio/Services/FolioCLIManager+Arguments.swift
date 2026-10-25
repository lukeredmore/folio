import Darwin
import Foundation

public enum FolioCLIImmediateAction: Equatable {
    case printHelp(String)
    case printVersion(String)
}

extension FolioCLIManager {

    public static var helpText: String {
        """
        Usage: folio [options] [path[:line[:column]] ...]

        Open files or folders in Folio.

        Options:
          -n, --new          Open in a new Folio instance
          -a, --add          Open in the existing Folio instance
          -w, --wait         Wait for files to be opened
              --foreground   Run Folio in the foreground attached to the terminal
          -v, --version      Print the Folio version and exit
          -h, --help         Print this help message and exit
        """
    }

    public static func resolveVersionString(
        bundleInfoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        if let shortVersion = bundleInfoDictionary?["CFBundleShortVersionString"] as? String,
           !shortVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return shortVersion
        }
        return "1.0.0"
    }

    public static func evaluateImmediateCLIAction(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundleInfoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> FolioCLIImmediateAction? {
        guard arguments.count > 1 else { return nil }
        for arg in arguments.dropFirst() {
            if arg == "--" { break }
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
        guard let action = evaluateImmediateCLIAction(
            arguments: arguments,
            bundleInfoDictionary: bundleInfoDictionary
        ) else {
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
               !value.isEmpty {
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

    public static func extractCommandLinePaths(
        from arguments: [String],
        currentDirectoryPath: String = effectiveWorkingDirectoryPath()
    ) -> [String] {
        guard arguments.count > 1 else { return [] }
        var paths: [String] = []
        var skipNext = false
        var treatRemainingAsPaths = false

        for arg in arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if !treatRemainingAsPaths {
                if arg == "--" {
                    treatRemainingAsPaths = true
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
               (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) ||
               (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")) {
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
            let resolvedURL = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded).standardizedFileURL
                : URL(fileURLWithPath: currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL
            if let suffix = rawSuffix {
                paths.append("\(resolvedURL.path)\(suffix)")
            } else {
                paths.append(resolvedURL.path)
            }
        }
        return paths
    }

    public static func deduplicateCommandLinePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where seen.insert(path).inserted {
            result.append(path)
        }
        return result
    }
}
