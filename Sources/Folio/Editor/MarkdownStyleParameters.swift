import AppKit

/// Inputs of a Markdown restyle other than the text and the selection. Two passes with equal
/// parameters, text, and selection produce the same attributes, decorations, and headings.
package struct MarkdownStyleParameters: Equatable {
    package let theme: EditorTheme
    package let typography: EditorTypographySettings
    package let sourceCodeMode: Bool
    package let focusMode: Bool
    package let containerWidth: CGFloat
    package let prettyMode: Bool
    package let baseDirectoryURL: URL?
    package let textAlignment: NSTextAlignment
    package let fileURL: URL?

    package init(
        theme: EditorTheme,
        typography: EditorTypographySettings,
        sourceCodeMode: Bool,
        focusMode: Bool,
        containerWidth: CGFloat,
        prettyMode: Bool,
        baseDirectoryURL: URL?,
        textAlignment: NSTextAlignment,
        fileURL: URL?
    ) {
        self.theme = theme
        self.typography = typography
        self.sourceCodeMode = sourceCodeMode
        self.focusMode = focusMode
        self.containerWidth = containerWidth
        self.prettyMode = prettyMode
        self.baseDirectoryURL = baseDirectoryURL
        self.textAlignment = textAlignment
        self.fileURL = fileURL
    }
}

extension MarkdownLiveStyler {
    @discardableResult
    package static func applyStyles(
        to storage: NSTextStorage,
        parameters: MarkdownStyleParameters,
        selectedRange: NSRange
    ) -> MarkdownDocumentAnalysis {
        styleDocument(storage, parameters: parameters, selectedRange: selectedRange).analysis
    }
}
