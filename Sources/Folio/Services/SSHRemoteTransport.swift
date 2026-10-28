import CryptoKit
import Foundation

// MARK: - Multiplexed OpenSSH Transport

public struct SSHRemoteTransport: RemoteFileTransport {
    public let connectTimeoutSeconds: Int

    public init(connectTimeoutSeconds: Int = 6) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    func controlSocketPath(for mount: RemoteMountSpec) -> String {
        let rawKey = "\(mount.sshDestination):\(mount.port ?? 22)"
        let hash = SHA256.hash(data: Data(rawKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "/tmp/folio-ssh-\(hash).sock"
    }

    func baseSSHArguments(for mount: RemoteMountSpec) -> [String] {
        let lowerHost = mount.host.lowercased()
        let isLoopback = lowerHost == "localhost" || lowerHost == "127.0.0.1" || lowerHost == "::1"
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=120",
            "-o", "ControlPath=\(controlSocketPath(for: mount))",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2"
        ]
        if isLoopback {
            args.append(contentsOf: [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR"
            ])
        } else {
            args.append(contentsOf: [
                "-o", "StrictHostKeyChecking=accept-new"
            ])
        }
        if let port = mount.port, port > 0 {
            args.append(contentsOf: ["-p", "\(port)"])
        }
        if let identity = mount.identityFile, !identity.isEmpty {
            let expanded = (identity as NSString).expandingTildeInPath
            args.append(contentsOf: ["-i", expanded])
        }
        args.append(mount.sshDestination)
        return args
    }

    /// Escapes a path for safe single-quoted POSIX shell usage, while allowing leading `~` expansion.
    public static func shellEscapePath(_ path: String) -> String {
        if path == "~" {
            return "\"$HOME\""
        }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            let escapedRest = rest.replacingOccurrences(of: "'", with: "'\\''")
            return "\"$HOME\"/'\(escapedRest)'"
        }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    public func fetchSnapshot(for mount: RemoteMountSpec) async throws -> [RemoteFileEntry] {
        let escapedTarget = Self.shellEscapePath(mount.remotePath)

        let remoteScript: String
        switch mount.targetKind {
        case .file:
            remoteScript = """
                TARGET=\(escapedTarget)
                if [ ! -f "$TARGET" ]; then
                    echo "__FOLIO_ERR_NOT_FOUND__" >&2
                    exit 44
                fi
                BASENAME=$(basename "$TARGET")
                MTIME=$(date -r "$TARGET" +%s 2>/dev/null || stat -c %Y "$TARGET" 2>/dev/null || stat -f %m "$TARGET" 2>/dev/null || echo 0)
                printf "===FOLIO_FILE===\\t%s\\t%s\\n" "$BASENAME" "$MTIME"
                base64 < "$TARGET" | tr -d '\\r\\n'
                printf "\\n===FOLIO_END===\\n"
                """
        case .folder:
            remoteScript = """
                TARGET=\(escapedTarget)
                if [ ! -d "$TARGET" ]; then
                    echo "__FOLIO_ERR_NOT_FOUND__" >&2
                    exit 44
                fi
                cd "$TARGET" || exit 44
                find . -maxdepth 4 \\( -name .git -o -name node_modules -o -name target -o -name .build -o -name DerivedData -o -name dist -o -name build \\) -prune -o -type f \\( -iname '*.md' -o -iname '*.markdown' -o -iname '*.mdown' -o -iname '*.mkd' -o -iname '*.txt' \\) -print | while IFS= read -r f; do
                    REL="${f#./}"
                    MTIME=$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
                    printf "===FOLIO_FILE===\\t%s\\t%s\\n" "$REL" "$MTIME"
                    base64 < "$f" | tr -d '\\r\\n'
                    printf "\\n===FOLIO_END===\\n"
                done
                """
        }

        let (stdout, stderr, status) = try await runSSHScript(for: mount, script: remoteScript)
        guard status == 0 else {
            throw mapSSHError(mount: mount, status: status, stderr: stderr)
        }

        return Self.parseSnapshotOutput(stdout)
    }

    public static func parseSnapshotOutput(_ output: String) -> [RemoteFileEntry] {
        var entries: [RemoteFileEntry] = []
        let lines = output.components(separatedBy: "\n")
        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("===FOLIO_FILE===\t") {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 3 else {
                    idx += 1
                    continue
                }
                let relPath = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let mtime = TimeInterval(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date().timeIntervalSince1970
                idx += 1
                var b64Chunks: [String] = []
                while idx < lines.count && lines[idx] != "===FOLIO_END===" {
                    b64Chunks.append(lines[idx].trimmingCharacters(in: .whitespacesAndNewlines))
                    idx += 1
                }
                let joinedB64 = b64Chunks.joined()
                let decodedData = Data(base64Encoded: joinedB64) ?? Data()
                let text = String(data: decodedData, encoding: .utf8) ?? ""
                if !relPath.isEmpty {
                    entries.append(
                        RemoteFileEntry(
                            relativePath: relPath,
                            modificationTimestamp: mtime,
                            content: text
                        ))
                }
            }
            idx += 1
        }
        return entries
    }

    public func pushFile(content: String, relativePath: String, for mount: RemoteMountSpec) async throws -> TimeInterval {
        let targetFileExpr: String
        switch mount.targetKind {
        case .file:
            targetFileExpr = Self.shellEscapePath(mount.remotePath)
        case .folder:
            let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let combined = (mount.remotePath as NSString).appendingPathComponent(cleanRel)
            targetFileExpr = Self.shellEscapePath(combined)
        }

        let b64Payload = Data(content.utf8).base64EncodedString()
        let remoteScript = """
            TARGET=\(targetFileExpr)
            DIR=$(dirname "$TARGET")
            mkdir -p "$DIR" || exit 45
            TMP="$TARGET.folio_tmp.$$"
            base64 -d > "$TMP" << '__FOLIO_B64_EOF__'
            \(b64Payload)
            __FOLIO_B64_EOF__
            if [ $? -ne 0 ]; then
                base64 -D > "$TMP" << '__FOLIO_B64_EOF__'
            \(b64Payload)
            __FOLIO_B64_EOF__
            fi
            mv -f "$TMP" "$TARGET" || exit 45
            MTIME=$(date -r "$TARGET" +%s 2>/dev/null || stat -c %Y "$TARGET" 2>/dev/null || stat -f %m "$TARGET" 2>/dev/null || date +%s)
            printf "%s\\n" "$MTIME"
            """

        let (stdout, stderr, status) = try await runSSHScript(for: mount, script: remoteScript)
        guard status == 0 else {
            throw mapSSHError(mount: mount, status: status, stderr: stderr)
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeInterval(trimmed) ?? Date().timeIntervalSince1970
    }

    public func deleteFile(relativePath: String, for mount: RemoteMountSpec) async throws {
        let targetFileExpr: String
        switch mount.targetKind {
        case .file:
            targetFileExpr = Self.shellEscapePath(mount.remotePath)
        case .folder:
            let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let combined = (mount.remotePath as NSString).appendingPathComponent(cleanRel)
            targetFileExpr = Self.shellEscapePath(combined)
        }

        let remoteScript = "rm -f \(targetFileExpr)"
        let (_, stderr, status) = try await runSSHScript(for: mount, script: remoteScript)
        guard status == 0 else {
            throw mapSSHError(mount: mount, status: status, stderr: stderr)
        }
    }

    func mapSSHError(mount: RemoteMountSpec, status: Int32, stderr: String) -> RemoteWorkspaceError {
        let cleanErr =
            stderr
            .replacingOccurrences(of: "__FOLIO_ERR_NOT_FOUND__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 44 || stderr.contains("__FOLIO_ERR_NOT_FOUND__") {
            return .remotePathNotFound(path: mount.remotePath)
        }
        if status == 45 || cleanErr.lowercased().contains("permission denied") {
            return .permissionDenied(path: mount.remotePath)
        }
        if cleanErr.lowercased().contains("timed out") || cleanErr.lowercased().contains("operation timed out") {
            return .transportTimeout(host: mount.host)
        }
        let fallback = cleanErr.isEmpty ? "SSH exited with code \(status)" : cleanErr
        return .connectionFailed(host: mount.host, details: fallback)
    }

    func runSSHScript(
        for mount: RemoteMountSpec,
        script: String
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let sshArgs = baseSSHArguments(for: mount) + ["sh", "-s"]
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArgs

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            if let scriptData = script.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(scriptData)
            }
            stdinPipe.fileHandleForWriting.closeFile()

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return (
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                status: process.terminationStatus
            )
        }.value
    }
}
