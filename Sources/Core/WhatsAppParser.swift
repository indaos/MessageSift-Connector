import Foundation

/// WhatsApp desktop's ChatStorage.sqlite rows → shared items: 1:1 chats, group messages that mention you,
/// and your own messages (so MessageSift knows what you answered).
enum WhatsAppParser {
    struct Row {
        var id: Int64
        var text: String?
        var date: Double          // seconds since 2001-01-01
        var fromMe: Bool
        var type: Int64
        var fromJID: String?
        var pushName: String?
        var chatJID: String
        var partner: String?
        var memberName: String?
        var memberJID: String?
        var metadata: Data?
    }

    enum ChatKind { case direct, group, other }

    static func kind(ofJID jid: String) -> ChatKind {
        if jid.hasSuffix("@g.us") { return .group }
        if jid.hasSuffix("@s.whatsapp.net") || jid.hasSuffix("@lid") { return .direct }
        return .other  // status, newsletters, broadcast lists
    }

    /// "41791234567@s.whatsapp.net" → "41791234567".
    static func digits(ofJID jid: String) -> String? {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        let digits = user.split(separator: ":").first.map(String.init)?.filter(\.isNumber) ?? ""
        return digits.count >= 5 ? digits : nil
    }

    static func mediaLabel(forType type: Int64) -> String? {
        switch type {
        case 1: return "📷 Photo"
        case 2: return "🎥 Video"
        case 3: return "🎤 Voice message"
        case 4: return "👤 Contact"
        case 5: return "📍 Location"
        case 8: return "📄 Document"
        default: return nil
        }
    }

    /// `me`: your phone number and LID digits (from WhatsApp's own preferences).
    static func messages(_ rows: [Row], me: [String]) -> [SharedMessage] {
        var out: [SharedMessage] = []
        var lastFromMe: [String: Date] = [:]
        for row in rows {
            let kind = kind(ofJID: row.chatJID)
            guard kind != .other else { continue }
            let date = Date(timeIntervalSinceReferenceDate: row.date)
            var text = (row.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                guard kind == .direct, let label = mediaLabel(forType: row.type) else { continue }
                text = label
            } else if row.type != 0 && mediaLabel(forType: row.type) == nil && row.type != 7 {
                continue  // system and group events
            }
            let conversation = "whatsapp:\(row.chatJID)"
            if row.fromMe { lastFromMe[conversation] = max(lastFromMe[conversation] ?? .distantPast, date) }
            if kind == .group && !row.fromMe {
                let mentioned = me.contains { id in text.contains("@" + id) || (row.metadata?.range(of: Data(id.utf8)) != nil) }
                guard mentioned else { continue }
            }
            let senderJID = row.memberJID ?? row.fromJID ?? row.chatJID
            let phone = digits(ofJID: senderJID).map { "+" + $0 }
            let partner = row.partner ?? ""
            let found = [row.memberName, kind == .direct ? partner : nil, row.pushName, phone].compactMap { $0 }.first { !$0.isEmpty }
            let name = row.fromMe ? "Me" : (found ?? "WhatsApp")
            out.append(SharedMessage(
                id: "whatsapp:\(row.id)", source: .whatsapp, sender: name, senderHandle: phone ?? senderJID,
                title: partner.isEmpty ? name : partner, body: text, date: date, isUnread: !row.fromMe, isFromMe: row.fromMe,
                isDirect: kind == .direct, conversationID: conversation, context: kind == .group ? "WhatsApp group" : "WhatsApp",
                link: link(chatJID: row.chatJID)))
        }
        for i in out.indices where !out[i].isFromMe {
            if let mine = lastFromMe[out[i].conversationID], mine > out[i].date { out[i].isAnswered = true }
        }
        return out
    }

    /// Phone-number chats open the chat (never sends); groups and @lid chats open WhatsApp.
    static func link(chatJID: String) -> URL? {
        if chatJID.hasSuffix("@s.whatsapp.net"), let d = digits(ofJID: chatJID) { return URL(string: "whatsapp://send?phone=\(d)") }
        return URL(string: "whatsapp://")
    }
}
