import AppKit
import SwiftUI

public struct FindReplaceBannerView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case find
        case replace
    }

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        viewModel.showDocumentReplaceControls.toggle()
                    }
                } label: {
                    Image(systemName: viewModel.showDocumentReplaceControls ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Toggle Replace (Cmd+R)")

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundColor(viewModel.theme.secondaryTextColor)

                TextField("Find in document (Cmd+F)...", text: $viewModel.findQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 210)
                    .focused($focusedField, equals: .find)
                    .onSubmit {
                        viewModel.findNextInDocument()
                    }

                Button {
                    viewModel.findPreviousInDocument()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .controlSize(.small)
                .help("Find Previous (Cmd+Shift+G)")

                Button {
                    viewModel.findNextInDocument()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .controlSize(.small)
                .help("Find Next (Cmd+G)")

                if !viewModel.findQuery.isEmpty {
                    let count = viewModel.documentFindMatchCount
                    Text("\(count) \(count == 1 ? "match" : "matches")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }

                Spacer()

                Button {
                    viewModel.closeDocumentFindBar()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .help("Close Find Bar (Esc)")
            }

            if viewModel.showDocumentReplaceControls {
                HStack(spacing: 8) {
                    Spacer()
                        .frame(width: 14)

                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.theme.secondaryTextColor)

                    TextField("Replace with (Cmd+R)...", text: $viewModel.replaceQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 210)
                        .focused($focusedField, equals: .replace)
                        .onSubmit {
                            viewModel.replaceCurrentMatch()
                        }

                    Button("Replace") {
                        viewModel.replaceCurrentMatch()
                    }
                    .controlSize(.small)

                    Button("Replace All") {
                        viewModel.replaceAllInDocument()
                    }
                    .controlSize(.small)

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(viewModel.theme.sidebarBackgroundColor)
        .overlay(alignment: .bottom) {
            Divider().overlay(viewModel.theme.borderColor)
        }
        .onAppear {
            focusedField = .find
        }
        .onChange(of: viewModel.findBarFocusRequestID) { _, _ in
            focusedField = .find
        }
    }
}
