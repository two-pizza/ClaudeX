import XCTest
@testable import ClaudeXPolicy

final class UpdateCheckTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("1.3.0", than: "1.2.5"))
        XCTAssertTrue(UpdateCheck.isNewer("1.2.10", than: "1.2.9"))
        XCTAssertTrue(UpdateCheck.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2.5", than: "1.2.5"))
        XCTAssertFalse(UpdateCheck.isNewer("1.3", than: "1.3.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2.4", than: "1.2.5"))
        XCTAssertFalse(UpdateCheck.isNewer("1.3.0-beta.1", than: "1.2.5"))
        XCTAssertFalse(UpdateCheck.isNewer("1.3.0", than: "garbage"))
    }

    func testTagParsing() {
        XCTAssertEqual(UpdateCheck.version(fromTag: "v1.2.5"), "1.2.5")
        XCTAssertEqual(UpdateCheck.version(fromTag: "1.3"), "1.3")
        XCTAssertNil(UpdateCheck.version(fromTag: "v1.3.0-beta.1"))
        XCTAssertNil(UpdateCheck.version(fromTag: "latest"))
        XCTAssertNil(UpdateCheck.version(fromTag: "v1..2"))
    }

    private func body(tag: String, prerelease: Bool = false, assetHost: String = "github.com",
                      page: String = "https://github.com/two-pizza/ClaudeX/releases/tag/v1.3.0") -> Data {
        """
        {"tag_name": "\(tag)", "html_url": "\(page)", "draft": false, "prerelease": \(prerelease),
         "assets": [{"name": "notes.txt", "browser_download_url": "https://github.com/x/notes.txt"},
                    {"name": "ClaudeX-1.3.0-menubar.zip",
                     "browser_download_url": "https://\(assetHost)/two-pizza/ClaudeX/releases/download/v1.3.0/ClaudeX-1.3.0-menubar.zip"}]}
        """.data(using: .utf8)!
    }

    func testNewerReleaseIsOffered() {
        guard case .available(let release) = UpdateCheck.outcome(data: body(tag: "v1.3.0"), current: "1.2.5")
        else { return XCTFail("expected an update") }
        XCTAssertEqual(release.version, "1.3.0")
        XCTAssertEqual(release.downloadURL?.lastPathComponent, "ClaudeX-1.3.0-menubar.zip")
    }

    func testSameOrOlderReleaseIsUpToDate() {
        XCTAssertEqual(UpdateCheck.outcome(data: body(tag: "v1.3.0"), current: "1.3.0"),
                       .upToDate(current: "1.3.0"))
        XCTAssertEqual(UpdateCheck.outcome(data: body(tag: "v1.2.5"), current: "1.3.0"),
                       .upToDate(current: "1.3.0"))
    }

    func testUntrustedOrOddReleasesAreRefused() {
        let prerelease = UpdateCheck.outcome(data: body(tag: "v1.4.0", prerelease: true), current: "1.3.0")
        XCTAssertEqual(prerelease, .failed("Could not read the latest release"))
        let foreignPage = UpdateCheck.outcome(data: body(tag: "v1.4.0", page: "https://evil.example/x"),
                                              current: "1.3.0")
        XCTAssertEqual(foreignPage, .failed("Could not read the latest release"))
        XCTAssertEqual(UpdateCheck.outcome(data: Data("{}".utf8), current: "1.3.0"),
                       .failed("Could not read the latest release"))
    }

    func testForeignDownloadHostIsDropped() {
        guard case .available(let release) = UpdateCheck.outcome(
            data: body(tag: "v1.4.0", assetHost: "evil.example"), current: "1.3.0")
        else { return XCTFail("expected an update") }
        XCTAssertNil(release.downloadURL, "only github.com downloads are offered")
    }

    func testNonHTTPSLinksAreRefused() {
        for scheme in ["http", "smb", "file"] {
            let page = UpdateCheck.outcome(
                data: body(tag: "v1.4.0", page: "\(scheme)://github.com/two-pizza/ClaudeX/releases/tag/v1.4.0"),
                current: "1.3.0")
            XCTAssertEqual(page, .failed("Could not read the latest release"), scheme)
        }
        let asset = Data("""
        {"tag_name": "v1.4.0", "html_url": "https://github.com/two-pizza/ClaudeX/releases/tag/v1.4.0",
         "assets": [{"name": "ClaudeX-1.4.0-menubar.zip", "browser_download_url": "smb://github.com/x.zip"}]}
        """.utf8)
        guard case .available(let release) = UpdateCheck.outcome(data: asset, current: "1.3.0")
        else { return XCTFail("expected an update") }
        XCTAssertNil(release.downloadURL, "a non-https asset is skipped, the page still offered")
    }
}

final class UpdateCheckerTests: XCTestCase {
    private var completions: [(UpdateCheck.Outcome) -> Void] = []
    private var shown: [UpdateCheck.Outcome] = []
    private var results: [UpdateCheck.Outcome] = []
    private var closeDialog: (() -> Void)?

    private func makeChecker() -> UpdateChecker {
        let checker = UpdateChecker { [unowned self] in self.completions.append($0) }
        checker.onResult = { [unowned self] in self.results.append($0) }
        checker.present = { [unowned self] outcome, done in
            self.shown.append(outcome)
            self.closeDialog = done
        }
        return checker
    }

    func testManualJoinsQuietCheckAndShowsOneDialog() {
        let checker = makeChecker()
        checker.check(manual: false)
        checker.check(manual: true)
        checker.check(manual: true)
        XCTAssertEqual(completions.count, 1, "one request in flight")
        completions[0](.upToDate(current: "1.3.0"))
        XCTAssertEqual(shown, [.upToDate(current: "1.3.0")])
        XCTAssertEqual(results.count, 1)
    }

    func testQuietCheckShowsNoDialog() {
        let checker = makeChecker()
        checker.check(manual: false)
        completions[0](.failed("offline"))
        XCTAssertEqual(results, [.failed("offline")])
        XCTAssertTrue(shown.isEmpty)
        XCTAssertFalse(checker.isChecking)
    }

    func testClicksWhileDialogIsOpenAreIgnored() {
        let checker = makeChecker()
        checker.check(manual: true)
        completions[0](.failed("offline"))
        checker.check(manual: true)
        XCTAssertEqual(completions.count, 1, "no new request while the dialog is open")
        closeDialog?()
        checker.check(manual: true)
        XCTAssertEqual(completions.count, 2)
        completions[1](.upToDate(current: "1.3.0"))
        XCTAssertEqual(shown, [.failed("offline"), .upToDate(current: "1.3.0")])
    }

    func testQuietCheckDuringOpenDialogUpdatesTitleOnly() {
        let checker = makeChecker()
        checker.check(manual: true)
        completions[0](.upToDate(current: "1.3.0"))
        checker.check(manual: false)
        completions[1](.failed("offline"))
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(results.count, 2)
    }
}
