import AppKit
import SwiftUI

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
