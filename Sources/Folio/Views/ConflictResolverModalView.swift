import AppKit
import SwiftUI

// MARK: - Interactive Conflict Resolver Modal

public struct ConflictResolverModalView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let conflict = viewModel.activeConflict {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Resolve File Conflict — \(conflict.fileURL.lastPathComponent)")
                            .font(.system(size: 15, weight: .semibold))
                        Text(
                            "This file was updated externally while overlapping lines were modified in Folio. Choose how to resolve each conflicting section or apply a global strategy."
                        )
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("Quick Actions:")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.secondary)

                    Button("Keep All Local") {
                        viewModel.resolveConflict(using: .keepLocal)
                    }
                    .controlSize(.small)

                    Button("Accept All External") {
                        viewModel.resolveConflict(using: .acceptExternal)
                    }
                    .controlSize(.small)

                    Button("Keep Both Everywhere") {
                        viewModel.resolveConflict(using: .keepBoth)
                    }
                    .controlSize(.small)

                    Spacer()
                }

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(conflict.conflictHunks.enumerated()), id: \.element.id) { idx, hunk in
                            conflictHunkCard(index: idx, hunk: hunk)
                        }
                    }
                }
                .frame(maxHeight: 380)

                Divider()

                HStack {
                    Button("Cancel") {
                        viewModel.showConflictResolverModal = false
                    }
                    Spacer()
                    Button("Apply Selected Resolution & Auto-Save") {
                        viewModel.applyInteractiveConflictResolution()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("No active conflict.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                HStack {
                    Spacer()
                    Button("Close") {
                        viewModel.showConflictResolverModal = false
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 680)
    }

    @ViewBuilder
    private func conflictHunkCard(index idx: Int, hunk: DocumentConflictHunk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Conflict #\(idx + 1) (Line \(hunk.lineNumber))")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker(
                    "Resolution",
                    selection: Binding(
                        get: { hunk.selectedStrategy },
                        set: { newStrategy in
                            viewModel.setConflictHunkResolution(newStrategy, forHunkID: hunk.id)
                        }
                    )
                ) {
                    ForEach(ConflictResolutionStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 310)
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCAL (IN FOLIO)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.blue)
                    Text(hunk.localLines.isEmpty ? "(Deleted)" : hunk.localLines.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.blue.opacity(0.08))
                        .cornerRadius(6)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("EXTERNAL (ON DISK)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                    Text(hunk.externalLines.isEmpty ? "(Deleted)" : hunk.externalLines.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(6)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}
