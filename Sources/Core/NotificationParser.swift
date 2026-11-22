import Foundation

/// Turns Notification Center records (binary plists) into shared items: Slack, WhatsApp and other chat apps.
enum NotificationParser {
    struct Record {
        var id: String
        var app: String
        var data: Data
        var delivered: Date?
    }

    /// Chat apps shared by default when they show notifications.
    static let defaultApps = ["org.whispersystems.signal-desktop", "com.hnc.Discord", "ru.keepcoder.Telegram",
                              "com.tdesktop.Telegram", "com.microsoft.teams2", "com.microsoft.teams"]

    static func isSlack(_ app: String) -> Bool { app.lowercased().contains("slack") }
    static func isWhatsApp(_ app: String) -> Bool { app.lowercased().contains("whatsapp") }

    struct Fields { var title: String; var subtitle: String; var body: String; var date: Date }

    static func fields(_ r: Record) -> Fields? {
        guard let root = (try? PropertyListSerialization.propertyList(from: r.data, options: [], format: nil)) as? [String: Any] else { return nil }
        let req = root["req"] as? [String: Any] ?? root
        func text(_ key: String) -> String { (req[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let f = Fields(title: text("titl"), subtitle: text("subt"), body: text("body"),
                       date: r.delivered ?? (root["date"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) ?? Date())
        return f.title.isEmpty && f.body.isEmpty ? nil : f
    }

    /// One record, or nil when it is empty or from an app that isn't shared.
    static func message(_ r: Record, otherApps: Set<String>, appName: (String) -> String) -> SharedMessage? {
        guard let f = fields(r) else { return nil }
        if isSlack(r.app) { return slack(r, f) }
        if isWhatsApp(r.app) {
            guard !f.body.isEmpty else { return nil }
            let who = f.title.isEmpty ? "WhatsApp" : f.title
            return SharedMessage(id: "whatsappnc:\(r.id)", source: .whatsapp, sender: who, senderHandle: f.title, title: who,
                                 body: f.body, date: f.date, isDirect: true, conversationID: "whatsapp:nc:\(f.title)",
                                 context: "WhatsApp notification", link: URL(string: "whatsapp://"))
        }
        guard otherApps.contains(r.app) else { return nil }
        let name = appName(r.app)
        let conversation = f.subtitle.isEmpty ? f.title : f.subtitle
        return SharedMessage(id: "other:\(r.id)", source: .otherApps, sender: f.title.isEmpty ? name : f.title, senderHandle: r.app,
                             title: f.subtitle.isEmpty ? (f.title.isEmpty ? name : f.title) : f.subtitle, body: f.body, date: f.date,
                             isDirect: f.subtitle.isEmpty, conversationID: "other:\(r.app):\(conversation)", context: name,
                             link: link(for: r.app))
    }

    /// "Name in #channel", "#channel" with the sender as subtitle, or a DM ("Name").
    static func slack(_ r: Record, _ f: Fields) -> SharedMessage {
        var sender = f.title, channel: String?, body = f.body
        if let range = f.title.range(of: " in "),
           case let target = String(f.title[range.upperBound...]),
           target.hasPrefix("#") || target.range(of: #"^[a-z0-9_.\-]+$"#, options: .regularExpression) != nil {
            sender = String(f.title[..<range.lowerBound])
            channel = target.hasPrefix("#") ? target : "#" + target
        } else if f.title.hasPrefix("#") {
            channel = f.title
            sender = f.subtitle.isEmpty ? "Slack" : f.subtitle
        } else if f.subtitle.contains("#") {
            channel = f.subtitle
        }
        // Channel notifications often repeat the sender in the body ("Name: text").
        if let colon = body.range(of: #"^[^:\n]{2,60}: "#, options: .regularExpression) {
            let prefix = String(body[colon].dropLast(2))
            let generic = ["new message", "neue nachricht", "slack"].contains(f.title.lowercased())
            if generic || prefix.caseInsensitiveCompare(sender) == .orderedSame {
                if generic { sender = prefix }
                body = String(body[colon.upperBound...])
            }
        }
        if sender.isEmpty { sender = "Slack" }
        return SharedMessage(id: "slacknc:\(r.id)", source: .slack, sender: sender, senderHandle: sender, title: channel ?? sender,
                             body: body, date: f.date, isDirect: channel == nil, conversationID: "slack:\(channel ?? sender)",
                             context: "Slack notification", link: URL(string: "slack://open"))
    }

    static func link(for app: String) -> URL? {
        let l = app.lowercased()
        if l.contains("telegram") { return URL(string: "tg://") }
        if l.contains("discord") { return URL(string: "discord://") }
        if l.contains("signal") { return URL(string: "sgnl://") }
        if l.contains("teams") { return URL(string: "msteams://") }
        return nil
    }
}
