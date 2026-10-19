import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct QuickOpenModalView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @FocusState private var isSearchFocused: Bool

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    private var filteredFiles: [WorkspaceFileNode] {
        let q = viewModel.quickOpenQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return Array(viewModel.flatMarkdownFiles.prefix(25))
        }
        return viewModel.flatMarkdownFiles.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.url.path.localizedCaseInsensitiveContains(q) ||
            ($0.remoteConnectionString?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(viewModel.theme.linkColor)

                TextField("Search file by name (Cmd+P)...", text: $viewModel.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(viewModel.theme.textColor)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if let first = filteredFiles.first {
                            viewModel.openFile(at: first.url)
                            viewModel.showQuickOpen = false
                        }
                    }

                Button {
                    viewModel.showQuickOpen = false
                } label: {
                    Text("ESC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(viewModel.theme.borderColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .overlay(viewModel.theme.borderColor)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filteredFiles.isEmpty {
                        Text("No matching files in workspace")
                            .font(.system(size: 12.5))
                            .foregroundColor(viewModel.theme.secondaryTextColor)
                            .padding(16)
                    } else {
                        ForEach(filteredFiles) { node in
                            Button {
                                viewModel.openFile(at: node.url)
                                viewModel.showQuickOpen = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: node.isRemote ? "network" : (node.isMarkdownFile ? "doc.text.fill" : "doc"))
                                        .font(.system(size: 14))
                                        .foregroundColor(viewModel.theme.linkColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(viewModel.theme.textColor)
                                        Text(node.remoteConnectionString ?? node.url.deletingLastPathComponent().path)
                                            .font(.system(size: 10.5))
                                            .foregroundColor(viewModel.theme.secondaryTextColor)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(viewModel.currentFileURL == node.url ? viewModel.theme.linkColor.opacity(0.15) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 500)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(viewModel.theme.sidebarBackgroundColor)
                .shadow(color: Color.black.opacity(0.28), radius: 20, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(viewModel.theme.borderColor, lineWidth: 1)
        )
        .onAppear {
            isSearchFocused = true
        }
    }
}

public struct WordCountPopoverView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DOCUMENT STATISTICS")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Reading Time")
                        .foregroundColor(.secondary)
                    Text(viewModel.stats.readingTimeString)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Words")
                        .foregroundColor(.secondary)
                    Text("\(viewModel.stats.words)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Lines")
                        .foregroundColor(.secondary)
                    Text("\(viewModel.stats.lines)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Characters")
                        .foregroundColor(.secondary)
                    Text("\(viewModel.stats.characters)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Without Spaces")
                        .foregroundColor(.secondary)
                    Text("\(viewModel.stats.charactersWithoutSpaces)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                if viewModel.stats.selectedCharacters > 0 {
                    Divider()
                    GridRow {
                        Text("Selected Words")
                            .foregroundColor(.secondary)
                        Text("\(viewModel.stats.selectedWords)")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Selected Chars")
                            .foregroundColor(.secondary)
                        Text("\(viewModel.stats.selectedCharacters)")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
            }
            .font(.system(size: 12.5))
        }
        .padding(14)
        .frame(width: 230)
    }
}

public struct InsertTableModalView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @State private var rows: Int = 3
    @State private var columns: Int = 3

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Table")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 16) {
                Stepper("Rows: \(rows)", value: $rows, in: 1...25)
                Stepper("Columns: \(columns)", value: $columns, in: 1...10)
            }
            .font(.system(size: 12.5))

            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.showInsertTableSheet = false
                }
                Button("Insert") {
                    viewModel.insertTable(rows: rows, columns: columns)
                    viewModel.showInsertTableSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

public struct FindReplaceBannerView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundColor(viewModel.theme.secondaryTextColor)

            TextField("Find in document...", text: $viewModel.findQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 180)
                .onSubmit {
                    viewModel.findNextInDocument()
                }

            TextField("Replace with...", text: $viewModel.replaceQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 160)

            Button("Next") {
                viewModel.findNextInDocument()
            }
            .controlSize(.small)

            Button("Replace") {
                viewModel.replaceCurrentMatch()
            }
            .controlSize(.small)

            Button("Replace All") {
                viewModel.replaceAllInDocument()
            }
            .controlSize(.small)

            Spacer()

            Button {
                viewModel.showFindReplaceBar = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(viewModel.theme.sidebarBackgroundColor)
        .overlay(alignment: .bottom) {
            Divider().overlay(viewModel.theme.borderColor)
        }
    }
}

