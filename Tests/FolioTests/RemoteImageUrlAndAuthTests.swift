import AppKit
import Darwin
import Foundation
import XCTest
@testable import Folio

private final class LocalLoopbackAuthHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let acceptQueue = DispatchQueue(label: "com.folio.tests.loopback-http")
    private var isStopped = false

    static let sampleSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="160" height="80" viewBox="0 0 160 80">
          <rect width="160" height="80" rx="8" fill="#2563eb"/>
        </svg>
        """

    static let samplePNGData: Data = {
        let img = NSImage(size: NSSize(width: 120, height: 60))
        img.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 120, height: 60)).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            return Data()
        }
        return png
    }()

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        startAcceptLoop()
    }

    private func startAcceptLoop() {
        acceptQueue.async { [weak self] in
            while let self = self, !self.isStopped {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.listenFD, $0, &clientLen)
                    }
                }
                guard clientFD >= 0 else { break }
                self.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return }
        let request = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
        let lowerReq = request.lowercased()
        let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""

        let isAuthorized =
            lowerReq.contains("folio_session=secret_token_42")
            || lowerReq.contains("authorization: bearer secret_token_42")

        let statusLine: String
        let contentType: String
        let body: Data

        if firstLine.contains("/public/badge") {
            statusLine = "HTTP/1.1 200 OK"
            contentType = "image/svg+xml"
            body = Data(Self.sampleSVG.utf8)
        } else if firstLine.contains("/restricted/") {
            if isAuthorized {
                statusLine = "HTTP/1.1 200 OK"
                contentType = "image/png"
                body = Self.samplePNGData
            } else {
                statusLine = "HTTP/1.1 401 Unauthorized"
                contentType = "text/plain"
                body = Data("Unauthorized".utf8)
            }
        } else {
            statusLine = "HTTP/1.1 200 OK"
            contentType = "image/png"
            body = Self.samplePNGData
        }

        let header = "\(statusLine)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(body)
        _ = responseData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!, responseData.count)
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        close(listenFD)
    }

    deinit {
        stop()
    }
}

final class RemoteImageUrlAndAuthTests: XCTestCase {

    override func tearDown() {
        FolioMediaImageCache.shared.curlCommandPrefix = FolioMediaImageCache.defaultCurlCommandPrefix
        FolioMediaImageCache.shared.sshAuthConfig = .disabled
        FolioMediaImageCache.shared.clearRemoteCache()
        super.tearDown()
    }

    func testBuildCurlShellCommandAndResolveRemoteURL() {
        let resolved = FolioMediaImageCache.resolveRemoteURL(
            from: "https://media.example.com/chart.png?token=1&amp;size=large"
        )
        XCTAssertEqual(resolved?.absoluteString, "https://media.example.com/chart.png?token=1&size=large")
        let spaceURL = FolioMediaImageCache.resolveRemoteURL(
            from: "https://media.example.com/folder name/diagram.svg"
        )
        XCTAssertEqual(spaceURL?.absoluteString, "https://media.example.com/folder%20name/diagram.svg")

        let targetURL = URL(string: "https://media.example.com/img.png")!
        let defaultCmd = FolioMediaImageCache.buildCurlShellCommand(for: targetURL, commandPrefix: "curl")
        XCTAssertEqual(defaultCmd, "curl -sS -L --fail --max-time 30 'https://media.example.com/img.png'")

        let copyAsCurlSnippet = """
            curl 'https://internal.example.com/some/page' \\
              -H 'Authorization: Bearer secret_token_42' \\
              -b 'folio_session=secret_token_42'
            """
        let strippedCmd = FolioMediaImageCache.buildCurlShellCommand(for: targetURL, commandPrefix: copyAsCurlSnippet)
        XCTAssertEqual(
            strippedCmd,
            "curl -H 'Authorization: Bearer secret_token_42'    -b 'folio_session=secret_token_42' -sS -L --fail --max-time 30 'https://media.example.com/img.png'"
        )
    }

    @MainActor
    func testAuthenticatedRemoteImageFetchAndSettingsPersistence() throws {
        let server = try XCTUnwrap(LocalLoopbackAuthHTTPServer())
        defer { server.stop() }

        let defaults = isolatedDefaults()

        let viewModel = makeIsolatedViewModel(defaults: defaults)
        XCTAssertEqual(viewModel.mediaCurlCommandPrefix, "curl")

        let publicBadgeURL = "http://127.0.0.1:\(server.port)/public/badge"
        let restrictedURL = "http://127.0.0.1:\(server.port)/restricted/chart.png?a=1&amp;b=2"

        // 1. Trigger initial fetch without auth credentials
        XCTAssertNil(FolioMediaImageCache.shared.image(for: publicBadgeURL))
        XCTAssertNil(FolioMediaImageCache.shared.image(for: restrictedURL))
        XCTAssertTrue(FolioMediaImageCache.shared.waitUntilRemoteFetchesIdle())

        // Public extensionless SVG succeeds; restricted PNG fails (401)
        XCTAssertNotNil(FolioMediaImageCache.shared.image(for: publicBadgeURL))
        XCTAssertNil(FolioMediaImageCache.shared.image(for: restrictedURL))

        // 2. Configure custom curl command with auth cookie via Global Settings property
        viewModel.mediaCurlCommandPrefix = "curl -b \"folio_session=secret_token_42\""
        XCTAssertEqual(
            defaults.string(forKey: EditorWorkspaceViewModel.mediaCurlCommandPrefixDefaultsKey),
            "curl -b \"folio_session=secret_token_42\""
        )

        // 3. Re-request restricted URL; it should now succeed and decode the PNG image
        _ = FolioMediaImageCache.shared.image(for: restrictedURL)
        XCTAssertTrue(FolioMediaImageCache.shared.waitUntilRemoteFetchesIdle())
        let loadedImg = FolioMediaImageCache.shared.image(for: restrictedURL)
        XCTAssertNotNil(loadedImg)
        XCTAssertEqual(loadedImg?.size.width, 120)
        XCTAssertEqual(loadedImg?.size.height, 60)

        // 4. Verify Markdown inline, reference, and HTML <img> rendering with remote URLs
        let markdown = """
            # Remote Media

            ![Badge](\(publicBadgeURL))

            ![Restricted][ref-img]

            <img src="\(restrictedURL)" width="100" alt="HTML Restricted">

            [ref-img]: http://127.0.0.1:\(server.port)/restricted/chart.png
            """
        _ = FolioMediaImageCache.shared.image(for: "http://127.0.0.1:\(server.port)/restricted/chart.png")
        XCTAssertTrue(FolioMediaImageCache.shared.waitUntilRemoteFetchesIdle())

        let storage = NSTextStorage(string: markdown)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            typography: .default,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            prettyMode: true
        )
        let renderedURLs: [String] = analysis.decorations.compactMap {
            if case let .imageRendered(url, _, _, _, _, _, _) = $0.kind {
                return url
            }
            return nil
        }
        XCTAssertEqual(renderedURLs.count, 3)
        XCTAssertTrue(renderedURLs.contains(publicBadgeURL))
        XCTAssertTrue(renderedURLs.contains("http://127.0.0.1:\(server.port)/restricted/chart.png?a=1&b=2"))
        XCTAssertTrue(renderedURLs.contains("http://127.0.0.1:\(server.port)/restricted/chart.png"))

        // 5. Verify restoring a new ViewModel reads the persisted curl prefix from UserDefaults
        let restoredVM = makeIsolatedViewModel(defaults: defaults)
        XCTAssertEqual(restoredVM.mediaCurlCommandPrefix, "curl -b \"folio_session=secret_token_42\"")
    }
}
