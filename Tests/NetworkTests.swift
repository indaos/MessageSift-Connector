import XCTest
@testable import MessageSift_Connector

final class NetworkTests: XCTestCase {
    override func tearDown() { Keychain.testStore = [:] }

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
