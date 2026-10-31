import AppKit
import SwiftUI

public struct AddRemoteMountModalView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager

    /// The `RemoteHostProfile.id` of the chosen recent host, or `newHostTag`.
    @State private var hostSelection: String = Self.newHostTag
    @State private var newHostInput: String = ""
    @State private var pathInput: String = ""
    @State private var targetKind: RemoteMountTargetKind = .folder
    @State private var targetKindManuallyChosen: Bool = false
    @State private var portInput: String = "22"
    @State private var identityFileInput: String = ""
    @State private var displayNameInput: String = ""
    @State private var isAdvancedExpanded: Bool = false
    @State private var isConnectedExpanded: Bool = false
    @State private var isConnecting: Bool = false
    @State private var validationError: String?

    private static let newHostTag = "new-host"
    private static let scrollingMountCount = 5

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self.remoteManager = viewModel.remoteWorkspaceManager
    }

    private var recentHosts: [RemoteHostProfile] { remoteManager.recentHosts }

    private var selectedHost: RemoteHostProfile? {
        recentHosts.first { $0.id == hostSelection }
    }

    private var destinationInput: String {
        selectedHost?.destination ?? newHostInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            connectionFields
            if !remoteManager.mounts.isEmpty {
                Divider()
                connectedMounts
            }
            footer
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let latest = recentHosts.first {
                hostSelection = latest.id
                applyHostSettings(latest)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below.fill")
                .font(.system(size: 20))
                .foregroundColor(viewModel.theme.linkColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect Remote Folder")
                    .font(.headline)
                Text("Files sync to a local cache over SSH.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    fieldLabel("Host")
                    hostField
                }
                GridRow {
                    fieldLabel("Path")
                    HStack(spacing: 8) {
                        TextField("Path", text: $pathInput, prompt: Text("~/notes"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .labelsHidden()
                            .onChange(of: pathInput) { _, newValue in
                                validationError = nil
                                if !targetKindManuallyChosen {
                                    targetKind = RemoteMountSpec.inferredTargetKind(forRemotePath: newValue)
                                }
                            }
                            .onSubmit { connectRemote() }
                        Picker("Type", selection: targetKindBinding) {
                            Text("Folder").tag(RemoteMountTargetKind.folder)
                            Text("File").tag(RemoteMountTargetKind.file)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        fieldLabel("Port")
                        TextField("Port", text: $portInput, prompt: Text("22"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .labelsHidden()
                            .frame(width: 70)
                    }
                    GridRow {
                        fieldLabel("Key")
                        HStack(spacing: 6) {
                            TextField("Key", text: $identityFileInput, prompt: Text("~/.ssh/config and ssh-agent"))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .labelsHidden()
                            Button("Browse…") { browseIdentityKeyFile() }
                        }
                    }
                    GridRow {
                        fieldLabel("Label")
                        TextField("Label", text: $displayNameInput, prompt: Text("Folder name"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                }
                .padding(.top, 6)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var hostField: some View {
        let newHostField = TextField("Host", text: $newHostInput, prompt: Text("user@host"))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .labelsHidden()
            .onChange(of: newHostInput) { _, _ in validationError = nil }
            .onSubmit { connectRemote() }
        if recentHosts.isEmpty {
            newHostField
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Host", selection: $hostSelection) {
                    ForEach(recentHosts) { host in
                        Text(host.id).tag(host.id)
                    }
                    Divider()
                    Text("New Host…").tag(Self.newHostTag)
                }
                .labelsHidden()
                .onChange(of: hostSelection) { _, _ in
                    validationError = nil
                    if let selectedHost { applyHostSettings(selectedHost) }
                }
                if hostSelection == Self.newHostTag {
                    newHostField
                }
            }
        }
    }

    private var connectedMounts: some View {
        DisclosureGroup(isExpanded: $isConnectedExpanded) {
            if remoteManager.mounts.count > Self.scrollingMountCount {
                ScrollView { mountGroups }
                    .frame(height: 220)
            } else {
                mountGroups
            }
        } label: {
            HStack {
                Text("Connected (\(remoteManager.mounts.count))")
                Spacer()
                Button("Sync All") {
                    Task { await remoteManager.syncAllMounts(isBackground: false) }
                }
                .controlSize(.small)
            }
        }
    }

    private var mountGroups: some View {
        let groups = Dictionary(grouping: remoteManager.mounts) { RemoteHostProfile(mount: $0).id }
        let hostIDs = remoteManager.mounts.map { RemoteHostProfile(mount: $0).id }.uniqued()
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(hostIDs, id: \.self) { hostID in
                VStack(alignment: .leading, spacing: 2) {
                    Text(hostID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(groups[hostID] ?? []) { mount in
                        mountRow(mount)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func mountRow(_ mount: RemoteMountSpec) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mount.targetKind == .folder ? "folder" : "doc.text")
                .foregroundStyle(viewModel.theme.linkColor)
                .frame(width: 16)
            Text(mount.folderName)
                .lineLimit(1)
            Text(mount.remotePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(mount.connectionSpecString)
            Spacer(minLength: 4)
            RemoteConnectionStateIcon(
                state: remoteManager.connectionStates[mount.id] ?? .connected,
                accentColor: viewModel.theme.linkColor
            )
            Button {
                Task { await remoteManager.syncMount(id: mount.id, isBackground: false) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Sync Now")
            Button {
                viewModel.disconnectRemoteMount(id: mount.id)
            } label: {
                Image(systemName: "eject")
            }
            .buttonStyle(.borderless)
            .help("Disconnect")
        }
        .padding(.vertical, 3)
    }

    private var footer: some View {
        HStack {
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") {
                viewModel.showAddRemoteModal = false
            }
            .keyboardShortcut(.cancelAction)
            Button("Connect") {
                connectRemote()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(destinationInput.isEmpty || isConnecting)
        }
    }

    // MARK: - Helpers

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var targetKindBinding: Binding<RemoteMountTargetKind> {
        Binding(
            get: { targetKind },
            set: { newKind in
                targetKind = newKind
                targetKindManuallyChosen = true
            }
        )
    }

    private func applyHostSettings(_ host: RemoteHostProfile) {
        portInput = String(host.port ?? 22)
        identityFileInput = host.identityFile ?? ""
    }

    private func connectRemote() {
        guard !destinationInput.isEmpty, !isConnecting else { return }
        let port = Int(portInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
        let keyPath = identityFileInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let customLabel = displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let spec = try RemoteMountSpec.parse(
                destination: destinationInput,
                path: pathInput,
                targetKind: targetKindManuallyChosen ? targetKind : nil,
                portOverride: port == 22 ? nil : port,
                identityFilePath: keyPath.isEmpty ? nil : keyPath,
                displayName: customLabel.isEmpty ? nil : customLabel
            )
            validationError = nil
            isConnecting = true
            Task {
                await viewModel.connectRemoteMount(spec)
                isConnecting = false
                pathInput = ""
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

extension Array where Element: Hashable {
    /// The elements in order, without repeats.
    fileprivate func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