public struct StatusBarView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self.remoteManager = viewModel.remoteWorkspaceManager
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Left: Sidebar toggle & Source Code Mode toggle
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    viewModel.showSidebar.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12.5))
                    .foregroundColor(viewModel.showSidebar ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar (Cmd+Shift+L)")

            Button {
                viewModel.sourceCodeMode.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11.5))
                    if viewModel.sourceCodeMode {
                        Text("Exit Source Code Mode")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundColor(viewModel.sourceCodeMode ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("Toggle Source Code Mode (Cmd+/)")

            // Active mode badges (Focus Mode / Typewriter Mode)
            if viewModel.focusMode {
                modeBadge(title: "Focus Mode", icon: "eye") {
                    viewModel.focusMode = false
                }
            }
            if viewModel.typewriterMode {
                modeBadge(title: "Typewriter", icon: "align.vertical.center") {
                    viewModel.typewriterMode = false
                }
            }

            if let fileURL = viewModel.currentFileURL,
               let mount = remoteManager.mount(forLocalURL: fileURL) {
                remoteStatusPill(for: fileURL, mount: mount)
            }

            Spacer()

            // Theme quick selector menu
            Menu {
                ForEach(EditorTheme.allCases) { themeOption in
                    Button {
                        viewModel.theme = themeOption
                    } label: {
                        HStack {
                            Text(themeOption.rawValue)
                            if viewModel.theme == themeOption {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 11))
                    Text(viewModel.theme.rawValue)
                        .font(.system(size: 11))
                }
                .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch Theme")

            // Typography & Layout Settings button
            Button {
                viewModel.showSettingsModal.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Text("Settings")
                        .font(.system(size: 11))
                }
                .foregroundColor(viewModel.showSettingsModal ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $viewModel.showSettingsModal, arrowEdge: .top) {
                EditorSettingsView(viewModel: viewModel)
            }
            .help("Typography & Editor Settings (Cmd+,)")

            // Right: Word Count Popover button
            Button {
                viewModel.showWordCountPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    if viewModel.stats.selectedWords > 0 {
                        Text("\(viewModel.stats.selectedWords) / \(viewModel.stats.words) Words")
                    } else {
                        Text("\(viewModel.stats.words) Words")
                    }
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9))
                }
                .font(.system(size: 11.5, weight: .regular))
                .monospacedDigit()
                .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $viewModel.showWordCountPopover, arrowEdge: .top) {
                WordCountPopoverView(viewModel: viewModel)
            }
            .help("Word Count & Document Statistics")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(viewModel.theme.editorBackgroundColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(viewModel.theme.borderColor)
                .frame(height: 1)
        }
    }

    private func modeBadge(title: String, icon: String, onDismiss: @escaping () -> Void) -> some View {
        Button(action: onDismiss) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(viewModel.theme.linkColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(viewModel.theme.linkColor.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func remoteStatusPill(for fileURL: URL, mount: RemoteMountSpec) -> some View {
        let fileStatus = remoteManager.syncStatus(forLocalURL: fileURL)
        let mountState = remoteManager.connectionStates[mount.id] ?? .connected
        let sshLabel = remoteManager.remoteSSHDisplayPath(forLocalURL: fileURL) ?? mount.connectionString

        let (text, icon, color): (String, String, Color) = {
            switch (fileStatus, mountState) {
            case (.syncing, _), (_, .syncing):
                return ("Syncing \(mount.host)…", "arrow.triangle.2.circlepath", viewModel.theme.linkColor)
            case (.pendingUpload, _):
                return ("Queued for \(mount.host)", "arrow.up.circle.fill", .orange)
            case (_, .reconnecting(let attempt, _, _)):
                return ("Reconnecting \(mount.host) (#\(attempt))…", "wifi.exclamationmark", .orange)
            case (_, .error):
                return ("Offline (\(mount.host))", "wifi.exclamationmark", .orange)
            case (.error, _):
                return ("Sync Retry (\(mount.host))", "exclamationmark.triangle.fill", .orange)
            default:
                return ("SSH: \(mount.host)", "checkmark.icloud.fill", .green)
            }
        }()

        Button {
            Task {
                await remoteManager.syncMount(id: mount.id, isBackground: false)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(text)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .help("\(sshLabel) — Click to sync now")
    }
}

public struct EditorSettingsView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Typography & Layout Settings", systemImage: "textformat.size")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button("Reset Defaults") {
                    viewModel.resetTypographyToDefaults()
                }
                .controlSize(.small)
            }

            Divider()

            // Section 1: Body Typography
            VStack(alignment: .leading, spacing: 8) {
                Text("BODY TYPOGRAPHY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                settingSliderRow(
                    title: "Font Size Scale",
                    valueText: "\(Int(round(viewModel.typography.fontSizeScale * 100)))%",
                    value: $viewModel.typography.fontSizeScale,
                    range: 0.80...1.50,
                    step: 0.05
                )

                settingSliderRow(
                    title: "Line Height",
                    valueText: String(format: "%.2f×", viewModel.typography.lineHeightMultiple),
                    value: $viewModel.typography.lineHeightMultiple,
                    range: 1.00...1.80,
                    step: 0.02
                )

                settingSliderRow(
                    title: "Line Spacing",
                    valueText: String(format: "%.1f pt", viewModel.typography.lineSpacing),
                    value: $viewModel.typography.lineSpacing,
                    range: 0.0...16.0,
                    step: 0.5
                )

                settingSliderRow(
                    title: "Paragraph Spacing",
                    valueText: String(format: "%.1f pt", viewModel.typography.paragraphSpacing),
                    value: $viewModel.typography.paragraphSpacing,
                    range: 2.0...28.0,
                    step: 1.0
                )

                settingSliderRow(
                    title: "Character Spacing",
                    valueText: String(format: "%+.2f pt", viewModel.typography.characterSpacing),
                    value: $viewModel.typography.characterSpacing,
                    range: -0.50...2.50,
                    step: 0.05
                )
            }

            Divider()

            // Section 2: Headings & Horizontal Rules
            VStack(alignment: .leading, spacing: 8) {
                Text("TITLES & HORIZONTAL LINES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                settingSliderRow(
                    title: "Title Letter Spacing",
                    valueText: String(format: "%+.2f pt", viewModel.typography.headingCharacterSpacing),
                    value: $viewModel.typography.headingCharacterSpacing,
                    range: -0.50...3.00,
                    step: 0.05
                )

                settingSliderRow(
                    title: "Title Vertical Spacing",
                    valueText: String(format: "%.2f×", viewModel.typography.headingSpacingScale),
                    value: $viewModel.typography.headingSpacingScale,
                    range: 0.60...2.00,
                    step: 0.05
                )

                settingSliderRow(
                    title: "Underline Offset",
                    valueText: String(format: "%.1f pt", viewModel.typography.headingUnderlineOffset),
                    value: $viewModel.typography.headingUnderlineOffset,
                    range: 2.0...16.0,
                    step: 0.5
                )

                Toggle("Show H1 / H2 Heading Underlines", isOn: $viewModel.typography.showHeadingUnderlines)
                    .font(.system(size: 12))
            }

            Divider()

            // Section 3: Page Layout & Editor Options
            VStack(alignment: .leading, spacing: 8) {
                Text("PAGE LAYOUT & EDITOR")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                settingSliderRow(
                    title: "Max Column Width",
                    valueText: "\(Int(viewModel.typography.maxColumnWidth)) px",
                    value: $viewModel.typography.maxColumnWidth,
                    range: 560.0...1280.0,
                    step: 20.0
                )

                HStack {
                    Toggle("Continuous Spellcheck", isOn: $viewModel.spellCheckEnabled)
                        .font(.system(size: 12))
                    Spacer()
                    Picker("Theme", selection: $viewModel.theme) {
                        ForEach(EditorTheme.allCases) { themeOption in
                            Text(themeOption.rawValue).tag(themeOption)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }

            Divider()

            // Section 4: Software Updates & Build Info
            VStack(alignment: .leading, spacing: 8) {
                Text("SOFTWARE UPDATES & BUILD")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Folio \(AppUpdateManager.shared.currentVersion.displayString)")
                            .font(.system(size: 12, weight: .medium))
                        Text("Core Engine v\(AppUpdateManager.shared.currentVersion.engineVersion)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates…") {
                        Task {
                            await AppUpdateManager.shared.checkForUpdates(userInitiated: true)
                        }
                    }
                    .controlSize(.small)
                }

                Toggle("Automatically check for updates on launch", isOn: Binding(
                    get: { AppUpdateManager.shared.autoCheckForUpdates },
                    set: { AppUpdateManager.shared.autoCheckForUpdates = $0 }
                ))
                .font(.system(size: 12))
            }
        }
        .padding(16)
        .frame(width: 390)
    }

    private func settingSliderRow(
        title: String,
        valueText: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 135, alignment: .leading)

            Slider(
                value: Binding<Double>(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = CGFloat($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )

            Text(valueText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

public struct AppUpdateModalView: View {
    @ObservedObject var updateManager: AppUpdateManager

    public init(updateManager: AppUpdateManager) {
        self.updateManager = updateManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: FolioBrandIcon.makeAppIconImage(pixelSize: 64))
                    .resizable()
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Folio Software Update")
                        .font(.system(size: 14.5, weight: .semibold))
                    Text("Installed: \(updateManager.currentVersion.displayString)")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            switch updateManager.status {
            case .idle, .checking:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking GitHub Releases for a newer build…")
                        .font(.system(size: 12.5))
                }
                .padding(.vertical, 8)

            case .upToDate(let info):
                Label("You're running the latest build (\(info.displayString)).", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.vertical, 6)

            case .updateAvailable(let manifest):
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "New build available: v\(manifest.version) (Build #\(manifest.buildNumber), \(manifest.commitSHA.prefix(7)))",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.accentColor)

                    if let notes = manifest.notes, !notes.isEmpty {
                        ScrollView {
                            Text(notes)
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.08))
                        )
                    }
                }

            case .downloading(let manifest):
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading Folio.dmg (Build #\(manifest.buildNumber))…")
                        .font(.system(size: 12.5))
                }
                .padding(.vertical, 8)

            case .installing(let manifest):
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying and installing Build #\(manifest.buildNumber) (Folio will relaunch)…")
                        .font(.system(size: 12.5))
                }
                .padding(.vertical, 8)

            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))
                    .padding(.vertical, 6)
            }

            HStack {
                Spacer()
                Button("Close") {
                    updateManager.showUpdateSheet = false
                }
                if case .updateAvailable(let manifest) = updateManager.status {
                    Button("Update & Relaunch") {
                        Task {
                            await updateManager.downloadAndInstallUpdate(manifest)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

public struct RemoteConnectionBannerView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self.remoteManager = viewModel.remoteWorkspaceManager
    }

    public var body: some View {
        let unhealthy = remoteManager.unhealthyMounts
        if !unhealthy.isEmpty && !viewModel.remoteConnectionBannerDismissed {
            let (firstMount, firstState) = unhealthy[0]
            let errorMessage = firstState.errorMessage ?? "Connection interrupted."
            let attemptCount: Int = {
                switch firstState {
                case .reconnecting(let attempt, _, _):
                    return attempt
                default:
                    return 1
                }
            }()

            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Remote connection issue (\(firstMount.connectionString))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(viewModel.theme.textColor)
                        Text("• Auto-reconnecting (#\(attemptCount))…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    Text("\(errorMessage) — All files remain editable locally and will sync automatically as soon as connectivity returns.")
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                        .lineLimit(2)
                }

                Spacer()

                Button("Retry Now") {
                    remoteManager.retryAllUnhealthyMounts()
                }
                .controlSize(.small)

                Button {
                    viewModel.showAddRemoteModal = true
                } label: {
                    Text("Manage")
                }
                .controlSize(.small)

                Button {
                    viewModel.remoteConnectionBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .help("Dismiss banner (reconnection continues automatically in background)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.10))
            .overlay(alignment: .bottom) {
                Divider().overlay(Color.orange.opacity(0.30))
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

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
                    Picker("Mount Type", selection: Binding(
                        get: { targetKind },
                        set: { newKind in
                            targetKind = newKind
                            targetKindManuallyChosen = true
                        }
                    )) {
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



