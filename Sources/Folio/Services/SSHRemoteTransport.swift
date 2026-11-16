import CryptoKit
import Darwin
import Foundation

// MARK: - Multiplexed OpenSSH Transport

private final class SSHSubprocessController: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var stdoutData = Data()
    private var stderrData = Data()

    init(process: Process) {
        self.process = process
    }

    func startAndCheckCancellation() throws {
        try process.run()
        lock.lock()
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        lock.unlock()
        if running {
            process.terminate()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func setStdout(_ data: Data) {
        lock.lock()
        stdoutData = data
        lock.unlock()
    }

    func setStderr(_ data: Data) {
        lock.lock()
        stderrData = data
        lock.unlock()
    }

    func snapshotOutputs() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData)
    }
}

public struct SSHRemoteTransport: RemoteFileTransport {
    public let connectTimeoutSeconds: Int
    package let sshExecutableURL: URL

    public init(connectTimeoutSeconds: Int = 6) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.sshExecutableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    }

    package init(connectTimeoutSeconds: Int = 6, sshExecutableURL: URL) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.sshExecutableURL = sshExecutableURL
    }

    package func controlSocketPath(for mount: RemoteMountSpec) -> String {
        let rawKey = "\(mount.sshDestination):\(mount.port ?? 22)"
        let hash = SHA256.hash(data: Data(rawKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return FolioAppIdentity.current.sshControlSocketPath(hash: hash)
    }

    package func baseSSHArguments(for mount: RemoteMountSpec) -> [String] {
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
        args.append(contentsOf: ["--", mount.sshDestination])
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

    /// Quotes a mount-relative path for a POSIX shell. It never expands `~`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell function `fetch_file PATH LABEL`: prints one snapshot record for PATH, named LABEL.
    static let fetchFileFunction = """
        fetch_file() {
            [ -f "$1" ] || return 0
            MTIME=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
            printf "===FOLIO_FILE===\\t%s\\t%s\\n" "$2" "$MTIME"
            base64 < "$1" | tr -d '\\r\\n'
            printf "\\n===FOLIO_END===\\n"
        }
        """

    public func fetchFiles(_ relativePaths: [String], for mount: RemoteMountSpec) async throws -> [RemoteFileEntry] {
        let escapedTarget = Self.shellEscapePath(mount.remotePath)
        let calls: String
        let directoryCheck: String
        switch mount.targetKind {
        case .file:
            guard !relativePaths.isEmpty else { return [] }
            directoryCheck = """
                if [ ! -f "$TARGET" ]; then
                    echo "__FOLIO_ERR_NOT_FOUND__" >&2
                    exit 44
                fi
                """
            calls = "fetch_file \"$TARGET\" \"$(basename \"$TARGET\")\""
        case .folder:
            let cleanPaths = relativePaths.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
            guard !cleanPaths.isEmpty else { return [] }
            directoryCheck = """
                if [ ! -d "$TARGET" ]; then
                    echo "__FOLIO_ERR_NOT_FOUND__" >&2
                    exit 44
                fi
                cd "$TARGET" || exit 44
                """
            calls = cleanPaths.map { "fetch_file \(Self.shellQuote($0)) \(Self.shellQuote($0))" }.joined(separator: "\n")
        }
        let remoteScript = """
            TARGET=\(escapedTarget)
            \(directoryCheck)
            \(Self.fetchFileFunction)
            \(calls)
            """

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

    package static func makePushRemoteScript(targetFileExpr: String) -> String {
        """
        TARGET=\(targetFileExpr)
        DIR=$(dirname "$TARGET")
        mkdir -p "$DIR" || exit 45
        TMP="$TARGET.folio_tmp.$$"
        if (base64 -d 2>/dev/null || base64 -D) > "$TMP"; then
            :
        else
            rm -f "$TMP"
            exit 45
        fi
        if mv -f "$TMP" "$TARGET"; then
            :
        else
            rm -f "$TMP"
            exit 45
        fi
        MTIME=$(date -r "$TARGET" +%s 2>/dev/null || stat -c %Y "$TARGET" 2>/dev/null || stat -f %m "$TARGET" 2>/dev/null || date +%s)
        printf "%s\\n" "$MTIME"
        """
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
        let remoteScript = Self.makePushRemoteScript(targetFileExpr: targetFileExpr)

        let (stdout, stderr, status) = try await runSSHScript(
            for: mount,
            script: remoteScript,
            stdinData: Data(b64Payload.utf8)
        )
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

    package func runSSHScript(
        for mount: RemoteMountSpec,
        script: String,
        stdinData: Data? = nil
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        try Task.checkCancellation()
        let sshArgs: [String]
        let inputData: Data
        if let stdinData {
            sshArgs = baseSSHArguments(for: mount) + ["sh -c \(Self.shellQuote(script))"]
            inputData = stdinData
        } else {
            sshArgs = baseSSHArguments(for: mount) + ["sh", "-s"]
            inputData = Data(script.utf8)
        }

        let process = Process()
        process.executableURL = sshExecutableURL
        process.arguments = sshArgs

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinWrite = stdinPipe.fileHandleForWriting
        let stdoutRead = stdoutPipe.fileHandleForReading
        let stderrRead = stderrPipe.fileHandleForReading
        _ = fcntl(stdinWrite.fileDescriptor, F_SETNOSIGPIPE, 1)

        let controller = SSHSubprocessController(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ioGroup = DispatchGroup()
                ioGroup.enter()
                ioGroup.enter()
                ioGroup.enter()

                process.terminationHandler = { terminatedProcess in
                    let status = terminatedProcess.terminationStatus
                    ioGroup.notify(queue: .global(qos: .userInitiated)) {
                        if controller.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let outputs = controller.snapshotOutputs()
                        continuation.resume(
                            returning: (
                                stdout: String(data: outputs.stdout, encoding: .utf8) ?? "",
                                stderr: String(data: outputs.stderr, encoding: .utf8) ?? "",
                                status: status
                            ))
                    }
                }

                do {
                    try controller.startAndCheckCancellation()
                } catch {
                    process.terminationHandler = nil
                    ioGroup.leave()
                    ioGroup.leave()
                    ioGroup.leave()
                    try? stdinWrite.close()
                    try? stdoutRead.close()
                    try? stderrRead.close()
                    continuation.resume(throwing: error)
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { ioGroup.leave() }
                    if !inputData.isEmpty {
                        try? stdinWrite.write(contentsOf: inputData)
                    }
                    try? stdinWrite.close()
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { ioGroup.leave() }
                    let data = (try? stdoutRead.readToEnd()) ?? Data()
                    controller.setStdout(data)
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { ioGroup.leave() }
                    let data = (try? stderrRead.readToEnd()) ?? Data()
                    controller.setStderr(data)
                }
            }
        } onCancel: {
            controller.cancel()
        }
    }
}
