import AppKit
import SwiftUI

// MARK: - Document Conflict Tooltip & External Update Diff Inspector

/// Headline and resolution actions for an external edit that overlaps unsaved local edits.
struct DocumentConflictTooltipBody: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    let conflict: DocumentConflict

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("External Edit Conflict in \(conflict.fileURL.lastPathComponent)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(viewModel.theme.textColor)
                Text("\(conflict.conflictHunks.count) overlapping section(s) changed both in Folio and on disk.")
                    .font(.system(size: 10.5))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Keep My Changes") { viewModel.resolveConflict(using: .keepLocal) }
            Button("Accept External") { viewModel.resolveConflict(using: .acceptExternal) }
            Button("Keep Both") { viewModel.resolveConflict(using: .keepBoth) }
        }
        .controlSize(.small)
        HStack {
            Spacer(minLength: 0)
            Button("Resolve Interactively…") { viewModel.showConflictResolverModal = true }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .controlSize(.small)
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
