import AppKit
import Foundation
import SwiftUI

extension EditorWorkspaceViewModel {

    // MARK: - Document Kind Detection

    public var currentDocumentKind: FolioDocumentKind {
        LaTeXLiveStyler.documentKind(for: markdownText, fileURL: currentFileURL)
    }

    public var isCurrentDocumentLaTeX: Bool {
        currentDocumentKind == .latex
    }

    public var isCurrentDocumentBibTeX: Bool {
        currentDocumentKind == .bibtex
    }

    // MARK: - New LaTeX Document & Workspace File

    public static let defaultLaTeXDocument = """
        \\documentclass[11pt]{article}
        \\usepackage{amsmath,amssymb,amsthm}
        \\usepackage{graphicx}
        \\usepackage{hyperref}

        \\newtheorem{theorem}{Theorem}
        \\newtheorem{definition}{Definition}

        \\title{Untitled Paper}
        \\author{Author Name}
        \\date{\\today}

        \\begin{document}
        \\maketitle

        \\begin{abstract}
        Write your abstract here.
        \\end{abstract}

        \\section{Introduction}
        \\label{sec:intro}

        Write your introduction here with inline math like $E = mc^2$.

        \\end{document}
        """

    public func newLaTeXDocument() {
        flushPendingAutoSaveBeforeSwitchingFile()
        discardUntouchedNewFile()
        stopWatchingCurrentFile()
        activeConflict = nil
        dismissExternalUpdateNotice()
        isApplyingInternalStateChange = true
        currentFileURL = nil
        let initial = Self.defaultLaTeXDocument + "\n"
        markdownText = initial
        lastSavedDiskContent = initial
        isDirty = false
        currentSelectedRange = NSRange(location: 0, length: 0)
        isApplyingInternalStateChange = false
        setSessionValue(0, forKey: Self.selectedCursorLocationDefaultsKey)
        stats = DocumentStats.compute(for: markdownText)
        if activeTextView == nil {
            let analysis = MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: markdownText),
                theme: theme,
                typography: typography,
                sourceCodeMode: sourceCodeMode,
                focusMode: focusMode,
                selectedRange: NSRange(location: 0, length: 0)
            )
            headings = analysis.headings
        }
        refreshUndoRedoAvailability()
        persistDocumentSessionState()
    }

    public func createNewLaTeXFileInWorkspace(in targetDirectoryURL: URL? = nil) {
        let baseFolder = targetDirectoryURL ?? workspaceFolderURL
        guard let folder = baseFolder else {
            newLaTeXDocument()
            return
        }
        var candidateIndex = 1
        var targetURL = folder.appendingPathComponent("Untitled.tex")
        while FileManager.default.fileExists(atPath: targetURL.path) {
            candidateIndex += 1
            targetURL = folder.appendingPathComponent("Untitled \(candidateIndex).tex")
        }
        let titleName = targetURL.deletingPathExtension().lastPathComponent
        let template =
            Self.defaultLaTeXDocument
            .replacingOccurrences(of: "\\title{Untitled Paper}", with: "\\title{\(titleName)}") + "\n"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? template.write(to: targetURL, atomically: true, encoding: .utf8)

        if remoteWorkspaceManager.isRemoteURL(targetURL) {
            Task { @MainActor in
                await remoteWorkspaceManager.saveRemoteFile(at: targetURL, content: template)
            }
        }
        reloadWorkspaceTree()
        openFile(at: targetURL)
        untouchedNewFile = (targetURL, template)
    }

    // MARK: - Mode-Aware Formatting Helpers

    func resolvedInlineDelimiters(
        prefix: String,
        suffix: String,
        placeholder: String
    ) -> (prefix: String, suffix: String, placeholder: String) {
        guard isCurrentDocumentLaTeX else {
            return (prefix, suffix, placeholder)
        }
        switch (prefix, suffix) {
        case ("**", "**"):
            return ("\\textbf{", "}", placeholder)
        case ("*", "*"):
            return ("\\textit{", "}", placeholder)
        case ("`", "`"):
            return ("\\texttt{", "}", placeholder)
        case ("~~", "~~"), ("==", "=="):
            return ("\\underline{", "}", placeholder)
        case ("[", "](https://)"):
            return ("\\href{https://}{", "}", placeholder)
        case ("![", "](image.png)"):
            return ("\\includegraphics[width=0.8\\textwidth]{", "}", "image.png")
        default:
            return (prefix, suffix, placeholder)
        }
    }

    func setLaTeXHeadingLevel(_ level: Int) {
        withUndoMetadata(origin: .formattingAction, summary: level == 0 ? "Convert to Paragraph" : "LaTeX Section \(level)") {
            guard let tv = activeTextView else { return }
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let lineRange = nsStr.lineRange(for: NSRange(location: min(sel.location, nsStr.length), length: 0))
            var contentRange = lineRange
            while contentRange.length > 0 {
                let ch = nsStr.character(at: contentRange.location + contentRange.length - 1)
                if ch == 10 || ch == 13 { contentRange.length -= 1 } else { break }
            }
            let lineText = nsStr.substring(with: contentRange)
            let stripped = Self.stripLaTeXSectionWrapper(lineText)

            let replacement: String
            if level == 0 {
                replacement = stripped
            } else {
                let cmd: String
                switch level {
                case 1: cmd = "\\section"
                case 2: cmd = "\\subsection"
                case 3: cmd = "\\subsubsection"
                case 4: cmd = "\\paragraph"
                default: cmd = "\\subparagraph"
                }
                let inner = stripped.isEmpty ? "Section Title" : stripped
                replacement = "\(cmd){\(inner)}"
            }

            if tv.shouldChangeText(in: contentRange, replacementString: replacement) {
                tv.replaceCharacters(in: contentRange, with: replacement)
                tv.didChangeText()
                let cursor = contentRange.location + max(0, (replacement as NSString).length - (level == 0 ? 0 : 1))
                tv.setSelectedRange(NSRange(location: cursor, length: 0))
            }
        }
    }

    private static func stripLaTeXSectionWrapper(_ line: String) -> String {
        let pattern = #"^\s*\\(?:part|chapter|section|subsection|subsubsection|paragraph|subparagraph)\*?\{(.*)\}\s*$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let r = Range(match.range(at: 1), in: line)
        {
            return String(line[r])
        }
        return line.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
    }

    // MARK: - Block Insertion Commands

    public func insertCodeFence(language: String = "swift") {
        if isCurrentDocumentLaTeX {
            let snippet = "\n\\begin{verbatim}\n\n\\end{verbatim}\n"
            insertSnippetAtCursor(snippet, cursorOffsetFromStart: 18, summary: "Insert Verbatim Block")
            return
        }
        let snippet = "\n```\(language)\n\n```\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 5 + language.count, summary: "Insert Code Block")
    }

    public func insertMathBlock() {
        if isCurrentDocumentLaTeX {
            let snippet = "\n\\begin{equation}\n\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}\n\\end{equation}\n"
            insertSnippetAtCursor(snippet, cursorOffsetFromStart: 18, summary: "Insert Equation")
            return
        }
        let snippet = "\n$$\n\\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi}\n$$\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 4, summary: "Insert Math Block")
    }

    public func insertMermaidBlock() {
        let snippet = "\n```mermaid\ngraph TD\n    A[Start] --> B[End]\n```\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 12)
    }

    public func insertSVGBlock() {
        let snippet =
            "\n```svg\n<svg viewBox=\"0 0 120 40\"><rect x=\"4\" y=\"4\" width=\"112\" height=\"32\" rx=\"6\" fill=\"#3b82f6\"/><text x=\"60\" y=\"25\" fill=\"#ffffff\" text-anchor=\"middle\" font-size=\"13\">SVG</text></svg>\n```\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 8)
    }

    public func insertHorizontalRule() {
        let snippet = isCurrentDocumentLaTeX ? "\n\\noindent\\rule{\\textwidth}{0.4pt}\n" : "\n---\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: snippet.count, summary: "Insert Horizontal Rule")
    }

    public func insertTable(rows: Int, columns: Int) {
        let r = max(1, min(30, rows))
        let c = max(1, min(12, columns))
        if isCurrentDocumentLaTeX {
            let colSpec = Array(repeating: "l", count: c).joined(separator: " | ")
            let headers = (1...c).map { "\\textbf{Header \($0)}" }.joined(separator: " & ") + " \\\\"
            var lines = [
                "\\begin{tabular}{\(colSpec)}",
                "\\hline",
                headers,
                "\\hline"
            ]
            for rowIdx in 1...r {
                let cells = (1...c).map { "Row \(rowIdx) Col \($0)" }.joined(separator: " & ") + " \\\\"
                lines.append(cells)
            }
            lines.append("\\hline")
            lines.append("\\end{tabular}")
            let snippet = "\n" + lines.joined(separator: "\n") + "\n"
            insertSnippetAtCursor(snippet, cursorOffsetFromStart: 1, summary: "Insert LaTeX Table")
            return
        }
        let headers = (1...c).map { "Header \($0)" }.joined(separator: " | ")
        let sep = (1...c).map { _ in "---" }.joined(separator: " | ")
        var tableLines = [
            "| \(headers) |",
            "| \(sep) |"
        ]
        for rowIdx in 1...r {
            let cells = (1...c).map { "Row \(rowIdx) Col \($0)" }.joined(separator: " | ")
            tableLines.append("| \(cells) |")
        }
        let snippet = "\n" + tableLines.joined(separator: "\n") + "\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 3, summary: "Insert Table")
    }
}
