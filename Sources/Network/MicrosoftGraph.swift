import AppKit
import Foundation

/// One Microsoft sign-in (OAuth device code flow) for Teams and Outlook through Microsoft Graph.
/// The refresh token is kept in the Keychain; the access token only in memory.
actor MSGraph {
    static let shared = MSGraph()

    static let scopes = "offline_access User.Read Mail.Read Chat.Read"
    private static let refreshKey = "msgraph-refresh"

    enum GraphError: LocalizedError {
        case noClientID, notSignedIn, http(Int, String), expired, declined, unexpected
        var errorDescription: String? {
            switch self {
            case .noClientID: return "Needs Client ID"
            case .notSignedIn: return "Needs sign-in"
            case .http(let code, let detail): return detail.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(detail)"
            case .expired: return "The code expired. Sign in again."
            case .declined: return "Sign-in was declined."
            case .unexpected: return "Unexpected response"
            }
        }
    }

    struct DeviceCode: Sendable {
        let userCode: String
        let verificationURL: URL
        let deviceCode: String
        let interval: Int
        let expiresAt: Date
    }

    nonisolated static var clientID: String {
        get {
            let own = (DataLocation.defaults.string(forKey: "msgraph-clientID") ?? "").trimmingCharacters(in: .whitespaces)
            return own.isEmpty ? OAuthProvider.microsoft.clientID : own
        }
        set { DataLocation.defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "msgraph-clientID") }
    }

    nonisolated static var tenant: String {
        get {
            let t = (DataLocation.defaults.string(forKey: "msgraph-tenant") ?? "").trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "organizations" : t
        }
        set { DataLocation.defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "msgraph-tenant") }
    }

    /// "Signed in as …", saved after sign-in so Settings can show it without a request.
    nonisolated static var accountName: String? {
        get { DataLocation.defaults.string(forKey: "msgraph-account") }
        set { DataLocation.defaults.set(newValue, forKey: "msgraph-account") }
    }

    nonisolated static var isSignedIn: Bool { !clientID.isEmpty && Keychain.get(refreshKey).map { !$0.isEmpty } == true }

    private var accessToken: String?
    private var accessExpiry = Date.distantPast

    private var tokenURL: URL { URL(string: "https://login.microsoftonline.com/\(Self.tenant)/oauth2/v2.0/token")! }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    private func post(_ url: URL, _ fields: [String: String]) async throws -> (Int, [String: Any]) {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Self.form(fields)
        let (data, response) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    func startDeviceCode() async throws -> DeviceCode {
        guard !Self.clientID.isEmpty else { throw GraphError.noClientID }
        let url = URL(string: "https://login.microsoftonline.com/\(Self.tenant)/oauth2/v2.0/devicecode")!
        let (status, json) = try await post(url, ["client_id": Self.clientID, "scope": Self.scopes])
        guard status == 200, let user = json["user_code"] as? String, let device = json["device_code"] as? String,
              let page = (json["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw GraphError.http(status, json["error_description"] as? String ?? "")
        }
        return DeviceCode(userCode: user, verificationURL: page, deviceCode: device, interval: json["interval"] as? Int ?? 5,
                          expiresAt: Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 900)))
    }

    /// Waits until the person finishes the sign-in in the browser.
    func completeSignIn(_ code: DeviceCode) async throws -> String {
        var interval = code.interval
        while Date() < code.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let (status, json) = try await post(tokenURL, [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "client_id": Self.clientID,
                "device_code": code.deviceCode,
            ])
            if status == 200 {
                try store(json)
                let me = try await get("https://graph.microsoft.com/v1.0/me?$select=displayName,mail,userPrincipalName")
                let name = (me["mail"] as? String) ?? (me["userPrincipalName"] as? String) ?? (me["displayName"] as? String) ?? "?"
                Self.accountName = name
                return name
            }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw GraphError.expired
            case "authorization_declined": throw GraphError.declined
            default: throw GraphError.http(status, json["error_description"] as? String ?? "")
            }
        }
        throw GraphError.expired
    }

    private func store(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String else { throw GraphError.unexpected }
        accessToken = access
        accessExpiry = Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600) - 120)
        if let refresh = json["refresh_token"] as? String { Keychain.set(refresh, for: Self.refreshKey) }
    }

    func signOut() {
        accessToken = nil
        accessExpiry = .distantPast
        Keychain.set(nil, for: Self.refreshKey)
        Self.accountName = nil
    }

    private func token() async throws -> String {
        guard !Self.clientID.isEmpty else { throw GraphError.noClientID }
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let refresh = Keychain.get(Self.refreshKey), !refresh.isEmpty else { throw GraphError.notSignedIn }
        let (status, json) = try await post(tokenURL, [
            "grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": refresh, "scope": Self.scopes,
        ])
        guard status == 200 else {
            if json["error"] as? String == "invalid_grant" { signOut(); throw GraphError.notSignedIn }
            throw GraphError.http(status, json["error_description"] as? String ?? "")
        }
        try store(json)
        return accessToken ?? ""
    }

    func get(_ url: String) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw GraphError.unexpected }
        var r = URLRequest(url: u, timeoutInterval: 20)
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GraphError.http(status, ((json["error"] as? [String: Any])?["code"] as? String) ?? "")
        }
        return json
    }
}

