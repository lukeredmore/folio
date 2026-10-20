import AppKit
import SwiftUI

public struct SidebarView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self.remoteManager = viewModel.remoteWorkspaceManager
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Sidebar Header Tabs (Files / Outline / Search)
            HStack(spacing: 0) {
                ForEach([SidebarTab.files, SidebarTab.outline], id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.activeSidebarTab = tab
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: viewModel.activeSidebarTab == tab ? .semibold : .regular))
                                .foregroundColor(viewModel.activeSidebarTab == tab ? viewModel.theme.textColor : viewModel.theme.secondaryTextColor)
                            Rectangle()
                                .fill(viewModel.activeSidebarTab == tab ? viewModel.theme.linkColor : Color.clear)
                                .frame(height: 2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Search toggle icon button
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.activeSidebarTab = (viewModel.activeSidebarTab == .search) ? .files : .search
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: viewModel.activeSidebarTab == .search ? .semibold : .regular))
                            .foregroundColor(viewModel.activeSidebarTab == .search ? viewModel.theme.textColor : viewModel.theme.secondaryTextColor)
                        Rectangle()
                            .fill(viewModel.activeSidebarTab == .search ? viewModel.theme.linkColor : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(width: 38)
                    .padding(.top, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search in Workspace (Cmd+Shift+F)")
            }
            .padding(.horizontal, 8)
            .background(viewModel.theme.sidebarBackgroundColor)

            Divider()
                .overlay(viewModel.theme.borderColor)

            // Active Tab Body
            Group {
                switch viewModel.activeSidebarTab {
                case .files:
                    filesTabContent
                case .outline:
                    outlineTabContent
                case .search:
                    searchTabContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom Sidebar Footer Bar
            sidebarFooter
        }
        .frame(width: 245)
        .background(viewModel.theme.sidebarBackgroundColor)
    }

    // MARK: - Files Tab
    var filesTabContent: some View {
        VStack(spacing: 0) {
            if viewModel.rootFileNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                    Text("No Open Folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(viewModel.theme.textColor)
                    VStack(spacing: 8) {
                        Button("Open Folder...") {
                            viewModel.openFolderPanel()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            viewModel.showAddRemoteModal = true
                        } label: {
                            Label("Connect Remote (SSH)...", systemImage: "network")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.fileDisplayStyle == .tree {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.rootFileNodes) { node in
                            FileTreeNodeRow(
                                node: node,
                                level: 0,
                                viewModel: viewModel,
                                remoteManager: remoteManager
                            )
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.flatMarkdownFiles) { node in
                            Button {
                                viewModel.openFile(at: node.url)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: node.isRemote ? "network" : (node.isMarkdownFile ? "doc.text" : "doc"))
                                        .font(.system(size: 12))
                                        .foregroundColor(viewModel.theme.linkColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.name)
                                            .font(.system(size: 12.5, weight: viewModel.currentFileURL == node.url ? .semibold : .regular))
                                            .foregroundColor(viewModel.theme.textColor)
                                            .lineLimit(1)
                                        HStack(spacing: 4) {
                                            if let conn = node.remoteConnectionString {
                                                Text(conn)
                                                    .font(.system(size: 10))
                                                    .foregroundColor(viewModel.theme.secondaryTextColor)
                                                    .lineLimit(1)
                                            } else {
                                                Text(node.modificationDate, style: .date)
                                                    .font(.system(size: 10.5))
                                                    .foregroundColor(viewModel.theme.secondaryTextColor)
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(viewModel.currentFileURL == node.url ? viewModel.theme.linkColor.opacity(0.16) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    // MARK: - Outline Tab
    var outlineTabContent: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
                TextField("Filter Outline...", text: $viewModel.outlineFilterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(viewModel.theme.textColor)
                if !viewModel.outlineFilterText.isEmpty {
                    Button {
                        viewModel.outlineFilterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(viewModel.theme.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(viewModel.theme.editorBackgroundColor.opacity(0.5))

            Divider()
                .overlay(viewModel.theme.borderColor)

            let filteredHeadings = viewModel.headings.filter {
                viewModel.outlineFilterText.isEmpty ||
                $0.title.localizedCaseInsensitiveContains(viewModel.outlineFilterText)
            }

            if filteredHeadings.isEmpty {
                VStack(spacing: 8) {
                    Text("Outline is Empty")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                    Text("Add Markdown headings (# H1, ## H2) to navigate sections.")
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.theme.secondaryTextColor.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredHeadings) { heading in
                            let isActive = viewModel.activeHeadingID == heading.id
                            Button {
                                viewModel.scrollToHeading(heading)
                            } label: {
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(isActive ? viewModel.theme.linkColor : Color.clear)
                                        .frame(width: 3, height: 14)

                                    Text(heading.title)
                                        .font(.system(
                                            size: heading.level == 1 ? 12.5 : 12.0,
                                            weight: (heading.level == 1 || isActive) ? .semibold : .regular
                                        ))
                                        .foregroundColor(isActive ? viewModel.theme.linkColor : viewModel.theme.textColor)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.leading, CGFloat(max(0, heading.level - 1)) * 11.0 + 6.0)
                                .padding(.trailing, 8)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isActive ? viewModel.theme.linkColor.opacity(0.12) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}
