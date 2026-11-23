import Foundation

/// One shared item, in exactly the JSON shape MessageSift (App Store edition) decodes as `HubMessage`.
/// Every non-optional key must be present, or MessageSift can't read the file.
struct SharedMessage: Codable, Equatable {
    enum Source: String, Codable { case slack, whatsapp, otherApps, github, gitlab, jira, linear, teams, outlook }

    var id: String
    var source: Source
    var sender: String
    var senderHandle: String
    var title: String
    var body: String
    var date: Date
    var isUnread = true
    var isFlagged = false
    var isFromMe = false
    var isAnswered = false
    var isDirect = false
    var conversationID: String
    var context = ""
    var link: URL?
    var dueDate: Date?
    var slackTeam: String?
    var slackChannel: String?
    var slackTs: String?
    var slackThreadTs: String?
}

/// Network status for MessageSift: which services have a key here and their last error (no keys, no content).
struct ConnectorStatus: Codable, Equatable {
    var configured: [String]
    var errors: [String: String]
}

enum SharedFile {
    static let appGroupID = "5PMP974V72.com.dmikaya.MessageHub.store"
    static let fileName = "connector-messages.json"
    static let maxItems = 3000

    /// The store edition's App Group folder (needs the application-groups entitlement for that group).
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func encode(_ messages: [SharedMessage]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let newestFirst = messages.sorted { $0.date > $1.date }.prefix(maxItems)
        return try encoder.encode(Array(newestFirst))
    }

    /// Replaces the file in one step, so MessageSift never reads half a file.
    static func write(_ messages: [SharedMessage], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encode(messages).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    static let statusFileName = "connector-status.json"

    static func writeStatus(_ status: ConnectorStatus, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(status).write(to: folder.appendingPathComponent(statusFileName), options: .atomic)
    }

    static func delete(in folder: URL) throws {
        let url = folder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
