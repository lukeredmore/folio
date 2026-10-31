import AppKit
import Foundation

extension EditorWorkspaceViewModel {

    public static let typographyDefaultsKey = "Folio.EditorTypographySettings.v2"
    public static let customThemesDefaultsKey = "Folio.CustomEditorThemes.v1"
    public static let activeThemeDataDefaultsKey = "Folio.ActiveEditorThemeData.v1"
    public static let workspaceFolderPathDefaultsKey = "Folio.WorkspaceFolderPath.v1"
    public static let workspaceFolderBookmarkDefaultsKey = "Folio.WorkspaceFolderBookmark.v1"
    public static let localFolderPathsDefaultsKey = "Folio.LocalFolderPaths.v1"
    public static let currentFilePathDefaultsKey = "Folio.CurrentFilePath.v1"
    public static let currentFileBookmarkDefaultsKey = "Folio.CurrentFileBookmark.v1"
    public static let unsavedBufferTextDefaultsKey = "Folio.UnsavedBufferText.v1"
    public static let unsavedBufferIsDirtyDefaultsKey = "Folio.UnsavedBufferIsDirty.v1"
    public static let hasSavedDocumentSessionDefaultsKey = "Folio.HasSavedDocumentSession.v1"
    public static let recentFilePathsDefaultsKey = "Folio.RecentFilePaths.v1"
    public static let themeDefaultsKey = "Folio.EditorTheme.v1"
    public static let sourceCodeModeDefaultsKey = "Folio.SourceCodeMode.v1"
    public static let focusModeDefaultsKey = "Folio.FocusMode.v1"
    public static let typewriterModeDefaultsKey = "Folio.TypewriterMode.v1"
    public static let spellCheckEnabledDefaultsKey = "Folio.SpellCheckEnabled.v1"
    public static let sourceLineWidthDefaultsKey = "Folio.SourceLineWidth.v1"
    public static let mediaCurlCommandPrefixDefaultsKey = "Folio.MediaCurlCommandPrefix.v1"
    public static let mediaUseSSHAuthDefaultsKey = "Folio.MediaUseSSHAuth.v1"
    public static let mediaSSHIdentityFileDefaultsKey = "Folio.MediaSSHIdentityFile.v1"
    public static let mediaSSHUserDefaultsKey = "Folio.MediaSSHUser.v1"
    public static let showSidebarDefaultsKey = "Folio.ShowSidebar.v1"
    public static let activeSidebarTabDefaultsKey = "Folio.ActiveSidebarTab.v1"
    public static let fileDisplayStyleDefaultsKey = "Folio.FileDisplayStyle.v1"
    public static let fileSortOrderDefaultsKey = "Folio.FileSortOrder.v1"
    public static let collapsedDirectoryPathsDefaultsKey = "Folio.CollapsedDirectoryPaths.v1"
    public static let selectedCursorLocationDefaultsKey = "Folio.SelectedCursorLocation.v1"
    public static let undoTimelinesDefaultsKey = "Folio.PerFileUndoTimelines.v1"

    public func resetTypographyToDefaults() {
        typography = .default
    }

    public func resetMediaCurlCommandPrefixToDefault() {
        mediaCurlCommandPrefix = FolioMediaImageCache.defaultCurlCommandPrefix
        useSSHAuthForMedia = false
        mediaSSHIdentityFile = ""
        mediaSSHUser = ""
    }

    public func reloadRemoteMediaImages() {
        syncMediaSSHAuthConfig()
        FolioMediaImageCache.shared.clearRemoteCache()
    }

    public func syncMediaSSHAuthConfig() {
        FolioMediaImageCache.shared.sshAuthConfig = FolioMediaSSHAuthConfig(
            isEnabled: useSSHAuthForMedia,
            identityFile: mediaSSHIdentityFile,
            user: mediaSSHUser,
            mounts: remoteWorkspaceManager.mounts
        )
    }

    public func applySSHAuthFromMount(_ mount: RemoteMountSpec) {
        useSSHAuthForMedia = true
        if let user = mount.user, !user.isEmpty {
            mediaSSHUser = user
        }
        if let key = mount.identityFile, !key.isEmpty {
            mediaSSHIdentityFile = key
        }
        syncMediaSSHAuthConfig()
    }
}
