import XCTest
@testable import ClaudeXPolicy

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class HTTPClientTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var session: URLSession!
    private let url = URL(string: "https://offline.invalid/usage")!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.handler = nil
    }

    func testRetryAfterSecondsDatesAndInvalidValues() {
        XCTAssertEqual(RetryAfter.date(" 3600 ", receivedAt: date), date.addingTimeInterval(3600))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'",
                       "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            let raw = formatter.string(from: date.addingTimeInterval(7200))
            XCTAssertEqual(RetryAfter.date(raw, receivedAt: date), date.addingTimeInterval(7200), raw)
        }
        for raw: String? in [nil, "", "garbage", "-5", "1.5", "NaN", "Infinity", "0",
                             String(repeating: "9", count: 400), "Fri, 31 Dec 1999 23:59:59 GMT"] {
            XCTAssertNil(RetryAfter.date(raw, receivedAt: date), raw ?? "nil")
        }
    }

    func test429PassesRetryAfterThroughWithoutRetryingOrLoggingCredentials() {
        let done = expectation(description: "429 delivered")
        var count = 0
        StubURLProtocol.handler = { request in
            count += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                    headerFields: ["rEtRy-AfTeR": "3600"])!, Data("private body".utf8))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer private-token", forHTTPHeaderField: "Authorization")
        HTTPClient.get(request, session: session, now: { self.date },
                       scheduleRetry: { _, _ in XCTFail("HTTP 429 must not retry internally") },
                       log: { text in
            XCTAssertTrue(text.contains("3600"))
            XCTAssertFalse(text.contains("private"))
        }) { result in
            guard case .failure(.rateLimited(let until)) = result else {
                XCTFail("Expected rate limit"); done.fulfill(); return
            }
            XCTAssertEqual(until, self.date.addingTimeInterval(3600))
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(count, 1)
    }

    func test429WithoutHeaderAndOtherHTTPFailuresCompleteOnce() {
        for status in [429, 401, 403, 500] {
            let done = expectation(description: "status \(status)")
            StubURLProtocol.handler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
            }
            HTTPClient.get(URLRequest(url: url), session: session,
                           scheduleRetry: { _, _ in XCTFail("HTTP status must not retry") }) { result in
                switch (status, result) {
                case (429, .failure(.rateLimited(let until))): XCTAssertNil(until)
                case (401, .failure(.unauthorized)), (403, .failure(.unauthorized)): break
                case (500, .failure(.http(500))): break
                default: XCTFail("Unexpected result: \(result)")
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 3)
        }
    }

    func testTransportRetriesStayInFlightAndFinalFailureReleasesGate() {
        let suite = "ClaudeXHTTPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = date
        var count = 0
        StubURLProtocol.handler = { _ in
            count += 1
            throw URLError(.networkConnectionLost)
        }
        var retry: (() -> Void)?
        var delays: [TimeInterval] = []
        var scheduled = expectation(description: "first transport retry")
        let finished = expectation(description: "final result applied")
        let c = RefreshCoordinator(defaults: defaults, now: { clock }, fetchers: [
            "claude": { completion in
                HTTPClient.get(URLRequest(url: self.url), session: self.session,
                               scheduleRetry: { delay, work in
                    DispatchQueue.main.async {
                        delays.append(delay)
                        retry = work
                        scheduled.fulfill()
                    }
                }) { result in
                    completion(result.map { _ in
                        ProviderUsage(id: "claude", title: "Claude", plan: "Test", rows: [], credits: nil)
                    })
                }
            }
        ])
        c.onSnapshotChange = { finished.fulfill() }
        c.refresh(trigger: .launch, interval: 60, showCodex: false)
        wait(for: [scheduled], timeout: 3)
        clock.addTimeInterval(600)
        for trigger in RefreshTrigger.allCases {
            c.refresh(trigger: trigger, interval: 60, showCodex: false)
        }
        XCTAssertTrue(c.hasRequestsInFlight)
        XCTAssertEqual(count, 1)
        scheduled = expectation(description: "second transport retry")
        retry!()
        wait(for: [scheduled], timeout: 3)
        XCTAssertEqual(delays, [3, 10])
        retry!()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(count, 3)
        XCTAssertFalse(c.hasRequestsInFlight)
        XCTAssertNotNil(c.errors["claude"])
    }
}
