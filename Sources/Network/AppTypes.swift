import Foundation
import Security

// The Slack, GitHub, GitLab, Jira, Linear and Microsoft readers are copied from MessageSift (Developer ID edition)
// unchanged. These are the few MessageSift types they use, in the same shape.

enum MessageSource: String, Codable, Hashable {
    case mail, messages, slack, whatsapp, document, calendar, reminders, otherApps, github, gitlab, jira, linear, teams, outlook
}

/// MessageSift's message model, field for field (the readers build these; `SharedMessage(_:)` converts them).
struct HubMessage: Codable, Identifiable, Hashable {
    var id: String
    var source: MessageSource
    var sender: String
    var senderHandle: String
    var title: String
    var body: String
    var date: Date
    var isUnread: Bool = false
    var isFlagged: Bool = false
    var isFromMe: Bool = false
    var isAnswered: Bool = false
    var isDirect: Bool = false
    var conversationID: String
    var context: String = ""
    var link: URL?
    var dueDate: Date?
    var slackTeam: String?
    var slackChannel: String?
    var slackTs: String?
    var slackThreadTs: String?
    var resolvedReason: String?
}

/// Settings of the Connector itself (its own preferences).
enum DataLocation {
    static var defaults: UserDefaults {
        isRunningTests ? testDefaults : .standard
    }

    static var applicationSupport: URL {
        isRunningTests ? FileManager.default.temporaryDirectory.appendingPathComponent("ConnectorTests-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MessageSift Connector", isDirectory: true)
    }

    static let isRunningTests = NSClassFromString("XCTestCase") != nil
    private static let testDefaults: UserDefaults = {
        let name = "com.dmikaya.MessageHub.Connector.tests"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }()
}

/// Keys in the Connector's own Keychain items (MessageSift never reads them).
enum Keychain {
    private static let service = "com.dmikaya.MessageHub.Connector"

    static func get(_ account: String) -> String? {
        guard !DataLocation.isRunningTests else { return testStore[account] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        guard !DataLocation.isRunningTests else { testStore[account] = value; return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Unit tests never touch the real Keychain.
    nonisolated(unsafe) static var testStore: [String: String] = [:]
}

/// The Connector uses keys only (no sign-in apps), so these do nothing.
enum OAuthProvider: String { case slack, github, gitlab, atlassian, linear, microsoft
    var clientID: String { "" }
}

enum OAuth {
    static func isOAuthToken(_ provider: OAuthProvider) -> Bool { false }
    static func refreshIfNeeded(_ provider: OAuthProvider) async {}
    static func markManual(_ provider: OAuthProvider) {}
}

/// The one text check the work rules use, as in MessageSift.
enum UrgencyEngine {
    private static let asksRegex = try! NSRegularExpression(
        pattern: #"\b(can you|could you|would you|will you|please|pls|need you to|let me know|lmk|waiting (on|for) you|any update|action required|response required|respond by|kannst du|könntest du|können sie|könnten sie|bitte|pourriez-vous|pouvez-vous|merci de|puoi|potresti|per favore)\b"#,
        options: [.caseInsensitive])

    static func asksSomething(_ text: String) -> Bool {
        text.contains("?") || asksRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

extension MessageSource {
    var displayName: String {
        switch self {
        case .slack: return "Slack"
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .jira: return "Jira"
        case .linear: return "Linear"
        case .teams: return "Teams"
        case .outlook: return "Outlook"
        case .whatsapp: return "WhatsApp"
        default: return rawValue
        }
    }
}

extension ISO8601DateFormatter {
    /// "2026-11-23" or a full ISO date.
    static func flexible(_ s: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let d = full.date(from: s) { return d }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: String(s.prefix(10)))
    }
}

enum DeepLinks {
    static func slack(workspaceURL: String, channelID: String, ts: String, threadTS: String? = nil) -> URL? {
        guard !workspaceURL.isEmpty, !channelID.isEmpty, !ts.isEmpty else { return nil }
        let base = workspaceURL.hasSuffix("/") ? workspaceURL : workspaceURL + "/"
        var link = "\(base)archives/\(channelID)/p\(ts.replacingOccurrences(of: ".", with: ""))"
        if let threadTS, threadTS != ts { link += "?thread_ts=\(threadTS)&cid=\(channelID)" }
        return URL(string: link)
    }
}
