import Folio

@main
enum FolioApplicationMain {
    static func main() {
        FolioCLIManager.handleImmediateCLIFlagsIfNeeded()
        FolioApp.main()
    }
}
