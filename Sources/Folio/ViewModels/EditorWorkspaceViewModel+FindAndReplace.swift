import AppKit
import Foundation
import SwiftUI

extension EditorWorkspaceViewModel {

    // MARK: - Document Find (`Cmd+F`) & Find and Replace (`Cmd+R`)

    public func openDocumentFind(withReplace: Bool) {
        if let selText = singleLineSelectedText(), !selText.isEmpty {
            findQuery = selText
        }
        showFindReplaceBar = true
        showDocumentReplaceControls = withReplace
        findBarFocusRequestID &+= 1
    }

    public func closeDocumentFindBar() {
        showFindReplaceBar = false
        if let tv = activeTextView, let window = tv.window {
            window.makeFirstResponder(tv)
        }
    }

    public var documentFindMatchCount: Int {
        guard !findQuery.isEmpty else { return 0 }
        let nsStr = markdownText as NSString
        var count = 0
        var searchLoc = 0
        while searchLoc < nsStr.length {
            let range = NSRange(location: searchLoc, length: nsStr.length - searchLoc)
            let found = nsStr.range(of: findQuery, options: [.caseInsensitive], range: range)
            if found.location == NSNotFound || found.length == 0 {
                break
            }
            count += 1
            searchLoc = NSMaxRange(found)
        }
        return count
    }

    public func findNextInDocument() {
        guard !findQuery.isEmpty else { return }
        let sourceText = activeTextView?.string ?? markdownText
        let nsStr = sourceText as NSString
        let currentSel = activeTextView?.selectedRange() ?? currentSelectedRange
        let startLoc = min(NSMaxRange(currentSel), nsStr.length)
        let searchRange = NSRange(location: startLoc, length: nsStr.length - startLoc)

        var found = nsStr.range(of: findQuery, options: [.caseInsensitive], range: searchRange)
        if found.location == NSNotFound && startLoc > 0 {
            found = nsStr.range(of: findQuery, options: [.caseInsensitive], range: NSRange(location: 0, length: startLoc))
        }
        if found.location != NSNotFound {
            currentSelectedRange = found
            if let tv = activeTextView {
                tv.setSelectedRange(found)
                tv.scrollRangeToVisible(found)
            }
        }
    }

    public func findPreviousInDocument() {
        guard !findQuery.isEmpty else { return }
        let sourceText = activeTextView?.string ?? markdownText
        let nsStr = sourceText as NSString
        let currentSel = activeTextView?.selectedRange() ?? currentSelectedRange
        let startLoc = min(currentSel.location, nsStr.length)

        var found = NSRange(location: NSNotFound, length: 0)
        if startLoc > 0 {
            found = nsStr.range(
                of: findQuery,
                options: [.caseInsensitive, .backwards],
                range: NSRange(location: 0, length: startLoc)
            )
        }
        if found.location == NSNotFound && nsStr.length > startLoc {
            found = nsStr.range(
                of: findQuery,
                options: [.caseInsensitive, .backwards],
                range: NSRange(location: startLoc, length: nsStr.length - startLoc)
            )
        }
        if found.location != NSNotFound {
            currentSelectedRange = found
            if let tv = activeTextView {
                tv.setSelectedRange(found)
                tv.scrollRangeToVisible(found)
            }
        }
    }

    public func replaceCurrentMatch() {
        guard !findQuery.isEmpty else { return }
        if let tv = activeTextView {
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            if sel.length > 0 && nsStr.substring(with: sel).caseInsensitiveCompare(findQuery) == .orderedSame {
                withUndoMetadata(origin: .findReplace, summary: "Replace") {
                    if tv.shouldChangeText(in: sel, replacementString: replaceQuery) {
                        tv.replaceCharacters(in: sel, with: replaceQuery)
                        tv.didChangeText()
                    }
                }
            }
            findNextInDocument()
            return
        }

        let nsStr = markdownText as NSString
        let sel = currentSelectedRange
        if sel.length > 0,
            NSMaxRange(sel) <= nsStr.length,
            nsStr.substring(with: sel).caseInsensitiveCompare(findQuery) == .orderedSame
        {
            withUndoMetadata(origin: .findReplace, summary: "Replace") {
                markdownText = nsStr.replacingCharacters(in: sel, with: replaceQuery)
                currentSelectedRange = NSRange(location: sel.location + (replaceQuery as NSString).length, length: 0)
            }
        }
        findNextInDocument()
    }

    public func replaceAllInDocument() {
        guard !findQuery.isEmpty else { return }
        let updated = markdownText.replacingOccurrences(of: findQuery, with: replaceQuery, options: [.caseInsensitive])
        if updated != markdownText {
            withUndoMetadata(origin: .findReplace, summary: "Replace All") {
                markdownText = updated
                if let tv = activeTextView {
                    let clamped = DocumentLineDiff.adjustedSelection(
                        for: tv.selectedRange(),
                        inOldText: tv.string,
                        toNewText: updated
                    )
                    tv.applyProgrammaticDocumentText(updated, selectedRange: clamped)
                }
            }
        }
    }

    // MARK: - Workspace Search (`Cmd+Shift+F`) & Workspace Replace (`Cmd+Shift+R`)