struct MSGraphClient {
    struct Me { let id: String; let address: String }

    private static let graph = "https://graph.microsoft.com/v1.0"

    func me() async throws -> Me {
        let json = try await MSGraph.shared.get("\(Self.graph)/me?$select=id,mail,userPrincipalName")
        return Me(id: json["id"] as? String ?? "", address: ((json["mail"] as? String) ?? (json["userPrincipalName"] as? String) ?? "").lowercased())
    }

    /// 1:1 and group chat messages from others, and messages in any chat that @mention you.
    func teams(since: Date, me: Me) async throws -> [HubMessage] {
        let chats = try await MSGraph.shared.get("\(Self.graph)/me/chats?$expand=lastMessagePreview&$top=50&$orderby=lastMessagePreview/createdDateTime%20desc")
        let recent = Self.recentChats(chats, since: since).prefix(25)
        let useApp = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "msteams:")!) != nil
        var out: [HubMessage] = []
        for chat in recent {
            guard let id = chat["id"] as? String,
                  let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ":@"))),
                  let messages = try? await MSGraph.shared.get("\(Self.graph)/chats/\(encoded)/messages?$top=30") else { continue }
            out += Self.parseChatMessages(messages, chat: chat, meID: me.id, since: since, useApp: useApp)
        }
        return out
    }

    /// Inbox messages, minus those Apple Mail already has (same Message-ID).
    func outlook(since: Date, knownMessageIDs: Set<String>) async throws -> [HubMessage] {
        let iso = ISO8601DateFormatter().string(from: since)
        let select = "id,subject,from,receivedDateTime,isRead,flag,bodyPreview,internetMessageId,webLink,conversationId"
        let json = try await MSGraph.shared.get("\(Self.graph)/me/mailFolders/inbox/messages?$filter=receivedDateTime%20ge%20\(iso)&$orderby=receivedDateTime%20desc&$top=50&$select=\(select)")
        return Self.parseOutlook(json, knownMessageIDs: knownMessageIDs)
    }

    // MARK: Parsing (pure, tested)

    private static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func recentChats(_ json: [String: Any], since: Date) -> [[String: Any]] {
        (json["value"] as? [[String: Any]] ?? []).filter { chat in
            let preview = chat["lastMessagePreview"] as? [String: Any]
            return (date(preview?["createdDateTime"]) ?? date(chat["lastUpdatedDateTime"]) ?? .distantPast) > since
        }
    }

    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func link(chatID: String, messageID: String, useApp: Bool) -> URL? {
        let context = "{\"contextType\":\"chat\"}".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let path = "/l/message/\(chatID)/\(messageID)?context=\(context)"
        return URL(string: useApp ? "msteams:\(path)" : "https://teams.microsoft.com\(path)")
    }

    static func parseChatMessages(_ json: [String: Any], chat: [String: Any], meID: String, since: Date, useApp: Bool) -> [HubMessage] {
        guard let chatID = chat["id"] as? String else { return [] }
        let chatType = chat["chatType"] as? String ?? ""
        let messages = (json["value"] as? [[String: Any]] ?? []).filter { ($0["messageType"] as? String ?? "message") == "message" }
        func senderID(_ m: [String: Any]) -> String? { ((m["from"] as? [String: Any])?["user"] as? [String: Any])?["id"] as? String }
        let myLastReply = messages.filter { senderID($0) == meID }.compactMap { date($0["createdDateTime"]) }.max()
        return messages.compactMap { m -> HubMessage? in
            guard let id = m["id"] as? String, let created = date(m["createdDateTime"]), created > since,
                  m["deletedDateTime"] == nil || m["deletedDateTime"] is NSNull,
                  let from = senderID(m), from != meID else { return nil }
            let mentioned = (m["mentions"] as? [[String: Any]] ?? []).contains {
                (($0["mentioned"] as? [String: Any])?["user"] as? [String: Any])?["id"] as? String == meID
            }
            guard chatType == "oneOnOne" || chatType == "group" || mentioned else { return nil }
            let body = plainText((m["body"] as? [String: Any])?["content"] as? String ?? "")
            guard !body.isEmpty else { return nil }
            let sender = ((m["from"] as? [String: Any])?["user"] as? [String: Any])?["displayName"] as? String ?? "Teams"
            let topic = (chat["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return HubMessage(
                id: "teams:\(chatID):\(id)", source: .teams, sender: sender, senderHandle: from,
                title: topic ?? sender, body: body, date: created, isUnread: true,
                isAnswered: myLastReply.map { $0 > created } ?? false,
                isDirect: chatType == "oneOnOne" || mentioned, conversationID: "teams:\(chatID)",
                context: mentioned ? "Mentioned you" : (chatType == "oneOnOne" ? "Teams chat" : "Teams group chat"),
                link: link(chatID: chatID, messageID: id, useApp: useApp))
        }
    }

    static func bareMessageID(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }

    static func parseOutlook(_ json: [String: Any], knownMessageIDs: Set<String>) -> [HubMessage] {
        (json["value"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["id"] as? String, let received = date(m["receivedDateTime"]) else { return nil }
            if let mid = m["internetMessageId"] as? String, knownMessageIDs.contains(bareMessageID(mid)) { return nil }
            let address = (m["from"] as? [String: Any])?["emailAddress"] as? [String: Any]
            let name = address?["name"] as? String ?? ""
            let email = address?["address"] as? String ?? ""
            let flagged = (m["flag"] as? [String: Any])?["flagStatus"] as? String == "flagged"
            return HubMessage(
                id: "outlook:\(id)", source: .outlook, sender: name.isEmpty ? email : name, senderHandle: email,
                title: (m["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(No subject)",
                body: m["bodyPreview"] as? String ?? "", date: received, isUnread: !(m["isRead"] as? Bool ?? false),
                isFlagged: flagged, conversationID: "outlook:\(m["conversationId"] as? String ?? id)",
                context: "Outlook · Inbox", link: (m["webLink"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// Message-IDs of the Apple Mail messages, read back from their message:// links.
    static func messageIDs(fromMailLinks links: [URL?]) -> Set<String> {
        Set(links.compactMap { url -> String? in
            guard let url, url.scheme == "message" else { return nil }
            let raw = url.absoluteString.dropFirst("message://".count)
            return bareMessageID(String(raw).removingPercentEncoding ?? String(raw))
        })
    }
}
