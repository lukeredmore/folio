import AppKit
import SwiftUI

extension EditorSettingsView {

    @ViewBuilder
    var remoteMediaAndAuthSection: some View {
        let hasCustomAuth =
            viewModel.mediaCurlCommandPrefix != FolioMediaImageCache.defaultCurlCommandPrefix
            || viewModel.useSSHAuthForMedia
            || !viewModel.mediaSSHIdentityFile.isEmpty
            || !viewModel.mediaSSHUser.isEmpty

        settingsCard(
            title: "REMOTE MEDIA & AUTHENTICATION",
            trailingHeader: {
                HStack(spacing: 8) {
                    Button("Reload Remote Images") {
                        viewModel.reloadRemoteMediaImages()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.accentColor)

                    if hasCustomAuth {
                        Button("Reset to Default") {
                            viewModel.resetMediaCurlCommandPrefixToDefault()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                    }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Custom curl Command Prefix")
                        .font(.system(size: 12, weight: .medium))

                    TextField("curl -b \"session=...\" -H \"Authorization: Bearer ...\"", text: $viewModel.mediaCurlCommandPrefix)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))

                    Text(
                        "Replaces the start of the `curl` command used to fetch `http://`, `https://`, `sftp://`, and `scp://` images. Add auth cookies (`-b`), headers (`-H`), or paste a browser \"Copy as cURL\" snippet; Folio appends the image URL automatically."
                    )
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Use SSH Auth from Remote Host Access (--key / -u)",
                        isOn: $viewModel.useSSHAuthForMedia
                    )
                    .font(.system(size: 12))

                    if viewModel.useSSHAuthForMedia {
                        if !viewModel.remoteWorkspaceManager.mounts.isEmpty {
                            HStack(spacing: 6) {
                                Text("Connected Remotes:")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 5) {
                                        ForEach(viewModel.remoteWorkspaceManager.mounts) { mount in
                                            Button {
                                                viewModel.applySSHAuthFromMount(mount)
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "key.fill")
                                                        .font(.system(size: 9))
                                                    Text(mount.sshDestination)
                                                        .font(.system(size: 10.5, design: .monospaced))
                                                }
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 5)
                                                        .fill(Color.accentColor.opacity(0.12))
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .help("Apply SSH user and identity key from \(mount.connectionString)")
                                        }
                                    }
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("SSH User (-u)")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                TextField(
                                    viewModel.remoteWorkspaceManager.mounts.first?.user ?? "Auto from Remote Mount / URL",
                                    text: $viewModel.mediaSSHUser
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 145)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("SSH Identity Key (--key)")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                HStack(spacing: 5) {
                                    TextField(
                                        viewModel.remoteWorkspaceManager.mounts.first?.identityFile ?? "~/.ssh/id_ed25519 (auto)",
                                        text: $viewModel.mediaSSHIdentityFile
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))

                                    Button("Browse…") {
                                        browseMediaSSHIdentityKeyFile()
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }

                        Text(
                            "Automatically passes `-u '<user>:'` and `--key '<identityFile>'` from your connected Remote Host Access mount (or `~/.ssh`) directly to `curl` for `sftp://` and `scp://` image URLs."
                        )
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func browseMediaSSHIdentityKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.prompt = "Select SSH Key"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.mediaSSHIdentityFile = url.path
        }
    }
}
