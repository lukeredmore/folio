import AppKit
import SwiftUI

public struct AddRemoteMountModalView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager

    @State private var connectionInput: String = ""
    @State private var targetKind: RemoteMountTargetKind = .folder
    @State private var targetKindManuallyChosen: Bool = false
    @State private var portInput: String = "22"
    @State private var identityFileInput: String = ""
    @State private var displayNameInput: String = ""
    @State private var isConnecting: Bool = false
    @State private var validationError: String?

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self.remoteManager = viewModel.remoteWorkspaceManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below.fill")
                    .font(.system(size: 20))
                    .foregroundColor(viewModel.theme.linkColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Remote Folder or File (SSH / SFTP)")
                        .font(.system(size: 14.5, weight: .semibold))
                    Text("Files are mirrored to a high-speed local cache for 0ms open/search latency and synced automatically in the background.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH Destination")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("user@host:/path/to/notes  or  ssh://user@host:2222/~/notes/todo.md", text: $connectionInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                        .onChange(of: connectionInput) { _, newValue in
                            validationError = nil
                            if !targetKindManuallyChosen {
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                let ext = (trimmed as NSString).pathExtension.lowercased()
                                if ["md", "markdown", "mdown", "mkd", "txt"].contains(ext) {
                                    targetKind = .file
                                } else {
                                    targetKind = .folder
                                }
                            }
                        }
                        .onSubmit {
                            connectRemote()
                        }
                }

                HStack(spacing: 14) {
                    Picker(
                        "Mount Type",
                        selection: Binding(
                            get: { targetKind },
                            set: { newKind in
                                targetKind = newKind
                                targetKindManuallyChosen = true
                            }
                        )
                    ) {
                        Text("Remote Folder").tag(RemoteMountTargetKind.folder)
                        Text("Single File").tag(RemoteMountTargetKind.file)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)

                    HStack(spacing: 6) {
                        Text("Port:")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        TextField("22", text: $portInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 64)
                    }

                    Spacer()
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SSH Identity Key (Optional)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            TextField("~/.ssh/id_ed25519 (uses ~/.ssh/config & ssh-agent by default)", text: $identityFileInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                            Button("Browse…") {
                                browseIdentityKeyFile()
                            }
                            .controlSize(.small)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sidebar Label (Optional)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextField("e.g. Research Server", text: $displayNameInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                            .frame(width: 155)
                    }
                }

                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(.orange)
                }
            }

            if !remoteManager.mounts.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("CONNECTED REMOTES (\(remoteManager.mounts.count))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Sync All") {
                            Task {
                                await remoteManager.syncAllMounts(isBackground: false)
                            }
                        }
                        .controlSize(.mini)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(remoteManager.mounts) { mount in
                                HStack(spacing: 8) {
                                    Image(systemName: mount.targetKind == .folder ? "folder.fill" : "doc.text.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(viewModel.theme.linkColor)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(mount.label)
                                            .font(.system(size: 12, weight: .medium))
                                        Text(mount.connectionString)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    mountStateBadge(for: mount)

                                    Button("Sync") {
                                        Task {
                                            await remoteManager.syncMount(id: mount.id, isBackground: false)
                                        }
                                    }
                                    .controlSize(.mini)

                                    Button("Disconnect") {
                                        viewModel.disconnectRemoteMount(id: mount.id)
                                    }
                                    .controlSize(.mini)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary.opacity(0.08))
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                }
            }

            HStack {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Mounting & syncing initial snapshot…")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") {
                    viewModel.showAddRemoteModal = false
                }
                Button("Connect Remote") {
                    connectRemote()
                }
                .buttonStyle(.borderedProminent)
                .disabled(connectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
            }
        }
        .padding(18)
        .frame(width: 540)
    }

    @ViewBuilder
    private func mountStateBadge(for mount: RemoteMountSpec) -> some View {
        let state = remoteManager.connectionStates[mount.id] ?? .connected
        switch state {
        case .connected:
            Label("Synced", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.green)
        case .syncing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.accentColor)
        case .reconnecting(let attempt, _, _):
            Label("Retry #\(attempt)", systemImage: "wifi.exclamationmark")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.orange)
        case .error:
            Label("Offline", systemImage: "wifi.exclamationmark")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.orange)
        }
    }

    private func connectRemote() {
        let trimmed = connectionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let port = Int(portInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
        let keyPath = identityFileInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let customLabel = displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let spec = try RemoteMountSpec.parse(
                connectionString: trimmed,
                targetKind: targetKind,
                portOverride: port == 22 ? nil : port,
                identityFilePath: keyPath.isEmpty ? nil : keyPath,
                displayName: customLabel.isEmpty ? nil : customLabel
            )
            validationError = nil
            isConnecting = true
            Task {
                await viewModel.connectRemoteMount(spec)
                isConnecting = false
                connectionInput = ""
                viewModel.showAddRemoteModal = false
            }
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func browseIdentityKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.prompt = "Select SSH Key"
        if panel.runModal() == .OK, let url = panel.url {
            identityFileInput = url.path
        }
    }
}
