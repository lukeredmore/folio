import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension EditorWorkspaceViewModel {

    // MARK: - HTML & PDF Export
    public func exportToHTML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = documentTitle.replacingOccurrences(of: ".md", with: "") + ".html"
        panel.directoryURL = workspaceFolderURL ?? currentFileURL?.deletingLastPathComponent()
        panel.allowedContentTypes = [.html]
        if panel.runModal() == .OK, let url = panel.url {
            let html = generateStandaloneHTML()
            try? html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    public func exportToPDF() {
        printDocument()
    }

    public func generateStandaloneHTML() -> String {
        let escapedLines = markdownText.components(separatedBy: .newlines).map { line -> String in
            if line.hasPrefix("# ") { return "<h1>\(line.dropFirst(2))</h1>" }
            if line.hasPrefix("## ") { return "<h2>\(line.dropFirst(3))</h2>" }
            if line.hasPrefix("### ") { return "<h3>\(line.dropFirst(4))</h3>" }
            if line.hasPrefix("> ") { return "<blockquote>\(line.dropFirst(2))</blockquote>" }
            if line.trimmingCharacters(in: .whitespaces) == "---" { return "<hr/>" }
            if line.isEmpty { return "" }
            return "<p>\(line)</p>"
        }.joined(separator: "\n")

        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <title>\(documentTitle)</title>
            <style>
            body {
                max-width: \(Int(theme.maxWriteWidth))px;
                margin: 40px auto;
                padding: 0 24px;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Georgia, serif;
                font-size: \(Int(theme.baseFontSize))px;
                line-height: 1.6;
            }
            blockquote { border-left: 4px solid #dfe2e5; padding-left: 16px; color: #6a737d; }
            pre, code { background: #f6f8fa; border-radius: 4px; padding: 2px 6px; font-family: ui-monospace, Menlo, monospace; }
            </style>
            </head>
            <body>
            \(escapedLines)
            </body>
            </html>
            """
    }

    // MARK: - Default Showcase Document
    public static let defaultWelcomeDocument = """
        # Folio — Native macOS Markdown Editor
        Welcome to **Folio**, a lightning-fast **100% native macOS** (`AppKit` + `TextKit` + `SwiftUI`) Markdown editor built for distraction-free writing.
        > **Seamless Live Rendering**: Place your cursor on any line to reveal and edit its raw Markdown tokens (`#`, `**`, `` ` ``, `[link](url)`). Move the cursor away and the syntax markers collapse cleanly into live typography—with zero WebView overhead.
        ---
        ## Key Features
        - [x] **Seamless Hybrid WYSIWYG Editor** (`HybridMarkdownTextView`) with zero-latency native TextKit layout
        - [x] **6 Curated Themes**: *Daylight*, *Midnight*, *Parchment*, *Editorial*, *Classic*, and *Modernist*
        - [x] **Focus Mode** (`F8`) & **Typewriter Mode** (`F9`) & **Source Code Mode** (`Cmd+/`)
        - [x] **Hierarchical Sidebar** (`Cmd+Shift+L`): Document **Outline**, **Files** (Tree & List views), and **Global Search**
        - [x] **Quick Open Modal** (`Cmd+P`) for instant fuzzy file switching
        - [x] **Live Word Count Popover** showing Words, Lines, Characters, and Reading Time
        ### Inline Typography & Math
        You can write **bold text**, *italicized emphasis*, ~~strikethrough~~, ==highlighted notes==, `inline code`, and [clickable links](https://example.com) effortlessly. Inline math like $E = mc^2$ and $\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\varepsilon_0}$ is styled live.
        $$
        \\mathcal{L}_{\\text{Folio}} = \\int_{-\\infty}^{\\infty} \\psi^*(x) \\left( -\\frac{\\hbar^2}{2m}\\nabla^2 + V(x) \\right) \\psi(x)\\,dx
        $$
        ### Native Code Fences with Syntax Highlighting
        ```swift
        import AppKit
        // Pure native TextKit rendering — 0 MB WebView footprint
        final class FolioEngine {
            func renderLiveMarkdown(in storage: NSTextStorage) -> Bool {
                let latencyMs = 0.15
                return latencyMs < 1.0
            }
        }
        ```
        ### Live Markdown Tables
        | Subsystem | Architecture | Performance |
        | :--- | :--- | :--- |
        | **UI Layer** | Pure `AppKit` + `SwiftUI` | Native 120Hz ProMotion |
        | **Editor Engine** | Native `NSTextStorage` + `TextKit` | Sub-millisecond restyling |
        | **State Sync** | Direct in-memory Swift state | Zero IPC serialization |
        | **Themes** | 6 Native `EditorTheme` Palettes | Instant switching |
        ### Rich Media, Diagrams & Inline HTML (Pretty Mode)
        Press <kbd>Cmd+Shift+P</kbd> for the Command Palette or toggle **Pretty Mode** with <kbd>Cmd+Shift+Backslash</kbd> to render <mark>inline HTML highlights</mark>, <u>underlines</u>, H<sub>2</sub>O, and x<sup>2</sup>.
        ```mermaid
        flowchart LR
            Markdown["Markdown Source"] --> Engine["Folio Rust Engine"]
            Engine --> Native["120Hz Native Canvas"]
        ```
        """
}
