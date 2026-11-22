import SQLite3
import XCTest
@testable import MessageSift_Connector

/// Synthetic fixtures only; never real data.
final class ConnectorTests: XCTestCase {
    private func plist(_ req: [String: Any], date: Double? = nil) throws -> Data {
        var root: [String: Any] = ["req": req]
        if let date { root["date"] = date }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    private func record(_ app: String, _ req: [String: Any], id: String = "r1") throws -> NotificationParser.Record {
        .init(id: id, app: app, data: try plist(req), delivered: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    func testSlackChannelMention() throws {
        let r = try record("com.tinyspeck.slackmacgap", ["titl": "Sam Example in #general", "body": "Sam Example: @alex can you look?"])
        let m = try XCTUnwrap(NotificationParser.message(r, otherApps: [], appName: { $0 }))
        XCTAssertEqual(m.source, .slack)
        XCTAssertEqual(m.sender, "Sam Example")
        XCTAssertEqual(m.title, "#general")
        XCTAssertEqual(m.body, "@alex can you look?")
        XCTAssertFalse(m.isDirect)
        XCTAssertEqual(m.id, "slacknc:r1")
    }

    func testSlackDirectMessage() throws {
        let m = try XCTUnwrap(NotificationParser.message(try record("com.tinyspeck.slackmacgap", ["titl": "Sam Example", "body": "Lunch?"]),
                                                         otherApps: [], appName: { $0 }))
        XCTAssertTrue(m.isDirect)
        XCTAssertEqual(m.conversationID, "slack:Sam Example")
    }

    func testOtherAppsOnlyWhenChosen() throws {
        let r = try record("org.whispersystems.signal-desktop", ["titl": "Kim", "body": "Are you coming?"])
        XCTAssertNil(NotificationParser.message(r, otherApps: [], appName: { _ in "Signal" }))
        let m = try XCTUnwrap(NotificationParser.message(r, otherApps: ["org.whispersystems.signal-desktop"], appName: { _ in "Signal" }))
        XCTAssertEqual(m.source, .otherApps)
        XCTAssertEqual(m.context, "Signal")
        XCTAssertEqual(m.link?.absoluteString, "sgnl://")
    }

    func testEmptyNotificationIsSkipped() throws {
        XCTAssertNil(NotificationParser.message(try record("com.hnc.Discord", [:]), otherApps: ["com.hnc.Discord"], appName: { $0 }))
    }

    func testWhatsAppDirectGroupAndAnswered() {
        let chat = "41790000001@s.whatsapp.net", group = "123-456@g.us"
        let rows: [WhatsAppParser.Row] = [
            .init(id: 3, text: "Thanks!", date: 300, fromMe: true, type: 0, chatJID: chat),
            .init(id: 2, text: "Can you send the file?", date: 200, fromMe: false, type: 0, chatJID: chat, partner: "Kim"),
            .init(id: 4, text: "@41790000009 please check", date: 250, fromMe: false, type: 0, chatJID: group, partner: "Team",
                  memberName: "Lee", memberJID: "41790000002@s.whatsapp.net"),
            .init(id: 5, text: "Hello all", date: 260, fromMe: false, type: 0, chatJID: group, partner: "Team"),
            .init(id: 6, text: nil, date: 270, fromMe: false, type: 1, chatJID: chat, partner: "Kim"),
            .init(id: 7, text: "status", date: 280, fromMe: false, type: 0, chatJID: "status@broadcast"),
        ]
        let out = WhatsAppParser.messages(rows, me: ["41790000009"])
        XCTAssertEqual(out.map(\.id).sorted(), ["whatsapp:2", "whatsapp:3", "whatsapp:4", "whatsapp:6"])
        let ask = out.first { $0.id == "whatsapp:2" }!
        XCTAssertTrue(ask.isAnswered)
        XCTAssertTrue(ask.isDirect)
        XCTAssertEqual(ask.sender, "Kim")
        XCTAssertEqual(ask.link?.absoluteString, "whatsapp://send?phone=41790000001")
        XCTAssertEqual(out.first { $0.id == "whatsapp:6" }?.body, "📷 Photo")
        XCTAssertEqual(out.first { $0.id == "whatsapp:4" }?.context, "WhatsApp group")
    }

    /// The file must carry every key MessageSift's HubMessage decoder requires, with ISO 8601 dates.
    func testOutputFormat() throws {
        let m = SharedMessage(id: "other:1", source: .otherApps, sender: "Kim", senderHandle: "app", title: "Kim", body: "Hi",
                              date: Date(timeIntervalSince1970: 1_800_000_000), conversationID: "other:app:Kim", context: "Signal")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedFile.encode([m])) as? [[String: Any]])
        let required = ["id", "source", "sender", "senderHandle", "title", "body", "date", "isUnread", "isFlagged", "isFromMe",
                        "isAnswered", "isDirect", "conversationID", "context"]
        for key in required { XCTAssertNotNil(json[0][key], key) }
        XCTAssertEqual(json[0]["date"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(json[0]["source"] as? String, "otherApps")
    }

    func testWriteIsAtomicAndDeletable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let m = SharedMessage(id: "a", source: .slack, sender: "S", senderHandle: "S", title: "S", body: "b", date: Date(), conversationID: "c")
        try SharedFile.write([m], to: folder)
        let url = folder.appendingPathComponent(SharedFile.fileName)
        XCTAssertEqual(try JSONDecoder().decode([AnyCodableID].self, from: Data(contentsOf: url)).count, 1)
        try SharedFile.delete(in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNewestFirstAndCapped() throws {
        let items = (0..<(SharedFile.maxItems + 10)).map {
            SharedMessage(id: "\($0)", source: .slack, sender: "S", senderHandle: "S", title: "S", body: "b",
                          date: Date(timeIntervalSince1970: Double($0)), conversationID: "c")
        }
        let decoded = try JSONDecoder().decode([AnyCodableID].self, from: SharedFile.encode(items))
        XCTAssertEqual(decoded.count, SharedFile.maxItems)
        XCTAssertEqual(decoded.first?.id, "\(SharedFile.maxItems + 9)")
    }
}

private struct AnyCodableID: Decodable { let id: String }

/// A real (temporary, synthetic) SQLite file. Core Data TIMESTAMP columns return whole numbers as INTEGER.
final class ReaderTests: XCTestCase {
    func testWhatsAppRowWithIntegerDate() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wa-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE t (id INTEGER, chatjid TEXT, date TIMESTAMP, me INTEGER, type INTEGER, text TEXT); INSERT INTO t VALUES (1, '41790000001@s.whatsapp.net', 785000000, 0, 0, 'Hi'), (2, '41790000001@s.whatsapp.net', 785000000.5, 1, 0, 'Yes');", nil, nil, nil)
        sqlite3_close(db)
        let rows = try XCTUnwrap(ReadOnlyDatabase(path: path)).query("SELECT * FROM t ORDER BY id").compactMap(Sources.whatsAppRow)
        XCTAssertEqual(rows.map(\.date), [785000000, 785000000.5])
        XCTAssertEqual(rows.map(\.fromMe), [false, true])
    }
}
