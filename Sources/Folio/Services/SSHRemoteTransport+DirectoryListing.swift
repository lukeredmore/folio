import Foundation

extension SSHRemoteTransport {
    /// Shell `case` pattern that matches names with one of `extensions`, case-insensitively.
    static func documentNameCasePattern(for extensions: Set<String>) -> String {
        guard !extensions.isEmpty else { return "__folio_no_documents__" }
        return extensions.sorted().map { ext in
            "*."
                + ext.map { char in
                    let lower = char.lowercased()
                    let upper = char.uppercased()
                    return lower == upper ? String(char) : "[\(lower)\(upper)]"
                }.joined()
        }.joined(separator: "|")
    }

    public func listDirectories(
        _ relativePaths: [String],
        fileExtensions: Set<String>,
        for mount: RemoteMountSpec
    ) async throws -> [RemoteDirectoryListing] {
        guard mount.targetKind == .folder, !relativePaths.isEmpty else { return [] }
        let calls = relativePaths.map { path in
            "list_dir \(Self.shellQuote(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))"
        }.joined(separator: "\n")
        let remoteScript = """
            TARGET=\(Self.shellEscapePath(mount.remotePath))
            if [ ! -d "$TARGET" ]; then
                echo "__FOLIO_ERR_NOT_FOUND__" >&2
                exit 44
            fi
            cd "$TARGET" || exit 44
            list_dir() {
                if [ -z "$1" ]; then D=.; else D="$1"; fi
                if [ ! -d "$D" ]; then
                    printf "===FOLIO_MISSING===\\t%s\\n" "$1"
                    return 0
                fi
                printf "===FOLIO_DIR===\\t%s\\n" "$1"
                for f in "$D"/*; do
                    NAME=${f##*/}
                    if [ -d "$f" ]; then
                        printf "D\\t%s\\n" "$NAME"
                    elif [ -f "$f" ]; then
                        case "$NAME" in
                            \(Self.documentNameCasePattern(for: fileExtensions))) ;;
                            *) continue ;;
                        esac
                        STAT=$(stat -c '%Y %s' "$f" 2>/dev/null || stat -f '%m %z' "$f" 2>/dev/null || echo '0 0')
                        printf "F\\t%s\\t%s\\n" "$NAME" "$STAT"
                    fi
                done
            }
            \(calls)
            """

        let (stdout, stderr, status) = try await runSSHScript(for: mount, script: remoteScript)
        guard status == 0 else {
            throw mapSSHError(mount: mount, status: status, stderr: stderr)
        }
        return Self.parseDirectoryListingOutput(stdout)
    }

    /// `find` arguments that prune hidden, ignored, and excluded folders, then print shown documents.
    static func probeFindArguments(fileExtensions: Set<String>, excludedPaths: Set<String>) -> String {
        let pruneNames = ["'.*'", "'bazel-*'", "'*.app'"] + WorkspaceFileNode.ignoredDirectoryNames.sorted().map(shellQuote)
        let prunes = pruneNames.map { "-name \($0)" } + excludedPaths.sorted().map { "-path \(shellQuote($0))" }
        let names = fileExtensions.sorted().map { "-iname \(shellQuote("*." + $0))" }
        return "\\( \(prunes.joined(separator: " -o ")) \\) -prune -o -type f \\( \(names.joined(separator: " -o ")) \\) -print"
    }

    public func probeDirectories(
        _ relativePaths: [String],
        fileExtensions: Set<String>,
        excludedPaths: Set<String>,
        for mount: RemoteMountSpec
    ) async throws -> [String: Bool] {
        guard mount.targetKind == .folder, !relativePaths.isEmpty else { return [:] }
        guard !fileExtensions.isEmpty else {
            return Dictionary(uniqueKeysWithValues: relativePaths.map { ($0, false) })
        }
        let calls = relativePaths.map { "probe_dir \(Self.shellQuote($0))" }.joined(separator: "\n")
        let remoteScript = """
            TARGET=\(Self.shellEscapePath(mount.remotePath))
            if [ ! -d "$TARGET" ]; then
                echo "__FOLIO_ERR_NOT_FOUND__" >&2
                exit 44
            fi
            cd "$TARGET" || exit 44
            if find . -maxdepth 0 -quit 2>/dev/null; then QUIT=-quit; else QUIT=; fi
            probe_dir() {
                FOUND=0
                if [ -d "$1" ] && [ -n "$(find -H "$1" \(Self.probeFindArguments(fileExtensions: fileExtensions, excludedPaths: excludedPaths)) $QUIT 2>/dev/null | head -n 1)" ]; then
                    FOUND=1
                fi
                printf "===FOLIO_PROBE===\\t%s\\t%s\\n" "$1" "$FOUND"
            }
            \(calls)
            """

        let (stdout, stderr, status) = try await runSSHScript(for: mount, script: remoteScript)
        guard status == 0 else {
            throw mapSSHError(mount: mount, status: status, stderr: stderr)
        }
        return Self.parseProbeOutput(stdout)
    }

    /// Parses `probe_dir` output lines: `===FOLIO_PROBE===`, the path, then `1` or `0`.
    public static func parseProbeOutput(_ output: String) -> [String: Bool] {
        var results: [String: Bool] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, parts[0] == "===FOLIO_PROBE===" else { continue }
            results[parts.dropFirst().dropLast().joined(separator: "\t")] = parts[parts.count - 1] == "1"
        }
        return results
    }

    /// Parses `list_dir` output: one header line per directory, then its `D` and `F` entry lines.
    public static func parseDirectoryListingOutput(_ output: String) -> [RemoteDirectoryListing] {
        var listings: [RemoteDirectoryListing] = []
        var currentPath: String?
        var subdirectories: [String] = []
        var files: [RemoteFileStat] = []

        func finishCurrent() {
            if let path = currentPath {
                listings.append(RemoteDirectoryListing(relativePath: path, exists: true, subdirectoryNames: subdirectories, files: files))
            }
            currentPath = nil
            subdirectories = []
            files = []
        }

        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            switch parts.first {
            case "===FOLIO_DIR===" where parts.count >= 2:
                finishCurrent()
                currentPath = parts.dropFirst().joined(separator: "\t")
            case "===FOLIO_MISSING===" where parts.count >= 2:
                finishCurrent()
                listings.append(
                    RemoteDirectoryListing(
                        relativePath: parts.dropFirst().joined(separator: "\t"),
                        exists: false,
                        subdirectoryNames: [],
                        files: []
                    ))
            case "D" where parts.count >= 2 && currentPath != nil:
                subdirectories.append(parts.dropFirst().joined(separator: "\t"))
            case "F" where parts.count >= 3 && currentPath != nil:
                let name = parts.dropFirst().dropLast().joined(separator: "\t")
                let stat = parts[parts.count - 1].split(separator: " ")
                let mtime = stat.first.flatMap { TimeInterval($0) } ?? 0
                let size = stat.count > 1 ? Int(stat[1]) ?? 0 : 0
                files.append(RemoteFileStat(name: name, modificationTimestamp: mtime, size: size))
            default:
                continue
            }
        }
        finishCurrent()
        return listings
    }
}
