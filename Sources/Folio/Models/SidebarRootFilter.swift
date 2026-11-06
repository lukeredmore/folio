import Foundation

/// A document type that a sidebar root can show or hide.
public enum SidebarFileType: String, CaseIterable, Codable, Identifiable, Sendable {
    case markdown
    case plainText
    case latex
    case bibtex

    public var id: String { rawValue }

    public var extensions: Set<String> {
        switch self {
        case .markdown: return WorkspaceFileNode.markdownExtensions.subtracting(["txt"])
        case .plainText: return ["txt"]
        case .latex: return WorkspaceFileNode.latexExtensions
        case .bibtex: return WorkspaceFileNode.bibtexExtensions
        }
    }

    /// Menu label, for example `LaTeX (.cls, .ltx, .sty, .tex)`.
    public var menuTitle: String {
        let name: String
        switch self {
        case .markdown: name = "Markdown"
        case .plainText: name = "Plain Text"
        case .latex: name = "LaTeX"
        case .bibtex: name = "BibTeX"
        }
        let suffixes = extensions.subtracting(["textbundle"]).sorted().map { "." + $0 }.joined(separator: ", ")
        return "\(name) (\(suffixes))"
    }

    public init?(fileExtension: String) {
        let lower = fileExtension.lowercased()
        guard let match = Self.allCases.first(where: { $0.extensions.contains(lower) }) else { return nil }
        self = match
    }
}

/// What one sidebar root (a local folder or a remote folder mount) hides.
public struct SidebarRootFilter: Codable, Equatable, Sendable {
    public var hiddenFileTypes: Set<SidebarFileType>
    /// Root-relative folder paths that the sidebar hides, with everything inside them.
    public var excludedPaths: Set<String>

    public init(hiddenFileTypes: Set<SidebarFileType> = [], excludedPaths: Set<String> = []) {
        self.hiddenFileTypes = hiddenFileTypes
        self.excludedPaths = excludedPaths
    }

    /// False when the file's type is hidden. Files of other types are not affected.
    public func showsFile(named name: String) -> Bool {
        guard let type = SidebarFileType(fileExtension: (name as NSString).pathExtension) else { return true }
        return !hiddenFileTypes.contains(type)
    }

    /// True when `relativePath` is an excluded folder or is inside one.
    public func excludes(relativePath: String) -> Bool {
        excludedPaths.contains { relativePath == $0 || relativePath.hasPrefix($0 + "/") }
    }

    /// The members of `extensions` whose type is not hidden.
    public func shownExtensions(of extensions: Set<String>) -> Set<String> {
        extensions.filter { ext in
            SidebarFileType(fileExtension: ext).map { !hiddenFileTypes.contains($0) } ?? true
        }
    }
}
