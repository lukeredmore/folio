import AppKit
import SwiftUI

public typealias SelectionCommentsBannerView = SelectionCommentsSidebarView

public struct SelectionCommentsSidebarView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Text("Comments (\(viewModel.selectionComments.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                    ForEach(viewModel.selectionComments) { comment in
                        commentRow(for: comment)
                            .id(comment.id)
                    }
                }
                .padding(.top, 52)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .ignoresSafeArea(.container, edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .onChange(of: viewModel.activeCommentID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func commentRow(for comment: SelectionComment) -> some View {
        let isActive = (viewModel.activeCommentID == comment.id)
        let excerpt = comment.selectedFormattedText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                if !excerpt.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.25)
                            .fill(viewModel.theme.linkColor.opacity(0.65))
                            .frame(width: 2.5)
                        Text(excerpt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Text(comment.commentText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button {
                    viewModel.selectComment(comment)
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Edit comment")

                Button {
                    viewModel.removeSelectionComment(id: comment.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete comment")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.focusComment(comment, scrollEditor: true)
        }
        .contextMenu {
            Button("Copy Comment") {
                viewModel.copySingleSelectionComment(comment)
            }
            Button("Edit Comment…") {
                viewModel.selectComment(comment)
            }
            Divider()
            Button("Delete Comment", role: .destructive) {
                viewModel.removeSelectionComment(id: comment.id)
            }
        }
    }
}
