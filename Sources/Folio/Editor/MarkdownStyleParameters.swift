import AppKit

/// Inputs of a Markdown restyle other than the text and the selection. Two passes with equal
/// parameters, text, and selection produce the same attributes, decorations, and headings.
struct MarkdownStyleParameters: Equatable {
    let theme: EditorTheme
    let typography: EditorTypographySettings
    let sourceCodeMode: Bool
    let focusMode: Bool
    let containerWidth: CGFloat
    let prettyMode: Bool
    let baseDirectoryURL: URL?
    let textAlignment: NSTextAlignment
    let fileURL: URL?
}

extension MarkdownLiveStyler {
    @discardableResult
    static func applyStyles(
        to storage: NSTextStorage,
        parameters: MarkdownStyleParameters,
        selectedRange: NSRange
    ) -> MarkdownDocumentAnalysis {
        applyStyles(
            to: storage,
            theme: parameters.theme,
            typography: parameters.typography,
            sourceCodeMode: parameters.sourceCodeMode,
            focusMode: parameters.focusMode,
            selectedRange: selectedRange,
            containerWidth: parameters.containerWidth,
            prettyMode: parameters.prettyMode,
            baseDirectoryURL: parameters.baseDirectoryURL,
            textAlignment: parameters.textAlignment,
            fileURL: parameters.fileURL
        )
    }
}

extension HybridMarkdownEditorRepresentable.Coordinator {
    /// Style parameters for the current view model settings and text view width.
    func styleParameters(for textView: HybridMarkdownTextView) -> MarkdownStyleParameters {
        MarkdownStyleParameters(
            theme: viewModel.theme,
            typography: viewModel.typography,
            sourceCodeMode: viewModel.sourceCodeMode,
            focusMode: viewModel.focusMode,
            containerWidth: currentContentWidth(for: textView),
            prettyMode: viewModel.prettyModeEnabled,
            baseDirectoryURL: viewModel.currentFileURL?.deletingLastPathComponent() ?? viewModel.workspaceFolderURL,
            textAlignment: viewModel.textAlignment.nsAlignment,
            fileURL: viewModel.currentFileURL
        )
    }
}
