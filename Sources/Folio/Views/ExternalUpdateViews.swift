import AppKit
import SwiftUI

// MARK: - Live External Auto-Update Banner & Diff Inspector

public struct ExternalUpdateBannerView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if let notice = viewModel.externalUpdateNotice, viewModel.activeConflict == nil {
            HStack(spacing: 10) {
                Image(systemName: notice.wasThreeWayMerged ? "arrow.triangle.branch" : "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(notice.headlineText) in \(notice.fileURL.lastPathComponent) (\(notice.summaryText))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(viewModel.theme.textColor)
                    Text("Changed lines are highlighted in green in the editor.")
                        .font(.system(size: 10.5))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }

                Spacer()

                Button("View Diff") {
                    viewModel.showExternalUpdateDiffModal = true
                }
                .controlSize(.small)

                Button("Undo Update") {
                    viewModel.undo()
                    viewModel.dismissExternalUpdateNotice()
                }
                .controlSize(.small)

                Button {
                    viewModel.dismissExternalUpdateNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.green.opacity(viewModel.theme.isDark ? 0.14 : 0.08))
            .overlay(alignment: .bottom) {
                Divider().overlay(Color.green.opacity(0.35))
            }
        }
    }
}

public struct DocumentConflictBannerView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if let conflict = viewModel.activeConflict {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text("External Edit Conflict in \(conflict.fileURL.lastPathComponent)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(viewModel.theme.textColor)
                    Text("\(conflict.conflictHunks.count) overlapping section(s) changed both in Folio and on disk.")
                        .font(.system(size: 10.5))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }

                Spacer()

                Button("Resolve Interactively…") {
                    viewModel.showConflictResolverModal = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)

                Button("Keep My Changes") {
                    viewModel.resolveConflict(using: .keepLocal)
                }
                .controlSize(.small)

                Button("Accept External") {
                    viewModel.resolveConflict(using: .acceptExternal)
                }
                .controlSize(.small)

                Button("Keep Both") {
                    viewModel.resolveConflict(using: .keepBoth)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(viewModel.theme.isDark ? 0.16 : 0.10))
            .overlay(alignment: .bottom) {
                Divider().overlay(Color.orange.opacity(0.4))
            }
        }
    }
}

public struct ExternalUpdateDiffModalView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice = viewModel.externalUpdateNotice {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.wasThreeWayMerged ? "External Changes Auto-Merged" : "External File Update Applied")
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(notice.fileURL.lastPathComponent) • +\(notice.addedLines) added, -\(notice.removedLines) removed")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notice.hunks) { hunk in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Lines \(hunk.newStartLine)–\(max(hunk.newStartLine, hunk.newStartLine + max(0, hunk.addedLines.count - 1)))")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)

                                ForEach(Array(hunk.removedLines.enumerated()), id: \.offset) { _, line in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("-")
                                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(.red)
                                        Text(line.isEmpty ? " " : line)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.red.opacity(0.10))
                                    .cornerRadius(4)
                                }

                                ForEach(Array(hunk.addedLines.enumerated()), id: \.offset) { _, line in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("+")
                                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(.green)
                                        Text(line.isEmpty ? " " : line)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.10))
                                    .cornerRadius(4)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.06))
                            )
                        }
                    }
                }
                .frame(maxHeight: 380)

                HStack {
                    Button("Undo External Update (Cmd+Z)") {
                        viewModel.undo()
                        viewModel.showExternalUpdateDiffModal = false
                        viewModel.dismissExternalUpdateNotice()
                    }
                    Spacer()
                    Button("Done") {
                        viewModel.showExternalUpdateDiffModal = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("No external update diff available.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                HStack {
                    Spacer()
                    Button("Close") {
                        viewModel.showExternalUpdateDiffModal = false
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 580)
    }
}
