import AppKit
import SwiftUI

public struct SidebarView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
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
    private var filesTabContent: some View {
        VStack(spacing: 0) {
            if viewModel.rootFileNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                    Text("No Open Folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(viewModel.theme.textColor)
                    Button("Open Folder...") {
                        viewModel.openFolderPanel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.fileDisplayStyle == .tree {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.rootFileNodes) { node in
                            FileTreeNodeRow(node: node, level: 0, viewModel: viewModel)
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
                                    Image(systemName: node.isMarkdownFile ? "doc.text" : "doc")
                                        .font(.system(size: 12))
                                        .foregroundColor(viewModel.theme.linkColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.name)
                                            .font(.system(size: 12.5, weight: viewModel.currentFileURL == node.url ? .semibold : .regular))
                                            .foregroundColor(viewModel.theme.textColor)
                                            .lineLimit(1)
                                        Text(node.modificationDate, style: .date)
                                            .font(.system(size: 10.5))
                                            .foregroundColor(viewModel.theme.secondaryTextColor)
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
    private var outlineTabContent: some View {
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

    // MARK: - Search Tab
    private var searchTabContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                    TextField("Search in folder...", text: $viewModel.workspaceSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(viewModel.theme.textColor)
                        .onSubmit {
                            viewModel.performWorkspaceSearch()
                        }
                        .onChange(of: viewModel.workspaceSearchQuery) { _, _ in
                            viewModel.performWorkspaceSearch()
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(viewModel.theme.editorBackgroundColor)
                )

                // Search option toggles (Case Sensitive, Whole Word, Regex)
                HStack(spacing: 6) {
                    searchTogglePill(label: "Aa", help: "Case Sensitive", isOn: $viewModel.searchCaseSensitive)
                    searchTogglePill(label: "ab", help: "Whole Word", isOn: $viewModel.searchWholeWord)
                    searchTogglePill(label: ".*", help: "Regular Expression", isOn: $viewModel.searchUseRegex)
                    Spacer()
                    Text("\(viewModel.workspaceSearchMatches.count) hits")
                        .font(.system(size: 10.5))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }
            }
            .padding(8)

            Divider()
                .overlay(viewModel.theme.borderColor)

            if viewModel.workspaceSearchMatches.isEmpty {
                VStack(spacing: 6) {
                    Text(viewModel.workspaceSearchQuery.isEmpty ? "Type to search across files" : "No matches found")
                        .font(.system(size: 12))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(viewModel.workspaceSearchMatches) { match in
                            Button {
                                viewModel.jumpToSearchMatch(match)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 10))
                                            .foregroundColor(viewModel.theme.linkColor)
                                        Text(match.fileName)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundColor(viewModel.theme.textColor)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(":\(match.lineNumber)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(viewModel.theme.secondaryTextColor)
                                    }
                                    Text(match.lineSnippet)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(viewModel.theme.secondaryTextColor)
                                        .lineLimit(2)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(viewModel.theme.editorBackgroundColor.opacity(0.5))
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

    private func searchTogglePill(label: String, help: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            viewModel.performWorkspaceSearch()
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(isOn.wrappedValue ? .white : viewModel.theme.secondaryTextColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue ? viewModel.theme.linkColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Sidebar Footer
    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.createNewFileInWorkspace()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("New File in Workspace")

            Menu {
                if let folder = viewModel.workspaceFolderURL {
                    Text("Folder: \(folder.lastPathComponent)")
                    Divider()
                }
                Button("Open Folder...") {
                    viewModel.openFolderPanel()
                }
                Divider()
                Picker("View Mode", selection: $viewModel.fileDisplayStyle) {
                    Text("File Tree View").tag(FileDisplayStyle.tree)
                    Text("File List View").tag(FileDisplayStyle.list)
                }
                Picker("Sort By", selection: $viewModel.fileSortOrder) {
                    ForEach(FileSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .onChange(of: viewModel.fileSortOrder) { _, _ in
                    viewModel.sortFileNodes()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(viewModel.workspaceFolderURL?.lastPathComponent ?? "Workspace")
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                }
                .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .menuStyle(.borderlessButton)

            Spacer()

            Button {
                viewModel.fileDisplayStyle = (viewModel.fileDisplayStyle == .tree) ? .list : .tree
            } label: {
                Image(systemName: viewModel.fileDisplayStyle == .tree ? "list.bullet.indent" : "list.bullet")
                    .font(.system(size: 11.5))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("Switch between File Tree and File List view")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(viewModel.theme.sidebarBackgroundColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(viewModel.theme.borderColor)
                .frame(height: 1)
        }
    }
}

private struct FileTreeNodeRow: View {
    let node: WorkspaceFileNode
    let level: Int
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if node.isDirectory {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isExpanded.toggle()
                    }
                } else {
                    viewModel.openFile(at: node.url)
                }
            } label: {
                HStack(spacing: 5) {
                    if node.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(viewModel.theme.secondaryTextColor)
                            .frame(width: 10)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11.5))
                            .foregroundColor(viewModel.theme.linkColor.opacity(0.85))
                    } else {
                        Spacer().frame(width: 10)
                        Image(systemName: node.isMarkdownFile ? "doc.text.fill" : "doc")
                            .font(.system(size: 11.5))
                            .foregroundColor(node.isMarkdownFile ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
                    }

                    Text(node.name)
                        .font(.system(size: 12, weight: viewModel.currentFileURL == node.url ? .semibold : .regular))
                        .foregroundColor(viewModel.theme.textColor)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.leading, CGFloat(level) * 12.0 + 4.0)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(viewModel.currentFileURL == node.url ? viewModel.theme.linkColor.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
            }

            if node.isDirectory, isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileTreeNodeRow(node: child, level: level + 1, viewModel: viewModel)
                }
            }
        }
    }
}
