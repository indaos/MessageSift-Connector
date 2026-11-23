import XCTest
@testable import MessageSift_Connector

final class NetworkTests: XCTestCase {
    override func tearDown() {
        Keychain.testStore = [:]
        NetworkGate.revoke(Array(NetworkGate.allowedHosts))
        NetworkGate.transport = { _ in throw URLError(.notConnectedToInternet) }
    }

    override func setUp() {
        // Tests never reach the network: every allowed request is answered here.
        NetworkGate.transport = { _ in throw URLError(.notConnectedToInternet) }
    }

    func testNoRequestGoesOutWithoutConsent() async throws {
        var sent: [String] = []
        NetworkGate.transport = { request in
            sent.append(request.url?.host ?? "")
            let body = Data(#"{"login":"kim"}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        Keychain.set("ghp-test", for: DevTool.github.tokenKey)
        XCTAssertTrue(NetworkSources.configured.isEmpty, "a key alone is not enough: network is off")
        do {
            _ = try await DevToolsClient(tool: .github).test()
            XCTFail("must not reach GitHub without consent")
        } catch NetworkGate.GateError.notAllowed(let host) {
            XCTAssertEqual(host, "api.github.com")
        }
        XCTAssertEqual(sent, [], "nothing went out")

        NetworkGate.allow(NetworkGate.hosts(for: .github))
        let connected = try await DevToolsClient(tool: .github).test()
        XCTAssertEqual(connected, "Connected as kim")
        XCTAssertEqual(sent, ["api.github.com"])
        XCTAssertEqual(NetworkSources.configured, [.github])

        // Another host (even with consent for GitHub) is refused.
        do {
            _ = try await URLSession.shared.data(for: URLRequest(url: URL(string: "https://example.com/x")!))
            XCTFail("unlisted host")
        } catch NetworkGate.GateError.notAllowed {}
        XCTAssertEqual(sent, ["api.github.com"])

        NetworkGate.revoke(NetworkGate.hosts(for: .github))
        XCTAssertTrue(NetworkSources.configured.isEmpty)
    }

    func testHostsPerService() {
        XCTAssertEqual(NetworkGate.hosts(for: .gitlab, server: "https://gitlab.example.org"), ["gitlab.example.org"])
        XCTAssertEqual(NetworkGate.hosts(for: .microsoft), ["login.microsoftonline.com", "graph.microsoft.com"])
        XCTAssertFalse(NetworkGate.isAllowed(URL(string: "http://api.github.com")!), "only https")
    }

    func testNetworkItemKeepsMessageSiftShape() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let m = HubMessage(id: "gitlab:https://g/x/-/merge_requests/1", source: .gitlab, sender: "Kim", senderHandle: "kim", title: "Fix login",
                           body: "Review requested", date: Date(timeIntervalSince1970: 1_799_000_000), isUnread: true, isDirect: true,
                           conversationID: "gitlab:1", context: "Review", link: URL(string: "https://g/x/-/merge_requests/1"), dueDate: due)
        let shared = try XCTUnwrap(SharedMessage(m))
        XCTAssertEqual(shared.source, .gitlab)
        XCTAssertEqual(shared.dueDate, due)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedFile.encode([shared])) as? [[String: Any]])
        XCTAssertEqual(json.first?["source"] as? String, "gitlab")
        XCTAssertNotNil(json.first?["dueDate"])
        XCTAssertNil(SharedMessage(HubMessage(id: "x", source: .mail, sender: "", senderHandle: "", title: "", body: "", date: Date(), conversationID: "x")))
    }

    func testConfiguredServicesFollowKeys() {
        XCTAssertTrue(NetworkSources.configured.isEmpty)
        Keychain.set("glpat-test", for: DevTool.gitlab.tokenKey)
        Keychain.set("xoxp-test", for: "slack-token")
        Keychain.set("jira-test", for: DevTool.jira.tokenKey)
        XCTAssertTrue(NetworkSources.configured.isEmpty, "network is off by default")
        NetworkGate.allow(["gitlab.com", "slack.com"])
        XCTAssertEqual(Set(NetworkSources.configured), [.gitlab, .slack], "Jira needs a site and email too")
    }

    func testServiceLinks() {
        XCTAssertEqual(Service(link: URL(string: "messagesift-connector://service/gitlab")!), .gitlab)
        XCTAssertEqual(Service(link: URL(string: "messagesift-connector://service/outlook")!), .microsoft)
        XCTAssertNil(Service(link: URL(string: "messagesift-connector://service/mail")!))
        XCTAssertNil(Service(link: URL(string: "messagesift-connector://other/gitlab")!))
    }

    func testStatusFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectorStatus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try SharedFile.writeStatus(ConnectorStatus(configured: ["gitlab"], errors: ["slack": "Token rejected (HTTP 401)"]), to: folder)
        let data = try Data(contentsOf: folder.appendingPathComponent(SharedFile.statusFileName))
        XCTAssertEqual(try JSONDecoder().decode(ConnectorStatus.self, from: data).configured, ["gitlab"])
    }
}
