import Folio

@main
enum FolioApplicationMain {
    static func main() {
        FolioProcessLimits.raiseOpenFileLimitIfNeeded()
        FolioCLIManager.handleImmediateCLIFlagsIfNeeded()
        FolioApp.main()
    }
}