    public func openWorkspaceSearch(withReplace: Bool) {
        if let selText = singleLineSelectedText(), !selText.isEmpty {
            workspaceSearchQuery = selText
        }
        showSidebar = true
        activeSidebarTab = .files
        showWorkspaceReplace = withReplace
        workspaceSearchFocusRequestID &+= 1
        if !workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            performWorkspaceSearch()
        }
    }

    public func makeWorkspaceSearchRegex() -> NSRegularExpression? {
        let query = workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let pattern: String
        if searchUseRegex {
            pattern = query
        } else if searchWholeWord {
            pattern = "\\b\(NSRegularExpression.escapedPattern(for: query))\\b"
        } else {
            pattern = NSRegularExpression.escapedPattern(for: query)
        }
        let regexOptions: NSRegularExpression.Options = searchCaseSensitive ? [] : [.caseInsensitive]
        return try? NSRegularExpression(pattern: pattern, options: regexOptions)
    }

    public var effectiveWorkspaceReplacementTemplate: String {
        searchUseRegex
            ? workspaceReplaceQuery
            : NSRegularExpression.escapedTemplate(for: workspaceReplaceQuery)
    }

    @discardableResult
    public func replaceAllInWorkspace() -> Int {
        guard let regex = makeWorkspaceSearchRegex() else { return 0 }
        let template = effectiveWorkspaceReplacementTemplate
        var modifiedFilesCount = 0

        if currentFileURL == nil {
            let nsLen = (markdownText as NSString).length
            let updated = regex.stringByReplacingMatches(
                in: markdownText,
                options: [],
                range: NSRange(location: 0, length: nsLen),
                withTemplate: template
            )
            if updated != markdownText {
                applyWorkspaceReplacementToActiveDocument(updated)
                modifiedFilesCount += 1
            }
        }

        let currentStdURL = currentFileURL?.standardizedFileURL
        for fileNode in flatMarkdownFiles {
            let fileStdURL = fileNode.url.standardizedFileURL
            if let currentStdURL, fileStdURL == currentStdURL {
                let nsLen = (markdownText as NSString).length
                let updated = regex.stringByReplacingMatches(
                    in: markdownText,
                    options: [],
                    range: NSRange(location: 0, length: nsLen),
                    withTemplate: template
                )
                if updated != markdownText {
                    applyWorkspaceReplacementToActiveDocument(updated)
                    performDiskWrite(updated, to: fileNode.url)
                    modifiedFilesCount += 1
                }
            } else if let diskText = try? String(contentsOf: fileNode.url, encoding: .utf8) {
                let nsLen = (diskText as NSString).length
                let updated = regex.stringByReplacingMatches(
                    in: diskText,
                    options: [],
                    range: NSRange(location: 0, length: nsLen),
                    withTemplate: template
                )
                if updated != diskText {
                    try? Data(updated.utf8).write(to: fileNode.url, options: .atomic)
                    if remoteWorkspaceManager.isRemoteURL(fileNode.url) {
                        enqueueRemoteUpload(updated, to: fileNode.url)
                    }
                    modifiedFilesCount += 1
                }
            }
        }

        performWorkspaceSearch()
        return modifiedFilesCount
    }

    public func replaceWorkspaceMatch(_ match: WorkspaceSearchMatch) {
        guard let regex = makeWorkspaceSearchRegex() else { return }
        let template = effectiveWorkspaceReplacementTemplate
        let currentStdURL = currentFileURL?.standardizedFileURL
        let matchStdURL = match.fileURL.standardizedFileURL

        if (currentFileURL == nil && match.fileURL.path == "/Untitled.md") || (currentStdURL != nil && matchStdURL == currentStdURL) {
            let nsStr = markdownText as NSString
            guard NSMaxRange(match.matchRangeInFile) <= nsStr.length else { return }
            let updated = regex.stringByReplacingMatches(
                in: markdownText,
                options: [],
                range: match.matchRangeInFile,
                withTemplate: template
            )
            if updated != markdownText {
                applyWorkspaceReplacementToActiveDocument(updated)
                if let url = currentFileURL {
                    performDiskWrite(updated, to: url)
                }
            }
        } else if let diskText = try? String(contentsOf: match.fileURL, encoding: .utf8) {
            let nsStr = diskText as NSString
            guard NSMaxRange(match.matchRangeInFile) <= nsStr.length else { return }
            let updated = regex.stringByReplacingMatches(
                in: diskText,
                options: [],
                range: match.matchRangeInFile,
                withTemplate: template
            )
            if updated != diskText {
                try? Data(updated.utf8).write(to: match.fileURL, options: .atomic)
                if remoteWorkspaceManager.isRemoteURL(match.fileURL) {
                    enqueueRemoteUpload(updated, to: match.fileURL)
                }
            }
        }
        performWorkspaceSearch()
    }

    private func applyWorkspaceReplacementToActiveDocument(_ updated: String) {
        withUndoMetadata(origin: .findReplace, summary: "Replace in Files") {
            markdownText = updated
            if let tv = activeTextView {
                let clamped = DocumentLineDiff.adjustedSelection(
                    for: tv.selectedRange(),
                    inOldText: tv.string,
                    toNewText: updated
                )
                tv.applyProgrammaticDocumentText(updated, selectedRange: clamped)
            }
        }
    }

    private func singleLineSelectedText() -> String? {
        let sourceText = activeTextView?.string ?? markdownText
        let sel = activeTextView?.selectedRange() ?? currentSelectedRange
        let nsStr = sourceText as NSString
        guard sel.length > 0, NSMaxRange(sel) <= nsStr.length else { return nil }
        let sub = nsStr.substring(with: sel)
        guard !sub.contains("\n"), !sub.contains("\r") else { return nil }
        return sub
    }
}
